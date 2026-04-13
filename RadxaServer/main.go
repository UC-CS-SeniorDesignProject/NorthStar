// main.go - radxa glasses server
// christian + moe
// runs on the radxa zero 3w, handles camera capture wifi setup
// and serves images to the ios app over REST and websocket
//
// radxa is headless so the iphone app configures evrything
// wifi creds, security token etc
// if theres no known wifi it starts a hotspot for inital setup

package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	dataDir   = "/var/lib/radxa-photo"
	tokenFile = "/var/lib/radxa-photo/token"

	hotspotSSID = "radxa-setup"
	hotspotPass = "radxa1234"
	hotspotConn = "radxa-hotspot"
	hotspotIP   = "10.42.0.1" // networkmanager default for hotspots

	mdnsHostname = "radxa" // radxa.local on the network
	defaultPort  = ":8080"
)

var (
	tokenMu    sync.RWMutex
	tokenValue string

	captureMu sync.Mutex // only one capture at a time
	wifiMu    sync.Mutex

	// websocket - only expect one phone conected at a time
	activeWSMu   sync.Mutex
	activeWSConn *websocket.Conn

	camera *CameraService
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ---- token persistance ----
// saved to disk so it survves reboots

func loadToken() {
	data, err := os.ReadFile(tokenFile)
	if err != nil {
		tokenValue = ""
		return
	}
	tokenValue = strings.TrimSpace(string(data))
}

func saveToken(t string) error {
	if err := os.MkdirAll(filepath.Dir(tokenFile), 0750); err != nil {
		return err
	}
	return os.WriteFile(tokenFile, []byte(t+"\n"), 0600)
}

func getToken() string {
	tokenMu.RLock()
	defer tokenMu.RUnlock()
	return tokenValue
}

func setToken(t string) error {
	tokenMu.Lock()
	defer tokenMu.Unlock()
	if err := saveToken(t); err != nil {
		return err
	}
	tokenValue = t
	return nil
}

func tokenIsSet() bool { return getToken() != "" }

// ---- auth ----
// X-API-Key header same as christians ocr server

func checkAuth(r *http.Request) bool {
	tok := getToken()
	if tok == "" {
		return false
	}
	key := r.Header.Get("X-API-Key")
	return subtle.ConstantTimeCompare([]byte(key), []byte(tok)) == 1
}

func validateToken(t string) bool {
	tok := getToken()
	if tok == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(t), []byte(tok)) == 1
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"detail": msg})
}

// camera shows up at diffrent /dev/video ports depending on usb slot
func findCameraDevice() string {
	for i := 0; i < 10; i++ {
		dev := fmt.Sprintf("/dev/video%d", i)
		if _, err := os.Stat(dev); err == nil {
			return dev
		}
	}
	return "/dev/video0"
}

// ---- REST endponts ----

// simple liveness check no auth
func handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// more detaild status, app uses this to check if evrythings good
func handleReadyz(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"status": "ready",
	}

	camDev := findCameraDevice()
	if _, err := os.Stat(camDev); err != nil {
		resp["status"] = "degraded"
		resp["camera"] = "not found"
	} else {
		resp["camera"] = "ok"
		resp["camera_device"] = camDev
		resp["capture_method"] = camera.Method()
	}

	resp["token_configured"] = tokenIsSet()
	resp["base_url"] = fmt.Sprintf("http://%s.local:%s", mdnsHostname, strings.TrimPrefix(defaultPort, ":"))

	wifiMu.Lock()
	status := getWifiStatus()
	wifiMu.Unlock()
	resp["network"] = status

	writeJSON(w, http.StatusOK, resp)
}

// first thing app does after conecting to hotspot
// no auth needed if no token exists yet (chicken egg problem)
func handleTokenSetup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}

	var body struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Token == "" {
		writeError(w, http.StatusBadRequest, "provide a non-empty \"token\" field")
		return
	}
	if len(body.Token) < 8 {
		writeError(w, http.StatusBadRequest, "token must be at least 8 characters")
		return
	}
	// need to auth w current token to change it
	if tokenIsSet() {
		if !checkAuth(r) {
			writeError(w, http.StatusUnauthorized, "authenticate with current token to change it")
			return
		}
	}
	if err := setToken(body.Token); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save token: "+err.Error())
		return
	}
	log.Println("Token configured successfully")
	writeJSON(w, http.StatusOK, map[string]string{"status": "token_set"})
}

