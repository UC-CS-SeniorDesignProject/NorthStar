import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'data/local/app_database.dart';
import 'data/local/connection/connection_health.dart';
import 'models/relay_exchange.dart';
import 'services/enhanced_local_service.dart';

void main() {
  runApp(const MyApp());
}

class ServerRequestException implements Exception {
  const ServerRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalLoopbackService {
  final List<String> _requests = <String>[];

  RelayExchange talk({required String request, String? reason}) {
    _requests.add(request);
    final String response =
        'Local loopback reply #${_requests.length}: $request';
    return RelayExchange(
      request: request,
      response: response,
      mode: RelayMode.localFallback,
      timestamp: DateTime.now(),
      note: reason,
    );
  }
}

class ResilientRequestClient {
  ResilientRequestClient({
    Duration timeout = const Duration(seconds: 10),
    EnhancedLocalLoopbackService? localLoopback,
    http.Client? httpClient,
    this.localOnlyMode = false,
  }) : _timeout = timeout,
       _localLoopback = localLoopback ?? EnhancedLocalLoopbackService(),
       _httpClient = httpClient ?? http.Client();

  final Duration _timeout;
  final EnhancedLocalLoopbackService _localLoopback;
  final http.Client _httpClient;
  final bool localOnlyMode;

  Future<RelayExchange> send({
    required Uri endpoint,
    required String request,
    Map<String, dynamic>? payload,
  }) async {
    // If local-only mode is enabled, force local processing
    if (localOnlyMode) {
      return _localLoopback.talk(
        request: endpoint.toString(),
        reason: 'Local-only mode enabled',
        payload: payload,
      );
    }

    try {
      final String response = await _sendToServer(endpoint, request, payload);
      return RelayExchange(
        request: request,
        response: response,
        mode: RelayMode.server,
        timestamp: DateTime.now(),
      );
    } on TimeoutException {
      return _localLoopback.talk(
        request: endpoint.toString(),
        reason: 'Timeout while reaching server.',
        payload: payload,
      );
    } on http.ClientException catch (error) {
      return _localLoopback.talk(
        request: endpoint.toString(),
        reason: 'Network issue: ${error.message}',
        payload: payload,
      );
    }
  }

  Future<String> _sendToServer(Uri endpoint, String requestBody, Map<String, dynamic>? payload) async {
    final Map<String, dynamic> requestData = {'message': requestBody};
    if (payload != null) {
      requestData.addAll(payload);
    }

    final http.Response response = await _httpClient
        .post(
          endpoint,
          headers: <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(requestData),
        )
        .timeout(_timeout);

    final String body = response.body;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ServerRequestException(
        'Server returned ${response.statusCode}: $body',
      );
    }

    return _extractMessage(body);
  }

  String _extractMessage(String body) {
    if (body.trim().isEmpty) {
      return '(empty response)';
    }

    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final dynamic value =
            decoded['reply'] ??
            decoded['response'] ??
            decoded['message'] ??
            decoded['echo'];
        if (value != null) {
          return value.toString();
        }
      }
    } on FormatException {
      // Keep raw body when it is not JSON.
    }

    return body;
  }

  void close() {
    _httpClient.close();
    _localLoopback.dispose();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.client, this.database});

  final ResilientRequestClient? client;
  final AppDatabase? database;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late ResilientRequestClient _client;
  late final AppDatabase _database = widget.database ?? AppDatabase();

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? ResilientRequestClient(localOnlyMode: false);
  }

  void _updateLocalOnlyMode(bool localOnly) {
    setState(() {
      _client.close(); // Close old client
      _client = ResilientRequestClient(localOnlyMode: localOnly);
    });
  }

  @override
  void dispose() {
    if (widget.client == null) {
      _client.close();
    }
    if (widget.database == null) {
      _database.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Northstar Relay',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: RelayHomePage(
        client: _client, 
        database: _database,
        onLocalOnlyModeChanged: _updateLocalOnlyMode,
      ),
    );
  }
}

class RelayHomePage extends StatefulWidget {
  const RelayHomePage({
    super.key,
    required this.client,
    required this.database,
    this.onLocalOnlyModeChanged,
  });

  final ResilientRequestClient client;
  final AppDatabase database;
  final void Function(bool)? onLocalOnlyModeChanged;

  @override
  State<RelayHomePage> createState() => _RelayHomePageState();
}

