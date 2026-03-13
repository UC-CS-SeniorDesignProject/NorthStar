enum RelayMode { server, localFallback }

class RelayExchange {
  const RelayExchange({
    required this.request,
    required this.response,
    required this.mode,
    required this.timestamp,
    this.note,
  });

  final String request;
  final String response;
  final RelayMode mode;
  final DateTime timestamp;
  final String? note;
}