// REST capture - takes photo returns raw jpeg
// websocket is faster this is the fallback
func handleCapture(w http.ResponseWriter, r *http.Request) {
	if !tokenIsSet() {
		writeError(w, http.StatusServiceUnavailable, "server token not configured")
		return
	}
	if !checkAuth(r) {
		writeError(w, http.StatusUnauthorized, "invalid or missing X-API-Key")
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "GET or POST required")
		return
	}

	data, _, _, captureMs, err := camera.CaptureFrame(0, 0)
	if err != nil {
		log.Printf("REST capture error: %v", err)
		writeError(w, http.StatusServiceUnavailable, "capture failed: "+err.Error())
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	log.Printf("REST captured %d bytes in %.1fms (%s)", len(data), captureMs, camera.Method())
	w.Write(data)
}

// ---- websocket handler ----
// main image transport, persistant connection
// binary jpeg frames no base64 overhead

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	// only one conection at a time close old one
	activeWSMu.Lock()
	if activeWSConn != nil {
		log.Println("Closing previous WebSocket connection")
		activeWSConn.Close()
	}
	activeWSConn = conn
	activeWSMu.Unlock()

	defer func() {
		activeWSMu.Lock()
		if activeWSConn == conn {
			activeWSConn = nil
		}
		activeWSMu.Unlock()
		conn.Close()
		log.Println("WebSocket connection closed")
	}()

	log.Println("WebSocket connection opened")

	// first msg must be auth
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, msg, err := conn.ReadMessage()
	if err != nil {
		log.Printf("WebSocket auth read failed: %v", err)
		return
	}

	var authMsg struct {
		Type  string `json:"type"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(msg, &authMsg); err != nil || authMsg.Type != "auth" {
		conn.WriteJSON(map[string]string{"type": "error", "detail": "expected auth message"})
		return
	}
	if !validateToken(authMsg.Token) {
		conn.WriteJSON(map[string]string{"type": "error", "detail": "invalid token"})
		return
	}
	conn.WriteJSON(map[string]string{"type": "auth_ok"})
	log.Println("WebSocket authenticated")

	// no timeout after auth, stays open
	conn.SetReadDeadline(time.Time{})

	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			log.Printf("WebSocket read error: %v", err)
			break
		}

		var req struct {
			Type    string `json:"type"`
			ID      string `json:"id"`
			Quality int    `json:"quality"`
			MaxSide int    `json:"max_side"`
		}
		if err := json.Unmarshal(msg, &req); err != nil {
			conn.WriteJSON(map[string]string{"type": "error", "detail": "invalid JSON"})
			continue
		}

		switch req.Type {
		case "ping":
			conn.WriteJSON(map[string]string{"type": "pong"})
		case "capture":
			handleWSCapture(conn, req.ID, req.Quality, req.MaxSide)
		default:
			conn.WriteJSON(map[string]string{
				"type":   "error",
				"detail": "unknown message type: " + req.Type,
			})
		}
	}
}

// sends frame over ws: metadata text msg then binary jpeg
func handleWSCapture(conn *websocket.Conn, id string, quality, maxSide int) {
	data, w, h, captureMs, err := camera.CaptureFrame(quality, maxSide)
	if err != nil {
		log.Printf("WS capture error: %v", err)
		conn.WriteJSON(map[string]string{
			"type":   "error",
			"detail": "capture failed: " + err.Error(),
		})
		return
	}

	// metadata first so app knows whats comming
	meta := map[string]any{
		"type":       "frame",
		"id":         id,
		"width":      w,
		"height":     h,
		"bytes":      len(data),
		"capture_ms": captureMs,
		"method":     camera.Method(),
		"ts":         float64(time.Now().UnixMicro()) / 1e6,
	}
	if err := conn.WriteJSON(meta); err != nil {
		log.Printf("WS meta write error: %v", err)
		return
	}

	// then actual jpeg bytes
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		log.Printf("WS binary write error: %v", err)
		return
	}

	log.Printf("WS frame: %d bytes, %.1fms (%s)", len(data), captureMs, camera.Method())
}

// ---- wifi managment ----
// all wifi goes thru nmcli (NetworkManager)

func handleWifiStatus(w http.ResponseWriter, r *http.Request) {
	if !tokenIsSet() {
		writeError(w, http.StatusServiceUnavailable, "server token not configured")
		return
	}
	if !checkAuth(r) {
		writeError(w, http.StatusUnauthorized, "invalid or missing X-API-Key")
		return
	}
	wifiMu.Lock()
	defer wifiMu.Unlock()
	writeJSON(w, http.StatusOK, getWifiStatus())
}

func handleWifiScan(w http.ResponseWriter, r *http.Request) {
	if !tokenIsSet() {
		writeError(w, http.StatusServiceUnavailable, "server token not configured")
		return
	}
	if !checkAuth(r) {
		writeError(w, http.StatusUnauthorized, "invalid or missing X-API-Key")
		return
	}
	wifiMu.Lock()
	defer wifiMu.Unlock()

	// rescan takes a couple secs
	exec.Command("nmcli", "device", "wifi", "rescan").Run()
	time.Sleep(2 * time.Second)

	out, err := exec.Command("nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list").Output()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "wifi scan failed: "+err.Error())
		return
	}

	// parse nmcli output dedupe by ssid
	var networks []map[string]string
	seen := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) < 3 || parts[0] == "" {
			continue
		}
		ssid := parts[0]
		if seen[ssid] {
			continue
		}
		seen[ssid] = true
		networks = append(networks, map[string]string{
			"ssid": ssid, "signal": parts[1], "security": parts[2],
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"networks": networks})
}

// handles both normal WPA and enterprise WPA2-EAP
// response goes out BEFORE we switch networks otherwise
// the http response woud never reach the phone
func handleWifiConfigure(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	if !tokenIsSet() {
		writeError(w, http.StatusServiceUnavailable, "server token not configured")
		return
	}
	if !checkAuth(r) {
		writeError(w, http.StatusUnauthorized, "invalid or missing X-API-Key")
		return
	}

	var body struct {
		SSID              string `json:"ssid"`
		Password          string `json:"password"`
		Security          string `json:"security"`           // wpa-psk or wpa-eap
		EAPMethod         string `json:"eap_method"`         // peap ttls etc
		Phase2Auth        string `json:"phase2_auth"`        // mschapv2 usually
		Identity          string `json:"identity"`           // enterprise username
		AnonymousIdentity string `json:"anonymous_identity"`
		CACert            string `json:"ca_cert"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SSID == "" {
		writeError(w, http.StatusBadRequest, "provide \"ssid\" and \"password\" fields")
		return
	}

	isEnterprise := body.Security == "wpa-eap"
	if isEnterprise {
		log.Printf("Wi-Fi configure requested: SSID=%s (Enterprise, EAP=%s, user=%s)", body.SSID, body.EAPMethod, body.Identity)
	} else {
		log.Printf("Wi-Fi configure requested: SSID=%s", body.SSID)
	}

	// respond before switching so phone gets the response
	writeJSON(w, http.StatusAccepted, map[string]string{
		"status":       "connecting",
		"ssid":         body.SSID,
		"message":      "Radxa is switching networks. Reconnect via mDNS after joining the same network.",
		"reconnect_at": fmt.Sprintf("http://%s.local:%s", mdnsHostname, strings.TrimPrefix(defaultPort, ":")),
	})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	if isEnterprise {
		go switchToEnterpriseWifi(body.SSID, body.EAPMethod, body.Phase2Auth, body.Identity, body.Password, body.AnonymousIdentity, body.CACert)
	} else {
		go switchToWifi(body.SSID, body.Password)
	}
}

