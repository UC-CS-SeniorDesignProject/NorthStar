#!/bin/bash
# Setup script for Radxa Photo Server
# Run this on the Radxa Zero 3W as root

set -e

echo "=== Radxa Photo Server Setup ==="

# 1. Install dependencies
echo "[1/5] Installing packages..."
apt-get update
apt-get install -y \
    golang-go \
    v4l-utils \
    fswebcam \
    network-manager \
    avahi-daemon

# 2. Build the server
echo "[2/5] Building Go server..."
SRC_DIR="/opt/radxa-server"
mkdir -p "$SRC_DIR"
cp /home/radxa/RadxaServer/main.go "$SRC_DIR/main.go"
cp /home/radxa/RadxaServer/go.mod "$SRC_DIR/go.mod"

cd "$SRC_DIR"
go build -o radxa-photo main.go
cp radxa-photo /usr/local/bin/radxa-photo
chmod 755 /usr/local/bin/radxa-photo
echo "  Built and installed to /usr/local/bin/radxa-photo"

# 3. Create directories
echo "[3/5] Creating directories..."
mkdir -p /var/lib/radxa-photo

# 4. Install systemd service
echo "[4/5] Installing systemd service..."
cp /home/radxa/RadxaServer/radxa-photo.service /etc/systemd/system/radxa-photo.service
systemctl daemon-reload
systemctl enable radxa-photo

# 5. Verify camera
echo "[5/5] Checking camera..."
if [ -e /dev/video0 ]; then
    echo "  Camera found at /dev/video0"
    v4l2-ctl --device=/dev/video0 --list-formats-ext 2>/dev/null | head -20
else
    echo "  WARNING: No camera at /dev/video0 — plug in the USB camera"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "To start the server now:"
echo "  sudo systemctl start radxa-photo"
echo ""
echo "First-time usage:"
echo "  1. Connect your iPhone to the 'radxa-setup' hotspot (password: radxa1234)"
echo "  2. Set a security token:  POST http://10.42.0.1:8080/api/token/setup"
echo "     Body: {\"token\": \"your-secret-here\"}"
echo "  3. Configure Wi-Fi:       POST http://10.42.0.1:8080/api/wifi/configure"
echo "     Body: {\"ssid\": \"YourNetwork\", \"password\": \"YourPassword\"}"
echo "  4. iPhone joins the same network, app connects to http://radxa.local:8080"
echo "  5. Capture a photo:       GET http://radxa.local:8080/v1/capture"
echo "     Header: X-API-Key: your-secret-here"
