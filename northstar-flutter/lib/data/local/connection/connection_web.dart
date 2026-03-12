import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'connection_health.dart';

QueryExecutor createQueryExecutor(String dbName) {
  return LazyDatabase(() async {
    final WasmDatabaseResult result = await WasmDatabase.open(
      databaseName: dbName,
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );

    final bool isInMemory =
        result.chosenImplementation == WasmStorageImplementation.inMemory;
    final String missingFeatures = result.missingFeatures
        .map((MissingBrowserFeature feature) => feature.name)
        .join(', ');

    if (isInMemory) {
      final String details = missingFeatures.isEmpty
          ? 'Browser fell back to temporary in-memory storage. Data may reset on refresh.'
          : 'Browser fell back to temporary in-memory storage. Missing features: $missingFeatures';
      reportLocalDbHealthStatus(
        LocalDbHealthStatus(
          mode: LocalDbStorageMode.inMemoryFallback,
          details: details,
        ),
      );
    } else {
      reportLocalDbHealthStatus(
        LocalDbHealthStatus(
          mode: LocalDbStorageMode.persistent,
          details: 'Web storage mode: ${result.chosenImplementation.name}',
        ),
      );
    }

    return result.resolvedExecutor;
  });
}
