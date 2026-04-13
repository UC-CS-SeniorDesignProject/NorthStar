# Radxa Photo Capture Server

A headless Go HTTP server running on a Radxa Zero 3W (Debian Bookworm). It captures photos from a USB-connected camera (Arducam IMX219, 3264x2448 MJPEG) and streams them to an iPhone app over the local network. The server also handles its own network provisioning — the iPhone app configures everything.

## Architecture: How Networking Works

The Radxa is a headless device with no screen, keyboard, or manual input. The iPhone app is the sole interface for configuration. The networking is designed around this constraint.

### The Problem

The Radxa needs to be on the same network as the iPhone to communicate, but with no display or keyboard, there's no way to manually enter Wi-Fi credentials on the Radxa. The Radxa's IP address is also dynamic — it changes depending on which network it joins.

### The Solution: Hotspot Fallback + mDNS

```
                        FIRST BOOT / NO KNOWN NETWORK
                        ==============================

    iPhone                          Radxa
      |                               |
      |    Radxa has no saved Wi-Fi   |
      |    ---- starts hotspot --->   | SSID: "radxa-setup"
      |                               | Pass: "radxa1234"
      |                               | IP:   10.42.0.1
      |                               |
      |-- joins "radxa-setup" ------->|
      |                               |
      |-- POST /api/token/setup ----->|  Set security token
      |<-- 200 {"status":"token_set"} |
      |                               |
      |-- POST /api/wifi/configure -->|  Send Wi-Fi creds
      |<-- 202 {"reconnect_at":       |  (response sent BEFORE
      |     "http://radxa.local:8080"}|   hotspot goes down)
      |                               |
      |   Radxa tears down hotspot    |
      |   Radxa joins target Wi-Fi    |
      |   avahi advertises radxa.local|
      |                               |
      |-- joins same Wi-Fi network -->|
      |                               |
      |-- GET radxa.local:8080/healthz|  Reconnect via mDNS
      |<-- 200 {"status":"ok"} -------|
      |                               |


                        SUBSEQUENT BOOTS
                        ================

    iPhone                          Radxa
      |                               |
      |    Radxa auto-connects to     |
      |    remembered Wi-Fi network   |
      |    avahi advertises radxa.local|
      |                               |
      |-- GET radxa.local:8080/healthz|  Already on same network
      |<-- 200 {"status":"ok"} -------|
      |                               |
      |-- GET /v1/capture ----------->|  Ready to use
      |<-- 200 [JPEG bytes] ----------|
      |                               |


                        NETWORK CHANGES
                        ================

    If the Radxa is moved to a new location and can't find
    a known network, it falls back to hotspot mode again.
    The iPhone repeats the first-boot flow to configure
    new Wi-Fi credentials. The Radxa remembers all previously
    configured networks via NetworkManager.
```

### Key Details

- **Hotspot IP is always `10.42.0.1`** — this is NetworkManager's default gateway for hotspots. The app hardcodes this for initial setup.
- **mDNS (`radxa.local`)** — after joining a real network, the Radxa advertises itself via avahi/mDNS as `radxa.local`. The iPhone resolves this automatically. No hardcoded IPs needed.
- **Wi-Fi configure is async** — when the iPhone sends Wi-Fi credentials, the server responds with `202 Accepted` *before* tearing down the hotspot. This ensures the HTTP response actually reaches the phone. The network switch happens 2 seconds later in a background goroutine.
- **Auto-fallback** — if the Wi-Fi connection attempt fails, the hotspot is re-enabled automatically.

## Authentication

All authenticated endpoints use the `X-API-Key` header (not Bearer auth).

The token starts **unconfigured**. On first use, the iPhone sets it via `POST /api/token/setup`. Once set, all authenticated endpoints require `X-API-Key: <token>`. To change an existing token, the request must include the current token for auth.

Token is persisted to disk at `/var/lib/radxa-photo/token` and survives reboots.

## API Reference

Base URL: `http://radxa.local:8080` (or `http://10.42.0.1:8080` during hotspot setup)

### Health & Status

#### `GET /healthz`
Unauthenticated. Simple liveness check.

**Response** `200`:
```json
{"status": "ok"}
```

