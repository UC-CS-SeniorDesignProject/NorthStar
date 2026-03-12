import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'connection_health.dart';

QueryExecutor createQueryExecutor(String dbName) {
  return LazyDatabase(() async {
    final Directory directory = await getApplicationSupportDirectory();
    final File file = File(p.join(directory.path, '$dbName.sqlite'));
    reportLocalDbHealthStatus(
      const LocalDbHealthStatus(
        mode: LocalDbStorageMode.persistent,
        details: 'Native SQLite file storage is active.',
      ),
    );
    return NativeDatabase.createInBackground(file);
  });
}
