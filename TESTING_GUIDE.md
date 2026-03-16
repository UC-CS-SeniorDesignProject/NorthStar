# Testing Your Local Vision Processing

## **Available Testing Methods**

### **✅ Current Setup (No Mobile SDK)**
**Windows Desktop App** - Running successfully! 
- ✅ Test API fallback logic  
- ✅ Test UI components
- ❌ Camera/ML features not available on desktop

### **🔧 For Full Camera Testing**
Need Android Studio/SDK or iOS device for camera features.

## **Testing Scenarios**

### **1. Test Server Fallback Logic (Windows - Active Now)**

The app is currently running on Windows. Test the fallback behavior:

**Test A: Server Available**
1. Start your Python server:
   ```bash
   cd c:\Users\jared\Repos\NorthStar\ocr-testing
   python northstar-controller.py
   ```

2. In the Flutter app:
   - Enter endpoint: `http://localhost:8000/controller/status`
   - Send request - should get server response

**Test B: Server Unavailable**  
1. Stop Python server (Ctrl+C)
2. Send same request - should get local fallback response

**Test C: API Endpoints**
Try these endpoints to test local processing:
- `/controller/status` - Get current status
- `/controller/start` - Start vision processing  
- `/controller/stop` - Stop vision processing
- `/health` - Health check

### **2. Unit Test the Components**

Run the existing tests:
```bash
flutter test
```

### **3. Mobile Testing Setup (For Camera Features)**

**Option A: Android Emulator**
1. Install Android Studio: https://developer.android.com/studio
2. Set up SDK and create emulator:
   ```bash
   flutter emulators --create --name vision_test
   flutter emulators --launch vision_test
   ```

**Option B: Physical Device**
1. Enable Developer mode on Android/iOS device
2. Connect via USB
3. Run: `flutter run` (auto-detects device)

### **4. Mobile Camera Testing Scenarios**

Once you have mobile setup:

**Test D: Local Vision Processing**
1. Grant camera permissions
2. Point camera at text (books, signs, screens)  
3. Should detect objects and perform OCR
4. Check status endpoint for detected text

**Test E: Performance Testing**
1. Monitor battery usage during processing
2. Test with different lighting conditions
3. Test object detection accuracy vs Python server

## **Debug Commands**

**Check app logs:**
```bash
flutter logs
```

**Restart app:**
- Press `r` in terminal (hot reload)
- Press `R` in terminal (hot restart)

**DevTools debugging:**
- Open: http://127.0.0.1:53502/KmT_uhvYzA0=/devtools/

## **Expected Test Results**

### **Windows (Current)**
- ✅ App launches successfully
- ✅ UI renders correctly  
- ✅ Server fallback works
- ⚠️ Camera features show "not available on this platform"

### **Mobile (After Setup)**
- ✅ Camera permission requests
- ✅ Live object detection
- ✅ OCR text recognition  
- ✅ Same API responses as Python server

## **Troubleshooting**

**Issue: "Camera permission denied"**
- Solution: Grant camera permission in device settings

**Issue: "ML Kit initialization failed"**  
- Solution: Ensure Google Play Services updated on Android

**Issue: "No camera available"**
- Solution: Test on physical device, not all emulators support camera

**Issue: Poor detection accuracy**
- Solution: Ensure good lighting, steady device, clear text/objects

## **Quick Test Commands**

**Test current Windows app:**
```bash
# App is already running! Test in the GUI
# Try endpoint: http://localhost:8000/controller/status
```

**Set up for mobile testing:**
```bash
# Install Android Studio first, then:
flutter emulators --create --name vision_test
flutter run -d vision_test
```

**Run unit tests:**
```bash
flutter test
```

## **Next Steps**

1. **Test Windows app now** - API fallback is working
2. **Install Android Studio** for mobile camera testing  
3. **Connect physical device** for real-world testing
4. **Compare accuracy** between local ML Kit vs Python server

Your local vision processing is ready - just need proper mobile environment for camera features!