class _RelayHomePageState extends State<RelayHomePage> {
  final TextEditingController _endpointController = TextEditingController(
    text: 'http://localhost:8080/echo',
  );
  late final TextEditingController _controllerBaseController =
      TextEditingController(text: _defaultControllerBaseUrl());
  final TextEditingController _requestController = TextEditingController();
  final List<RelayExchange> _history = <RelayExchange>[];

  StreamSubscription<LocalDbHealthStatus>? _dbHealthSubscription;
  Timer? _visionStatusTimer;

  bool _isSending = false;
  bool _visionStatusFetchInFlight = false;
  bool _visionRunning = false;
  bool _localOnlyMode = false;
  bool _isUsingLocalMode = true; // Track current processing mode
  String _processingMode = 'Server'; // Will be updated based on actual connection
  int _pendingOutboxCount = 0;
  String _status = 'Ready';
  String _visionText = '(no OCR text yet)';
  String _visionScene = 'Unknown';
  String _visionLockedLabel = 'None';
  String? _visionError;
  bool _visionHasFrames = false;
  String? _storageWarning;
  bool _hasShownStorageWarning = false;

  @override
  void initState() {
    super.initState();
    _processingMode = widget.client.localOnlyMode ? 'Local' : 'Server';
    _dbHealthSubscription = localDbHealthStream.listen(_onDbHealthStatus);
    _onDbHealthStatus(latestLocalDbHealthStatus);
    unawaited(_loadLocalHistory());
    _startVisionPolling();
    unawaited(_pollVisionStatus(showErrors: false));
  }

  @override
  void dispose() {
    _dbHealthSubscription?.cancel();
    _visionStatusTimer?.cancel();
    _endpointController.dispose();
    _controllerBaseController.dispose();
    _requestController.dispose();
    super.dispose();
  }

