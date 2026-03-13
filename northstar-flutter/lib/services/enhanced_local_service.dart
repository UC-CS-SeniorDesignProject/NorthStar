import 'dart:convert';
import '../models/relay_exchange.dart';
import '../services/local_vision_service.dart';

class EnhancedLocalLoopbackService {
  final List<String> _requests = <String>[];
  late final LocalVisionService _visionService;

  EnhancedLocalLoopbackService() {
    _visionService = LocalVisionService();
  }

  Future<RelayExchange> talk({
    required String request, 
    String? reason,
    Map<String, dynamic>? payload
  }) async {
    _requests.add(request);
    
    // Handle vision system endpoints locally
    if (request.contains('/controller/')) {
      return await _handleVisionEndpoint(request, payload, reason);
    }
    
    // Default loopback behavior
    final String response = 'Local loopback reply #${_requests.length}: $request';
    return RelayExchange(
      request: request,
      response: response,
      mode: RelayMode.localFallback,
      timestamp: DateTime.now(),
      note: reason,
    );
  }

  Future<RelayExchange> _handleVisionEndpoint(
    String endpoint, 
    Map<String, dynamic>? payload,
    String? reason
  ) async {
    try {
      Map<String, dynamic> response;
      
      if (endpoint.contains('/controller/status')) {
        response = _visionService.getStatus();
      } else if (endpoint.contains('/controller/start')) {
        final cameraIndex = payload?['camera_index'] ?? 0;
        final display = payload?['display'] ?? false;
        response = await _visionService.startProcessing(
          cameraIndex: cameraIndex,
          display: display,
        );
      } else if (endpoint.contains('/controller/stop')) {
        response = await _visionService.stopProcessing();
      } else if (endpoint.contains('/health')) {
        response = {'status': 'ok', 'mode': 'local'};
      } else {
        response = {'error': 'Unknown endpoint: $endpoint'};
      }

      return RelayExchange(
        request: endpoint,
        response: jsonEncode(response),
        mode: RelayMode.localFallback,
        timestamp: DateTime.now(),
        note: reason ?? 'Local vision processing',
      );
    } catch (e) {
      return RelayExchange(
        request: endpoint,
        response: jsonEncode({'error': e.toString()}),
        mode: RelayMode.localFallback,
        timestamp: DateTime.now(),
        note: 'Local vision error: $reason',
      );
    }
  }

  void dispose() {
    _visionService.dispose();
  }
}