import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'models.dart';

const _uuid = Uuid();

ExportBundle buildExportBundle({
  required List<ServerProfile> servers,
  required List<ManagedService> managedServices,
}) {
  return ExportBundle(
    version: 1,
    exportedAt: DateTime.now().toUtc().toIso8601String(),
    servers: servers,
    managedServices: managedServices,
  );
}

String encodeExportBundle(ExportBundle bundle) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(bundle.toJson());
}

ImportPreview previewImport({
  required ExportBundle bundle,
  required List<ServerProfile> existingServers,
  required List<ManagedService> existingManagedServices,
}) {
  final existingServerBySignature = {
    for (final server in existingServers) _serverSignature(server): server,
  };
  final existingServerById = {
    for (final server in existingServers) server.id: server,
  };
  final existingManagedKeys = {
    for (final managed in existingManagedServices) _managedKey(managed.serviceName): managed,
  };
  final serversToInsert = <ServerProfile>[];
  var skippedServers = 0;

  for (final importedServer in bundle.servers) {
    final signature = _serverSignature(importedServer);
    final matchingServer = existingServerBySignature[signature];
    if (matchingServer != null) {
      skippedServers++;
      continue;
    }

    ServerProfile serverToInsert = importedServer;
    if (existingServerById.containsKey(importedServer.id) ||
        serversToInsert.any((server) => server.id == importedServer.id)) {
      serverToInsert = importedServer.copyWith(id: _uuid.v4());
    }

    existingServerById[serverToInsert.id] = serverToInsert;
    existingServerBySignature[_serverSignature(serverToInsert)] = serverToInsert;
    serversToInsert.add(serverToInsert);
  }

  final managedServicesToInsert = <ManagedService>[];
  final errors = <String>[];
  var skippedManagedServices = 0;

  for (final importedManaged in bundle.managedServices) {
    final key = _managedKey(importedManaged.serviceName);
    if (existingManagedKeys.containsKey(key) ||
        managedServicesToInsert.any(
          (managed) => managed.serviceName == importedManaged.serviceName,
        )) {
      skippedManagedServices++;
      continue;
    }

    var managedToInsert = ManagedService(
      id: importedManaged.id,
      serviceName: importedManaged.serviceName,
      pinnedAt: importedManaged.pinnedAt,
    );
    if (existingManagedServices.any((managed) => managed.id == managedToInsert.id) ||
        managedServicesToInsert.any((managed) => managed.id == managedToInsert.id)) {
      managedToInsert = ManagedService(
        id: _uuid.v4(),
        serviceName: importedManaged.serviceName,
        pinnedAt: importedManaged.pinnedAt,
      );
    }

    existingManagedKeys[key] = managedToInsert;
    managedServicesToInsert.add(managedToInsert);
  }

  return ImportPreview(
    serversToInsert: serversToInsert,
    managedServicesToInsert: managedServicesToInsert,
    skippedServers: skippedServers,
    skippedManagedServices: skippedManagedServices,
    errors: errors,
  );
}

ExportBundle decodeExportBundle(String rawJson) {
  final parsed = jsonDecode(rawJson);
  if (parsed is! Map<String, dynamic>) {
    throw const FormatException('Import file must be a JSON object.');
  }
  return ExportBundle.fromJson(parsed);
}

String _serverSignature(ServerProfile server) {
  return '${server.name}|${server.baseUrl}|${server.token}';
}

String _managedKey(String serviceName) {
  return serviceName;
}
