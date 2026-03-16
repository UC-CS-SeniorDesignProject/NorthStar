import 'package:drift/drift.dart';

import 'connection_io.dart'
    if (dart.library.js_interop) 'connection_web.dart'
    as impl;

QueryExecutor createQueryExecutor(String dbName) {
  return impl.createQueryExecutor(dbName);
}
