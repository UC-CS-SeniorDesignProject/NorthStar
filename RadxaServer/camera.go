// camera stuff for the radxa - christian + moe
// keeps camera stream open so frames r basically instant
// if go4vl doesnt work falls back to v4l2-ctl or fswebcam

package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/vladimirvivien/go4vl/device"
	"github.com/vladimirvivien/go4vl/v4l2"
)

type CameraService struct {
	mu      sync.Mutex
	dev     *device.Device
	frames  <-chan []byte
	cancel  context.CancelFunc
	devPath string
	width   int
	height  int
	method  string // go4vl, v4l2-ctl, or fswebcam
	isOpen  bool
}

// sets up camera and picks best availble capture method
func NewCameraService() *CameraService {
	cs := &CameraService{
		devPath: findCameraDevice(),
		width:   3264, // max res for IMX219
		height:  2448,
	}

	// try go4vl first its way faster
	if err := cs.openGo4VL(); err != nil {
		log.Printf("go4vl failed (%v), falling back to CLI methods", err)

		if _, err := exec.LookPath("v4l2-ctl"); err == nil {
			cs.method = "v4l2-ctl"
			log.Printf("Camera: using v4l2-ctl fallback on %s", cs.devPath)
		} else {
			// fswebcam slow but works on evrything
			cs.method = "fswebcam"
			log.Printf("Camera: using fswebcam fallback on %s", cs.devPath)
		}
	}

	return cs
}

// opens camera w go4vl for persistant MJPEG streaming
// sensor compresses to jpeg in hardware so we just
// grab raw frames, no cpu encoding needed
func (cs *CameraService) openGo4VL() error {
	ctx, cancel := context.WithCancel(context.Background())

	// try higest res first work down
	resolutions := [][2]int{
		{3264, 2448},
		{2592, 1944},
		{1920, 1080},
		{1280, 720},
	}

	var dev *device.Device
	var err error

	for _, res := range resolutions {
		dev, err = device.Open(cs.devPath,
			device.WithPixFormat(v4l2.PixFormat{
				Width:       uint32(res[0]),
				Height:      uint32(res[1]),
				PixelFormat: v4l2.PixelFmtMJPEG,
			}),
			device.WithBufferSize(4),
		)
		if err == nil {
			cs.width = res[0]
			cs.height = res[1]
			break
		}
	}

	if err != nil {
		cancel()
		return fmt.Errorf("open camera: %w", err)
	}

	if err := dev.Start(ctx); err != nil {
		dev.Close()
		cancel()
		return fmt.Errorf("start stream: %w", err)
	}

	cs.dev = dev
	cs.frames = dev.GetOutput()
	cs.cancel = cancel
	cs.isOpen = true
	cs.method = "go4vl"

	// throw away first couple frames they come out dark sometimes
	for i := 0; i < 2; i++ {
		select {
		case <-cs.frames:
		case <-time.After(3 * time.Second):
			break
		}
	}

	log.Printf("Camera opened via go4vl: %s (%dx%d MJPEG, persistent stream)", cs.devPath, cs.width, cs.height)
	return nil
}

// gets latest frame as jpeg bytes
// quality/maxSide optional - app sends these when it wants smaller
// image for detection (no point sending 8MP to YOLO lol)
func (cs *CameraService) CaptureFrame(quality int, maxSide int) ([]byte, int, int, float64, error) {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	var data []byte
	var w, h int
	var ms float64
	var err error

	switch cs.method {
	case "go4vl":
		data, w, h, ms, err = cs.captureGo4VL()
	case "v4l2-ctl":
		data, w, h, ms, err = cs.captureV4L2Ctl()
	default:
		data, w, h, ms, err = cs.captureFswebcam()
	}

	if err != nil {
		return nil, 0, 0, ms, err
	}

	// only reencode if we acutally need to
	needsReencode := (quality > 0 && quality < 95) || maxSide > 0
	if needsReencode {
		data, w, h, err = reencodeJPEG(data, quality, maxSide)
		if err != nil {
			// reencode failed just send orignal
			return data, cs.width, cs.height, ms, nil
		}
	}

	return data, w, h, ms, nil
}

func reencodeJPEG(data []byte, quality int, maxSide int) ([]byte, int, int, error) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, err
	}

	bounds := img.Bounds()
	w := bounds.Dx()
	h := bounds.Dy()

	if maxSide > 0 {
		longest := w
		if h > longest {
			longest = h
		}
		if longest > maxSide {
			scale := float64(maxSide) / float64(longest)
			w = int(float64(w) * scale)
			h = int(float64(h) * scale)
			img = resizeImage(img, w, h)
		}
	}

	if quality <= 0 {
		quality = 95
	}

	var buf bytes.Buffer
	err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality})
	if err != nil {
		return nil, 0, 0, err
	}

	return buf.Bytes(), w, h, nil
}