  void _onDbHealthStatus(LocalDbHealthStatus status) {
    if (!mounted || !status.isInMemoryFallback) {
      return;
    }

    final String warningText =
        status.details ??
        'Local storage is using temporary in-memory mode. Data may reset.';

    if (_storageWarning != warningText) {
      setState(() {
        _storageWarning = warningText;
      });
    }

    if (_hasShownStorageWarning) {
      return;
    }

    _hasShownStorageWarning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _showError(warningText);
    });
  }

  Future<void> _loadLocalHistory() async {
    final List<MessageLog> storedMessages = await widget.database
        .getRecentMessageLogs();
    final int pendingCount = await widget.database.getPendingOutboxCount();

    if (!mounted) {
      return;
    }

    setState(() {
      _history
        ..clear()
        ..addAll(storedMessages.map(_mapLogToExchange));
      _pendingOutboxCount = pendingCount;
      _status = _statusWithPending('Ready', pendingCount);
    });
  }

  RelayExchange _mapLogToExchange(MessageLog messageLog) {
    return RelayExchange(
      request: messageLog.requestText,
      response: messageLog.responseText,
      mode: messageLog.mode == 'server'
          ? RelayMode.server
          : RelayMode.localFallback,
      timestamp: messageLog.createdAt,
      note: messageLog.note,
    );
  }

  String _statusWithPending(String statusText, int pendingCount) {
    if (pendingCount == 0) {
      return statusText;
    }
    return '$statusText • Pending outbox: $pendingCount';
  }

  String _defaultControllerBaseUrl() {
    if (kIsWeb) {
      return 'http://127.0.0.1:8000';
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }

    return 'http://127.0.0.1:8000';
  }

  Uri _controllerUri(String path) {
    final String baseText = _controllerBaseController.text.trim();
    if (baseText.isEmpty) {
      throw const FormatException('Controller URL is empty');
    }

    final String normalizedBase = baseText.endsWith('/')
        ? baseText.substring(0, baseText.length - 1)
        : baseText;

    return Uri.parse('$normalizedBase$path');
  }

  void _startVisionPolling() {
    _visionStatusTimer?.cancel();
    _visionStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollVisionStatus(showErrors: false));
    });
  }

  void _applyVisionStateFromPayload(Map<String, dynamic> payload) {
    final bool running = payload['running'] == true;
    final bool hasFrames =
        payload['last_frame_time'] is num &&
        (payload['last_frame_time'] as num).toDouble() > 0;

    final dynamic errorRaw = payload['last_error'];
    final String? errorText = errorRaw == null
        ? null
        : (errorRaw.toString().trim().isEmpty ? null : errorRaw.toString());

    final String latestTextRaw = (payload['latest_text'] ?? '').toString();
    final String latestText = latestTextRaw.trim().isEmpty
        ? '(no OCR text yet)'
        : latestTextRaw;

    final String sceneRaw = (payload['scene_description'] ?? 'Unknown')
        .toString();
    final String scene = sceneRaw.trim().isEmpty ? 'Unknown' : sceneRaw;

    final String lockedLabelRaw = (payload['locked_label'] ?? 'None')
        .toString();
    final String lockedLabel = lockedLabelRaw.trim().isEmpty
        ? 'None'
        : lockedLabelRaw;

    setState(() {
      _visionRunning = running;
      _visionHasFrames = hasFrames;
      _visionError = errorText;
      _visionText = latestText;
      _visionScene = scene;
      _visionLockedLabel = lockedLabel;
    });
  }

  Future<void> _pollVisionStatus({required bool showErrors}) async {
    if (_visionStatusFetchInFlight || !mounted) {
      return;
    }

    _visionStatusFetchInFlight = true;
    try {
      final Uri uri = _controllerUri('/controller/status');
      final http.Response response = await http
          .get(uri)
          .timeout(const Duration(seconds: 3));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (showErrors) {
          _showError('Status failed: ${response.statusCode} ${response.body}');
        }
        return;
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        if (showErrors) {
          _showError('Status response was not a JSON object.');
        }
        return;
      }

      if (!mounted) {
        return;
      }

      _applyVisionStateFromPayload(decoded);
    } catch (error) {
      if (showErrors && mounted) {
        _showError('Could not read vision status: $error');
      }
    } finally {
      _visionStatusFetchInFlight = false;
    }
  }

  Future<void> _send() async {
    final String endpointText = _endpointController.text.trim();
    final String message = _requestController.text.trim();

    if (message.isEmpty || _isSending) {
      return;
    }

    Uri endpoint;
    try {
      endpoint = Uri.parse(endpointText);
      if (!endpoint.hasScheme || endpoint.host.isEmpty) {
        throw const FormatException('Invalid endpoint');
      }
    } on FormatException {
      _showError(
        'Enter a valid endpoint URL, for example http://localhost:8080/echo',
      );
      return;
    }

    setState(() {
      _isSending = true;
      _status = 'Contacting server...';
    });

    try {
      final RelayExchange exchange = await widget.client.send(
        endpoint: endpoint,
        request: message,
      );

      await widget.database.persistExchange(
        requestText: exchange.request,
        responseText: exchange.response,
        usedFallback: exchange.mode == RelayMode.localFallback,
        note: exchange.note,
        timestamp: exchange.timestamp,
      );
      final int pendingCount = await widget.database.getPendingOutboxCount();

      if (!mounted) {
        return;
      }

      final String status = exchange.mode == RelayMode.server
          ? 'Connected to server'
          : 'Connection bad, using local loopback';

      // Show prominent message when falling back to local despite server mode
      if (exchange.mode == RelayMode.localFallback && !widget.client.localOnlyMode) {
        _showError('⚠️ Can\'t connect to server, switching to local processing. Reason: ${exchange.note ?? "Unknown"}');
      }

      setState(() {
        _history.insert(0, exchange);
        _pendingOutboxCount = pendingCount;
        _status = _statusWithPending(status, pendingCount);
        _processingMode = exchange.mode == RelayMode.server ? 'Server' : 'Local (Fallback)';
        _requestController.clear();
      });
    } on ServerRequestException catch (error) {
      _showError(error.message);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _statusWithPending(
          'Server responded with an error',
          _pendingOutboxCount,
        );
      });
    } catch (error) {
      _showError('Could not save local data: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _statusWithPending(
          'Local storage error',
          _pendingOutboxCount,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _startVision() async {
    Uri uri;
    try {
      uri = _controllerUri('/controller/start');
    } on FormatException {
      _showError('Enter a valid vision controller URL.');
      return;
    }

    try {
      final http.Response response = await http
          .post(
            uri,
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'camera_index': 0,
              'display': false,
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _showError('Start failed: ${response.statusCode} ${response.body}');
        return;
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _showError('Start response was not a JSON object.');
        return;
      }

      if (!mounted) {
        return;
      }

      _applyVisionStateFromPayload(decoded);
      setState(() {
        _status = _statusWithPending('Vision started', _pendingOutboxCount);
      });
    } catch (error) {
      _showError('Could not start vision: $error');
    }
  }

  Future<void> _stopVision() async {
    Uri uri;
    try {
      uri = _controllerUri('/controller/stop');
    } on FormatException {
      _showError('Enter a valid vision controller URL.');
      return;
    }

    try {
      final http.Response response = await http
          .post(uri)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _showError('Stop failed: ${response.statusCode} ${response.body}');
        return;
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _showError('Stop response was not a JSON object.');
        return;
      }

      if (!mounted) {
        return;
      }

      _applyVisionStateFromPayload(decoded);
      setState(() {
        _status = _statusWithPending('Vision stopped', _pendingOutboxCount);
      });
    } catch (error) {
      _showError('Could not stop vision: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _timeString(DateTime value) {
    String pad(int number) => number.toString().padLeft(2, '0');
    return '${pad(value.hour)}:${pad(value.minute)}:${pad(value.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final bool fallbackActive =
        _history.isNotEmpty && _history.first.mode == RelayMode.localFallback;

    return Scaffold(
      appBar: AppBar(title: const Text('Northstar Relay')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _endpointController,
              decoration: const InputDecoration(
                labelText: 'Server endpoint',
                hintText: 'http://localhost:8080/echo',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controllerBaseController,
              decoration: const InputDecoration(
                labelText: 'Vision controller base URL',
                hintText: 'http://127.0.0.1:8000',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                _visionRunning
                  ? FilledButton.icon(
                      onPressed: _visionStatusFetchInFlight ? null : _stopVision,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop Vision'),
                    )
                  : OutlinedButton.icon(
                      onPressed: _visionStatusFetchInFlight ? null : _startVision,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Vision'),
                    ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _visionStatusFetchInFlight
                      ? null
                      : () {
                          unawaited(_pollVisionStatus(showErrors: true));
                        },
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh vision status',
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Local-only mode toggle
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () {
                    widget.onLocalOnlyModeChanged?.call(!widget.client.localOnlyMode);
                  },
                  icon: Icon(widget.client.localOnlyMode 
                    ? Icons.computer 
                    : Icons.cloud),
                  label: Text(widget.client.localOnlyMode ? 'Local' : 'Server'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          _visionRunning
                              ? Icons.visibility
                              : Icons.visibility_off,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _visionRunning
                                ? 'Vision: Active ($_processingMode)'
                                : 'Vision: Idle',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        if (!widget.client.localOnlyMode && _processingMode.contains('Fallback'))
                          Icon(
                            Icons.warning_amber,
                            size: 18,
                            color: Theme.of(context).colorScheme.error,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _visionHasFrames
                          ? 'Camera frames: receiving'
                          : 'Camera frames: none yet',
                    ),
                    if (_visionError != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        'Vision error: $_visionError',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text('Locked target: $_visionLockedLabel'),
                    const SizedBox(height: 4),
                    Text('Scene: $_visionScene'),
                    const SizedBox(height: 6),
                    const Text('Latest OCR text:'),
                    const SizedBox(height: 2),
                    SelectableText(_visionText),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _requestController,
                    decoration: const InputDecoration(
                      labelText: 'Request message',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _isSending ? null : _send,
                  child: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(fallbackActive ? Icons.lan : Icons.cloud_done, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_status)),
              ],
            ),
            if (_storageWarning != null) ...<Widget>[
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _storageWarning!,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                const Icon(Icons.schedule, size: 16),
                const SizedBox(width: 8),
                Text('Pending outbox: $_pendingOutboxCount'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _history.isEmpty
                  ? const Center(
                      child: Text('No exchanges yet. Send a request to start.'),
                    )
                  : ListView.builder(
                      itemCount: _history.length,
                      itemBuilder: (BuildContext context, int index) {
                        final RelayExchange item = _history[index];
                        final String source = item.mode == RelayMode.server
                            ? 'Server'
                            : 'Local';

                        return Card(
                          child: ListTile(
                            leading: Icon(
                              item.mode == RelayMode.server
                                  ? Icons.cloud
                                  : Icons.memory,
                            ),
                            title: Text(item.response),
                            subtitle: Text(
                              'Request: ${item.request}'
                              '\nSource: $source'
                              '${item.note != null ? '\n${item.note}' : ''}',
                            ),
                            trailing: Text(_timeString(item.timestamp)),
                            isThreeLine: true,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
