import 'package:sembast/sembast.dart';

import 'models.dart';
import 'storage_backend.dart';

class AppStorage {
  static const _databaseName = 'clouddaemon_web';
  final _serversStore = stringMapStoreFactory.store('servers');
  final _managedServicesStore = stringMapStoreFactory.store('managed_services');

  AppStorage({DatabaseFactory? databaseFactory})
      : _databaseFactory = databaseFactory ?? getDatabaseFactory();

  final DatabaseFactory _databaseFactory;
  Database? _database;

  Future<void> init() async {
    _database ??= await _databaseFactory.openDatabase(_databaseName);
  }

  Future<List<ServerProfile>> loadServers() async {
    await init();
    final records = await _serversStore.find(_database!);
    return records
        .map((record) => ServerProfile.fromJson(record.value))
        .toList();
  }

  Future<void> saveServer(ServerProfile server) async {
    await init();
    await _serversStore.record(server.id).put(_database!, server.toJson());
  }

  Future<void> deleteServer(String serverId) async {
    await init();
    await _serversStore.record(serverId).delete(_database!);
    final finder = Finder(filter: Filter.equals('server_id', serverId));
    await _managedServicesStore.delete(_database!, finder: finder);
  }

  Future<List<ManagedService>> loadManagedServices() async {
    await init();
    final records = await _managedServicesStore.find(_database!);
    return records
        .map((record) => ManagedService.fromJson(record.value))
        .toList();
  }

  Future<void> saveManagedService(ManagedService managedService) async {
    await init();
    await _managedServicesStore
        .record(managedService.id)
        .put(_database!, managedService.toJson());
  }

  Future<void> deleteManagedService(String id) async {
    await init();
    await _managedServicesStore.record(id).delete(_database!);
  }
}
