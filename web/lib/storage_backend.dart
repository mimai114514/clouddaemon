import 'package:sembast/sembast.dart';

import 'storage_backend_stub.dart'
    if (dart.library.html) 'storage_backend_web.dart' as backend;

DatabaseFactory getDatabaseFactory() => backend.getDatabaseFactory();