// nearest neighbor resize, not pretty but whatevr
func resizeImage(src image.Image, newW, newH int) image.Image {
	bounds := src.Bounds()
	dst := image.NewRGBA(image.Rect(0, 0, newW, newH))

	for y := 0; y < newH; y++ {
		srcY := bounds.Min.Y + y*bounds.Dy()/newH
		for x := 0; x < newW; x++ {
			srcX := bounds.Min.X + x*bounds.Dx()/newW
			dst.Set(x, y, src.At(srcX, srcY))
		}
	}

	return dst
}

// reads from persistant stream and drains buffered frames
// so we alwyas get the newest one
func (cs *CameraService) captureGo4VL() ([]byte, int, int, float64, error) {
	if !cs.isOpen {
		return cs.captureV4L2Ctl()
	}

	t0 := time.Now()

	// drain old frames
	var frame []byte
	for {
		select {
		case f := <-cs.frames:
			frame = f
		default:
			goto done
		}
	}
done:

	if frame == nil {
		select {
		case f := <-cs.frames:
			frame = f
		case <-time.After(3 * time.Second):
			// stream probly died try reopening
			log.Println("go4vl frame timeout, trying to reopen camera...")
			cs.closeStream()
			if err := cs.openGo4VL(); err != nil {
				cs.method = "v4l2-ctl"
				return cs.captureV4L2Ctl()
			}
			return nil, 0, 0, 0, fmt.Errorf("camera timeout, stream reopened — retry")
		}
	}

	if len(frame) == 0 {
		return nil, 0, 0, 0, fmt.Errorf("empty frame")
	}

	ms := float64(time.Since(t0).Microseconds()) / 1000.0
	return frame, cs.width, cs.height, ms, nil
}

// v4l2-ctl fallback, slower but more compatable
func (cs *CameraService) captureV4L2Ctl() ([]byte, int, int, float64, error) {
	t0 := time.Now()
	tmp := filepath.Join(os.TempDir(), "radxa-v4l2-capture.jpg")
	os.Remove(tmp)

	cmd := exec.Command("v4l2-ctl",
		"--device", cs.devPath,
		"--set-fmt-video", fmt.Sprintf("width=%d,height=%d,pixelformat=MJPG", cs.width, cs.height),
		"--stream-mmap",
		"--stream-count=1",
		"--stream-to="+tmp,
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		os.Remove(tmp)
		log.Printf("v4l2-ctl failed: %v — %s", err, string(output))
		return cs.captureFswebcam()
	}

	data, err := os.ReadFile(tmp)
	os.Remove(tmp)
	if err != nil || len(data) == 0 {
		return cs.captureFswebcam()
	}

	ms := float64(time.Since(t0).Microseconds()) / 1000.0
	return data, cs.width, cs.height, ms, nil
}

// fswebcam was our orignal method keeping as last resort
func (cs *CameraService) captureFswebcam() ([]byte, int, int, float64, error) {
	t0 := time.Now()
	tmp := filepath.Join(os.TempDir(), "radxa-fswebcam-capture.jpg")
	os.Remove(tmp)

	cmd := exec.Command("fswebcam",
		"-d", cs.devPath,
		"-r", fmt.Sprintf("%dx%d", cs.width, cs.height),
		"--no-banner",
		"--jpeg", "95",
		"--skip", "2",
		tmp,
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		os.Remove(tmp)
		return nil, 0, 0, 0, fmt.Errorf("all capture methods failed: %s", string(output))
	}

	data, err := os.ReadFile(tmp)
	os.Remove(tmp)
	if err != nil || len(data) == 0 {
		return nil, 0, 0, 0, fmt.Errorf("fswebcam: empty output")
	}

	ms := float64(time.Since(t0).Microseconds()) / 1000.0
	return data, cs.width, cs.height, ms, nil
}

func (cs *CameraService) closeStream() {
	if cs.cancel != nil {
		cs.cancel()
	}
	if cs.dev != nil {
		cs.dev.Close()
	}
	cs.isOpen = false
}

func (cs *CameraService) Close() {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.closeStream()
}

// app shows this on dashboard
func (cs *CameraService) Method() string {
	return cs.method
}
