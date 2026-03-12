# Northstar Relay

Northstar Relay is a Flutter app that sends a request to a server and automatically falls back to a local loopback response when the network connection is bad.

## How it works

- Enter a server endpoint URL (default: `http://localhost:8080/echo`).
- Type a request message and tap **Send**.
- The app sends `POST` JSON: `{"message": "<your text>"}`.
- If the request times out or hits a socket/network error, the app switches to local loopback mode and replies locally.

## Expected server response

The app accepts:

- A plain text body, or
- JSON with one of: `reply`, `response`, `message`, `echo`

## Packages used

Runtime dependencies (`dependencies`):

- `flutter` (SDK)
- `http` `^1.2.2`
- `drift` `^2.20.2`
- `path` `^1.9.0`
- `path_provider` `^2.1.4`
- `sqlite3_flutter_libs` `^0.5.26`
- `cupertino_icons` `^1.0.8`

Development dependencies (`dev_dependencies`):

- `flutter_test` (SDK)
- `build_runner` `^2.4.13`
- `drift_dev` `^2.20.2`
- `flutter_lints` `^6.0.0`

## Run

```bash
flutter pub get
flutter run
```

For Android emulator testing against a host machine server, prefer `http://10.0.2.2:<port>/...` instead of `localhost`.

## Web local database (Drift WASM)

Web builds use Drift WASM for local persistence.

- `web/sqlite3.wasm` must exist.
- `web/drift_worker.js` must exist.
- Worker source is `web/drift_worker.dart`.

If you need to regenerate the worker file:

```bash
dart compile js web/drift_worker.dart -O2 -o web/drift_worker.js
```