// normal WPA2 connect
func switchToWifi(ssid, password string) {
	time.Sleep(2 * time.Second) // let http response reach phone
	wifiMu.Lock()
	defer wifiMu.Unlock()

	log.Printf("Switching to Wi-Fi: %s", ssid)
	disableHotspot()
	time.Sleep(1 * time.Second)

	var cmd *exec.Cmd
	if password != "" {
		cmd = exec.Command("nmcli", "device", "wifi", "connect", ssid, "password", password)
	} else {
		cmd = exec.Command("nmcli", "device", "wifi", "connect", ssid)
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Wi-Fi connect failed: %v — %s", err, string(out))
		enableHotspot() // go back so user can retry
		return
	}
	time.Sleep(3 * time.Second)
	status := getWifiStatus()
	log.Printf("Connected to Wi-Fi: %s — IP: %v", ssid, status["ip"])
}

// enterprise WPA2-EAP (like UC_Secure)
// uses nmcli connection add instead of simple connect
// had to figure this out for our univeristy network
func switchToEnterpriseWifi(ssid, eapMethod, phase2Auth, identity, password, anonIdentity, caCert string) {
	time.Sleep(2 * time.Second)
	wifiMu.Lock()
	defer wifiMu.Unlock()

	log.Printf("Switching to Enterprise Wi-Fi: %s (EAP=%s)", ssid, eapMethod)
	disableHotspot()
	time.Sleep(1 * time.Second)

	// clean up old connection w same name
	exec.Command("nmcli", "connection", "delete", ssid).Run()

	if eapMethod == "" {
		eapMethod = "peap"
	}
	if phase2Auth == "" {
		phase2Auth = "mschapv2"
	}

	args := []string{
		"connection", "add",
		"type", "wifi",
		"con-name", ssid,
		"ifname", "wlan0",
		"ssid", ssid,
		"wifi-sec.key-mgmt", "wpa-eap",
		"802-1x.eap", eapMethod,
		"802-1x.phase2-auth", phase2Auth,
		"802-1x.identity", identity,
		"802-1x.password", password,
	}

	if anonIdentity != "" {
		args = append(args, "802-1x.anonymous-identity", anonIdentity)
	}

	// skip cert verification if no cert
	// matches UC_Secure setup instructions
	if caCert == "" {
		args = append(args, "802-1x.phase1-auth-flags", "32")
	} else {
		args = append(args, "802-1x.ca-cert", caCert)
	}

	cmd := exec.Command("nmcli", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Enterprise Wi-Fi add failed: %v — %s", err, string(out))
		enableHotspot()
		return
	}

	// now actualy connect
	cmd = exec.Command("nmcli", "connection", "up", ssid)
	out, err = cmd.CombinedOutput()
	if err != nil {
		log.Printf("Enterprise Wi-Fi connect failed: %v — %s", err, string(out))
		exec.Command("nmcli", "connection", "delete", ssid).Run()
		enableHotspot()
		return
	}

	time.Sleep(3 * time.Second)
	status := getWifiStatus()
	log.Printf("Connected to Enterprise Wi-Fi: %s — IP: %v", ssid, status["ip"])
}

