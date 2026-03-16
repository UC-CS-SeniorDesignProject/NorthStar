import 'package:drift/drift.dart';

import 'connection/connection.dart';

part 'app_database.g.dart';

class MessageLogs extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get requestText => text()();

  TextColumn get responseText => text()();

  TextColumn get mode => text()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class OutboxEntries extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get requestText => text()();

  TextColumn get failureReason => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class SyncStates extends Table {
  IntColumn get id => integer()();

  IntColumn get pendingCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  DateTimeColumn get lastSuccessAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DriftDatabase(tables: <Type>[MessageLogs, OutboxEntries, SyncStates])
class AppDatabase extends _$AppDatabase {
  AppDatabase({QueryExecutor? executor})
    : super(executor ?? createQueryExecutor('northstar_relay'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await migrator.createAll();
      await into(
        syncStates,
      ).insert(const SyncStatesCompanion(id: Value(1), pendingCount: Value(0)));
    },
  );

  Future<void> persistExchange({
    required String requestText,
    required String responseText,
    required bool usedFallback,
    String? note,
    DateTime? timestamp,
  }) async {
    final DateTime now = timestamp ?? DateTime.now();

    await transaction(() async {
      await into(messageLogs).insert(
        MessageLogsCompanion.insert(
          requestText: requestText,
          responseText: responseText,
          mode: usedFallback ? 'local' : 'server',
          note: Value(note),
          createdAt: Value(now),
        ),
      );

      if (usedFallback) {
        await into(outboxEntries).insert(
          OutboxEntriesCompanion.insert(
            requestText: requestText,
            failureReason: Value(note),
            createdAt: Value(now),
          ),
        );
      }

      final int pendingCount = await getPendingOutboxCount();
      await _upsertSyncState(
        pendingCount: pendingCount,
        lastAttemptAt: now,
        lastSuccessAt: usedFallback ? null : now,
      );
    });
  }

  Future<List<MessageLog>> getRecentMessageLogs({int limit = 50}) {
    return (select(messageLogs)
          ..orderBy(<OrderingTerm Function(MessageLogs)>[
            (MessageLogs table) => OrderingTerm.desc(table.createdAt),
          ])
          ..limit(limit))
        .get();
  }

  Future<int> getPendingOutboxCount() async {
    final List<OutboxEntry> rows = await select(outboxEntries).get();
    return rows.length;
  }

  Future<void> _upsertSyncState({
    required int pendingCount,
    required DateTime lastAttemptAt,
    DateTime? lastSuccessAt,
  }) {
    return into(syncStates).insertOnConflictUpdate(
      SyncStatesCompanion(
        id: const Value(1),
        pendingCount: Value(pendingCount),
        lastAttemptAt: Value(lastAttemptAt),
        lastSuccessAt: Value(lastSuccessAt),
      ),
    );
  }
}
