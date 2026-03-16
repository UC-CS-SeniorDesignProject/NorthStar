import 'dart:async';

enum LocalDbStorageMode { unknown, persistent, inMemoryFallback }

class LocalDbHealthStatus {
  const LocalDbHealthStatus({required this.mode, this.details});

  const LocalDbHealthStatus.unknown()
    : mode = LocalDbStorageMode.unknown,
      details = null;

  final LocalDbStorageMode mode;
  final String? details;

  bool get isInMemoryFallback => mode == LocalDbStorageMode.inMemoryFallback;
}

LocalDbHealthStatus _latestStatus = const LocalDbHealthStatus.unknown();

final StreamController<LocalDbHealthStatus> _statusController =
    StreamController<LocalDbHealthStatus>.broadcast();

LocalDbHealthStatus get latestLocalDbHealthStatus => _latestStatus;

Stream<LocalDbHealthStatus> get localDbHealthStream => _statusController.stream;

void reportLocalDbHealthStatus(LocalDbHealthStatus status) {
  _latestStatus = status;
  _statusController.add(status);
}
