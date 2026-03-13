import 'dart:async';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'dart:io' show Platform;

class LocalVisionService {
  CameraController? _cameraController;
  late final TextRecognizer _textRecognizer;
  late final ObjectDetector _objectDetector;
  
  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isMockMode = false; // For desktop platforms
  String _latestText = '';
  String _lockedObject = '';
  
  // OCR triggers matching your Python code
  static const List<String> ocrTriggers = [
    'book', 'traffic light', 'stop sign', 'parking meter',
    'remote', 'cell phone', 'laptop', 'monitor', 'tv',
    'clock', 'sign', 'screen', 'menu', 'bottle', 'cup'
  ];

  LocalVisionService() {
    _textRecognizer = TextRecognizer();
    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.stream,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );
  }

  Future<Map<String, dynamic>> startProcessing({
    int cameraIndex = 0,
    bool display = false,
  }) async {
    if (_isInitialized) {
      return {'running': true, 'message': 'Already running'};
    }

    // Check if we're on a desktop platform without camera support
    if (_isDesktopPlatform()) {
      return _startMockProcessing();
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        // Fallback to mock mode if no cameras available
        return _startMockProcessing();
      }

      final camera = cameras.length > cameraIndex 
          ? cameras[cameraIndex] 
          : cameras.first;

      _cameraController = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      
      // Start image stream processing
      await _cameraController!.startImageStream(_processFrame);
      
      _isInitialized = true;
      return getStatus();
    } catch (e) {
      // Fallback to mock mode on any error
      return _startMockProcessing();
    }
  }

  bool _isDesktopPlatform() {
    if (kIsWeb) return true;
    try {
      return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    } catch (e) {
      return true; // Assume desktop if platform detection fails
    }
  }

  Future<Map<String, dynamic>> _startMockProcessing() async {
    _isMockMode = true;
    _isInitialized = true;
    _latestText = 'Mock OCR: Camera not available on this platform';
    _lockedObject = 'screen'; // Simulate detecting a screen
    
    // Start mock polling timer
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_isInitialized || !_isMockMode) {
        timer.cancel();
        return;
      }
      
      // Simulate changing text detection
      final mockTexts = [
        'Mock OCR: Desktop mode active',
        'Mock OCR: Testing vision features',
        'Mock OCR: Camera simulation running',
        'Mock OCR: Ready for mobile deployment'
      ];
      _latestText = mockTexts[DateTime.now().millisecond % mockTexts.length];
    });
    
    return getStatus();
  }

  Future<Map<String, dynamic>> stopProcessing() async {
    if (!_isInitialized) {
      return {'running': false, 'message': 'Not running'};
    }

    try {
      if (_isMockMode) {
        _isMockMode = false;
        _isInitialized = false;
        return getStatus();
      }
      
      await _cameraController?.stopImageStream();
      await _cameraController?.dispose();
      _cameraController = null;
      _isInitialized = false;
      return getStatus();
    } catch (e) {
      return {
        'running': false,
        'last_error': e.toString(),
      };
    }
  }

  Map<String, dynamic> getStatus() {
    final mode = _isMockMode ? 'mock' : 'camera';
    return {
      'running': _isInitialized,
      'locked_label': _lockedObject.isEmpty ? null : _lockedObject,
      'latest_text': _latestText,
      'scene_description': _isMockMode 
          ? 'Desktop simulation mode (camera not available)'
          : 'Local processing active',
      'camera_index': 0,
      'display': false,
      'mode': mode,
      'last_frame_time': DateTime.now().millisecondsSinceEpoch / 1000,
    };
  }

  void _processFrame(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage != null) {
        // Process for object detection
        final objects = await _objectDetector.processImage(inputImage);
        
        // Look for OCR triggers
        String? foundTrigger;
        for (final object in objects) {
          for (final label in object.labels) {
            if (ocrTriggers.contains(label.text.toLowerCase())) {
              foundTrigger = label.text;
              break;
            }
          }
          if (foundTrigger != null) break;
        }

        if (foundTrigger != null) {
          _lockedObject = foundTrigger;
          
          // Perform OCR on detected objects
          final recognizedText = await _textRecognizer.processImage(inputImage);
          _latestText = recognizedText.text;
        }
      }
    } catch (e) {
      debugPrint('Error processing frame: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _convertCameraImage(CameraImage image) {
    try {
      // Get image rotation
      final sensorOrientation = _cameraController?.description.sensorOrientation ?? 0;
      InputImageRotation? rotation;
      
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        var rotationCompensation = sensorOrientation;
        rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
      }

      if (rotation == null) return null;

      // Get image format
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      // For NV21 format (common on Android)
      if (image.format.group == ImageFormatGroup.nv21 ||
          image.format.group == ImageFormatGroup.yuv420) {
        return InputImage.fromBytes(
          bytes: image.planes[0].bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: format,
            bytesPerRow: image.planes[0].bytesPerRow,
          ),
        );
      }

      // For other formats, concatenate planes
      return InputImage.fromBytes(
        bytes: _concatenatePlanes(image.planes),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final List<int> allBytes = <int>[];
    for (final Plane plane in planes) {
      allBytes.addAll(plane.bytes);
    }
    return Uint8List.fromList(allBytes);
  }

  void dispose() {
    if (_isMockMode) {
      _isMockMode = false;
      _isInitialized = false;
      return;
    }
    
    _textRecognizer.close();
    _objectDetector.close();
    _cameraController?.dispose();
  }
}