#### `GET /readyz`
Unauthenticated. Readiness check with details about camera, token, and network state.

**Response** `200`:
```json
{
  "status": "ready",
  "camera": "ok",
  "token_configured": true,
  "base_url": "http://radxa.local:8080",
  "network": {
    "mode": "client",
    "connection": "MyHomeWifi",
    "ip": "192.168.1.42"
  }
}
```

`status` is `"ready"` when everything is good, `"degraded"` if the camera is missing.

`network.mode` is one of: `"client"` (connected to Wi-Fi), `"hotspot"` (running setup AP), `"disconnected"`, `"unknown"`.

When in hotspot mode, network includes `"hotspot_ssid": "radxa-setup"`.

### Token Setup

#### `POST /api/token/setup`
Set or change the security token. **No auth required when no token exists yet.** Requires current auth to change an existing token.

**Request**:
```json
{"token": "my-secret-token-here"}
```
Token must be at least 8 characters.

**Response** `200`:
```json
{"status": "token_set"}
```

**Errors**:
- `400` — empty or too-short token
- `401` — token already exists and request doesn't include valid `X-API-Key`

### Photo Capture

#### `GET /v1/capture`
**Authenticated.** Triggers the USB camera to capture a photo and returns the raw JPEG bytes directly in the response body. Nothing is stored on disk.

Also available at `GET /capture` and `POST /capture`.

**Headers**:
```
X-API-Key: <your-token>
```

**Response** `200`:
```
Content-Type: image/jpeg

<raw JPEG bytes>
```

The iPhone app can directly create a `UIImage` from the response data.

**Errors**:
- `401` — missing or invalid `X-API-Key`
- `503` — token not configured, or camera capture failed

### Wi-Fi Management

All Wi-Fi endpoints require authentication.

#### `GET /api/wifi/status`
Returns current network state.

**Response** `200`:
```json
{
  "mode": "client",
  "connection": "MyNetwork",
  "ip": "192.168.1.42"
}
```

#### `GET /api/wifi/networks`
Scans for available Wi-Fi networks. Takes ~2 seconds (scan delay).

**Response** `200`:
```json
{
  "networks": [
    {"ssid": "MyNetwork", "signal": "85", "security": "WPA2"},
    {"ssid": "Neighbor", "signal": "42", "security": "WPA1 WPA2"}
  ]
}
```

#### `POST /api/wifi/configure`
Connect to a Wi-Fi network. **This is an async operation** — the response comes back immediately, then the Radxa switches networks in the background.

**Request**:
```json
{"ssid": "MyNetwork", "password": "wifi-password"}
```

**Response** `202`:
```json
{
  "status": "connecting",
  "ssid": "MyNetwork",
  "message": "Radxa is switching networks. Reconnect via mDNS after joining the same network.",
  "reconnect_at": "http://radxa.local:8080"
}
```

After receiving this response, the app should:
1. Disconnect from the `radxa-setup` hotspot
2. Join the same target Wi-Fi network
3. Wait a few seconds for the Radxa to connect and get an IP
4. Reconnect to the Radxa at `http://radxa.local:8080`
5. Call `/healthz` to confirm the connection

If the Radxa fails to connect, it re-enables the hotspot automatically.

## Error Format

All errors return JSON with a `detail` field:
```json
{"detail": "description of what went wrong"}
```

HTTP status codes used: `400`, `401`, `405`, `500`, `503`.

## iPhone App Integration Notes

The existing app code already has most of what's needed:

- **`APIClient`** uses `X-API-Key` header — matches the server
- **`CaptureService`** does `GET` + `UIImage(data:)` on raw bytes — matches `/v1/capture`
- **`ServerService`** calls `/healthz` and `/readyz` — matches the server
- **Settings** has configurable base URL, API key, and capture endpoint — all compatible

What the app needs added:
1. **First-time setup flow** — detect hotspot, connect to `10.42.0.1:8080`, call token setup + wifi configure
2. **Wi-Fi management UI** — scan networks, select one, enter password, send to Radxa
3. **Reconnection logic** — after Wi-Fi configure, switch to target network, poll `radxa.local:8080/healthz` until it responds
4. **Store base URL as `http://radxa.local:8080`** after initial setup
