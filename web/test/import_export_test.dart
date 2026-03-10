import 'package:clouddaemon_web/import_export.dart';
import 'package:clouddaemon_web/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('previewImport skips duplicate servers and managed services', () {
    final existingServer = ServerProfile(
      id: 'server-1',
      name: 'prod',
      baseUrl: 'https://prod.example.com',
      token: 'secret',
    );
    final existingManaged = ManagedService(
      id: 'managed-1',
      serviceName: 'nginx.service',
      pinnedAt: '2026-03-10T00:00:00Z',
    );

    final bundle = ExportBundle(
      version: 1,
      exportedAt: '2026-03-10T00:00:00Z',
      servers: [existingServer],
      managedServices: [existingManaged],
    );

    final preview = previewImport(
      bundle: bundle,
      existingServers: [existingServer],
      existingManagedServices: [existingManaged],
    );

    expect(preview.addedServers, 0);
    expect(preview.skippedServers, 1);
    expect(preview.addedManagedServices, 0);
    expect(preview.skippedManagedServices, 1);
    expect(preview.errors, isEmpty);
  });

  test('previewImport keeps managed services global across all servers', () {
    final existingServer = ServerProfile(
      id: 'server-1',
      name: 'prod',
      baseUrl: 'https://prod.example.com',
      token: 'secret',
    );
    final importedServer = ServerProfile(
      id: 'server-1',
      name: 'staging',
      baseUrl: 'https://staging.example.com',
      token: 'other',
    );
    final importedManaged = ManagedService(
      id: 'managed-1',
      serviceName: 'docker.service',
      pinnedAt: '2026-03-10T00:00:00Z',
    );

    final preview = previewImport(
      bundle: ExportBundle(
        version: 1,
        exportedAt: '2026-03-10T00:00:00Z',
        servers: [importedServer],
        managedServices: [importedManaged],
      ),
      existingServers: [existingServer],
      existingManagedServices: const [],
    );

    expect(preview.addedServers, 1);
    expect(preview.serversToInsert.single.id, isNot(importedServer.id));
    expect(preview.managedServicesToInsert.single.serviceName, 'docker.service');
    expect(preview.errors, isEmpty);
  });
}