func getWifiStatus() map[string]any {
	result := map[string]any{"mode": "unknown"}

	out, err := exec.Command("nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device", "status").Output()
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.SplitN(line, ":", 3)
		if len(parts) < 3 {
			continue
		}
		if parts[0] == "wifi" {
			if parts[1] == "connected" {
				result["mode"] = "client"
				result["connection"] = parts[2]
			} else {
				result["mode"] = "disconnected"
			}
			break
		}
	}

	// check if hotspot is active
	out2, _ := exec.Command("nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active").Output()
	for _, line := range strings.Split(string(out2), "\n") {
		if strings.Contains(line, hotspotConn) {
			result["mode"] = "hotspot"
			result["hotspot_ssid"] = hotspotSSID
			break
		}
	}

	ipOut, _ := exec.Command("hostname", "-I").Output()
	if ip := strings.TrimSpace(string(ipOut)); ip != "" {
		result["ip"] = strings.Fields(ip)[0]
	}
	return result
}

// ---- hotspot ----

func enableHotspot() {
	log.Println("Enabling hotspot mode...")
	cmd := exec.Command("nmcli", "device", "wifi", "hotspot",
		"ifname", "wlan0", "con-name", hotspotConn,
		"ssid", hotspotSSID, "password", hotspotPass,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Hotspot enable failed: %v — %s", err, string(out))
		return
	}
	log.Printf("Hotspot enabled: SSID=%s", hotspotSSID)
}

func disableHotspot() {
	exec.Command("nmcli", "connection", "down", hotspotConn).Run()
}

// runs on startup, if no wifi start hotspot so user can configure
func checkAndSetupNetwork() {
	wifiMu.Lock()
	defer wifiMu.Unlock()
	time.Sleep(5 * time.Second) // give networkmanager a sec

	status := getWifiStatus()
	mode, _ := status["mode"].(string)
	if mode == "client" {
		log.Printf("Wi-Fi connected to: %v", status["connection"])
		return
	}
	log.Println("No Wi-Fi connection found — starting hotspot for initial setup")
	enableHotspot()
}

// sets hostname so avahi advretises us as radxa.local
func setupMDNS() {
	current, _ := exec.Command("hostname").Output()
	if strings.TrimSpace(string(current)) != mdnsHostname {
		log.Printf("Setting hostname to %q for mDNS...", mdnsHostname)
		exec.Command("hostnamectl", "set-hostname", mdnsHostname).Run()
		exec.Command("systemctl", "restart", "avahi-daemon").Run()
	}
	log.Printf("mDNS: reachable as %s.local", mdnsHostname)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	os.MkdirAll(dataDir, 0750)

	setupMDNS()
	loadToken()
	if tokenIsSet() {
		log.Println("Token loaded from file")
	} else {
		log.Println("No token configured — waiting for initial setup via POST /api/token/setup")
	}

	camera = NewCameraService()
	defer camera.Close()

	go checkAndSetupNetwork()

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/token/setup", handleTokenSetup)
	mux.HandleFunc("/v1/capture", handleCapture)
	mux.HandleFunc("/capture", handleCapture)
	mux.HandleFunc("/ws", handleWebSocket)
	mux.HandleFunc("/api/wifi/status", handleWifiStatus)
	mux.HandleFunc("/api/wifi/networks", handleWifiScan)
	mux.HandleFunc("/api/wifi/configure", handleWifiConfigure)

	listenAddr := os.Getenv("PHOTO_LISTEN")
	if listenAddr == "" {
		listenAddr = defaultPort
	}

	log.Printf("Radxa photo server starting on %s (REST + WebSocket, capture: %s)", listenAddr, camera.Method())
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}
