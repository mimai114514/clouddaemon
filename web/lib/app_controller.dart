import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'agent_api.dart';
import 'import_export.dart';
import 'models.dart';
import 'storage.dart';

const _uuid = Uuid();

typedef AgentClientFactory = AgentClient Function(ServerProfile server);

abstract class AgentClient {
  Future<PingInfo> ping();

  Future<List<ServiceSummary>> listServices({String? query});

  Future<ServiceSummary> getService(String serviceName);

  Future<ServiceSummary> performAction(String serviceName, String action);
}

class HttpAgentClient implements AgentClient {
  HttpAgentClient(ServerProfile server) : _client = AgentApiClient(server);

  final AgentApiClient _client;

  @override
  Future<PingInfo> ping() => _client.ping();

  @override
  Future<List<ServiceSummary>> listServices({String? query}) {
    return _client.listServices(query: query);
  }

  @override
  Future<ServiceSummary> getService(String serviceName) {
    return _client.getService(serviceName);
  }

  @override
  Future<ServiceSummary> performAction(String serviceName, String action) {
    return _client.performAction(serviceName, action);
  }
}

class ManagedServicePlacement {
  ManagedServicePlacement({
    required this.managedService,
    required this.server,
    required this.summary,
    required this.refreshedAt,
    required this.ping,
    required this.error,
  });

  final ManagedService managedService;
  final ServerProfile server;
  final ServiceSummary? summary;
  final DateTime? refreshedAt;
  final PingInfo? ping;
  final String? error;

  bool get actionsEnabled => error == null && summary != null;
}

class ManagedServiceGroup {
  ManagedServiceGroup({
    required this.managedService,
    required this.entries,
  });

  final ManagedService managedService;
  final List<ManagedServicePlacement> entries;
}

class ServerManagedServicesSection {
  ServerManagedServicesSection({
    required this.server,
    required this.ping,
    required this.error,
    required this.entries,
  });

  final ServerProfile server;
  final PingInfo? ping;
  final String? error;
  final List<ManagedServicePlacement> entries;
}

class AppController extends ChangeNotifier {
  AppController({
    AppStorage? storage,
    AgentClientFactory? clientFactory,
  })  : _storage = storage ?? AppStorage(),
        _clientFactory =
            clientFactory ?? ((server) => HttpAgentClient(server));

  final AppStorage _storage;
  final AgentClientFactory _clientFactory;

  Future<void>? _initializeFuture;
  Timer? _refreshTimer;

  bool initializing = true;
  bool refreshingCatalog = false;
  bool refreshingManaged = false;
  List<ServerProfile> servers = <ServerProfile>[];
  List<ManagedService> managedServices = <ManagedService>[];
  Map<String, PingInfo> serverPings = <String, PingInfo>{};
  Map<String, String> serverErrors = <String, String>{};
  Map<String, List<ServiceSummary>> discoveredServicesByServer =
      <String, List<ServiceSummary>>{};
  Map<String, ServiceSummary> managedStatuses = <String, ServiceSummary>{};
  Map<String, DateTime> managedRefreshedAt = <String, DateTime>{};
  String? selectedServerId;

  Future<void> initialize() {
    return _initializeFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    await _storage.init();
    servers = await _storage.loadServers();
    managedServices = await _storage.loadManagedServices();
    selectedServerId = servers.isEmpty ? null : servers.first.id;
    initializing = false;
    notifyListeners();
    await refreshAll();
    _refreshTimer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(refreshManagedStatuses()),
    );
  }

  ServerProfile? get selectedServer {
    final serverId = selectedServerId;
    if (serverId == null) {
      return servers.isEmpty ? null : servers.first;
    }
    return serverById(serverId) ?? (servers.isEmpty ? null : servers.first);
  }

  ServerProfile? serverById(String serverId) {
    for (final server in servers) {
      if (server.id == serverId) {
        return server;
      }
    }
    return null;
  }

  List<ServiceSummary> servicesForServer(String serverId) {
    return discoveredServicesByServer[serverId] ?? const <ServiceSummary>[];
  }

  bool isManagedServiceTracked(String serviceName) {
    return managedServices.any((managed) => managed.serviceName == serviceName);
  }

  List<ManagedServiceGroup> buildManagedServiceGroups() {
    final groups = <ManagedServiceGroup>[];
    final sortedManaged = [...managedServices]
      ..sort((a, b) => a.serviceName.compareTo(b.serviceName));

    for (final managed in sortedManaged) {
      final entries = <ManagedServicePlacement>[];
      for (final server in servers) {
        if (!_serverContainsService(server.id, managed.serviceName)) {
          continue;
        }

        entries.add(
          ManagedServicePlacement(
            managedService: managed,
            server: server,
            summary: statusFor(server.id, managed.serviceName),
            refreshedAt: refreshedAtFor(server.id, managed.serviceName),
            ping: serverPings[server.id],
            error: serverErrors[server.id],
          ),
        );
      }
      groups.add(ManagedServiceGroup(managedService: managed, entries: entries));
    }

    return groups;
  }

  List<ServerManagedServicesSection> buildServerSections() {
    final sections = <ServerManagedServicesSection>[];

    for (final server in servers) {
      final entries = <ManagedServicePlacement>[];
      for (final managed in managedServices) {
        if (!_serverContainsService(server.id, managed.serviceName)) {
          continue;
        }

        entries.add(
          ManagedServicePlacement(
            managedService: managed,
            server: server,
            summary: statusFor(server.id, managed.serviceName),
            refreshedAt: refreshedAtFor(server.id, managed.serviceName),
            ping: serverPings[server.id],
            error: serverErrors[server.id],
          ),
        );
      }

      entries.sort(
        (a, b) => a.managedService.serviceName.compareTo(
          b.managedService.serviceName,
        ),
      );

      sections.add(
        ServerManagedServicesSection(
          server: server,
          ping: serverPings[server.id],
          error: serverErrors[server.id],
          entries: entries,
        ),
      );
    }

    return sections;
  }

  ServiceSummary? statusFor(String serverId, String serviceName) {
    return managedStatuses[_managedStatusKey(serverId, serviceName)];
  }

  DateTime? refreshedAtFor(String serverId, String serviceName) {
    return managedRefreshedAt[_managedStatusKey(serverId, serviceName)];
  }

  Future<void> refreshAll() async {
    if (servers.isEmpty) {
      managedStatuses = <String, ServiceSummary>{};
      managedRefreshedAt = <String, DateTime>{};
      discoveredServicesByServer = <String, List<ServiceSummary>>{};
      notifyListeners();
      return;
    }

    await Future.wait(<Future<void>>[
      refreshServerPings(),
      refreshDiscoveredServicesForAll(),
      refreshManagedStatuses(),
    ]);
  }

  Future<void> saveServer(ServerProfile server) async {
    await _storage.saveServer(server);
    final existingIndex = servers.indexWhere((item) => item.id == server.id);
    if (existingIndex == -1) {
      servers = [...servers, server];
    } else {
      servers = [...servers]..[existingIndex] = server;
    }

    selectedServerId = server.id;
    notifyListeners();
    await refreshServerPing(server);
    await refreshDiscoveredServicesForServer(server.id);
    await refreshManagedStatuses();
  }

  Future<void> deleteServer(String serverId) async {
    final server = serverById(serverId);
    if (server == null) {
      return;
    }

    await _storage.deleteServer(server.id);
    servers = servers.where((item) => item.id != server.id).toList();
    discoveredServicesByServer = {
      for (final entry in discoveredServicesByServer.entries)
        if (entry.key != server.id) entry.key: entry.value,
    };
    serverPings = {
      for (final entry in serverPings.entries)
        if (entry.key != server.id) entry.key: entry.value,
    };
    serverErrors = {
      for (final entry in serverErrors.entries)
        if (entry.key != server.id) entry.key: entry.value,
    };
    managedStatuses = {
      for (final entry in managedStatuses.entries)
        if (!entry.key.startsWith('${server.id}|')) entry.key: entry.value,
    };
    managedRefreshedAt = {
      for (final entry in managedRefreshedAt.entries)
        if (!entry.key.startsWith('${server.id}|')) entry.key: entry.value,
    };

    if (selectedServerId == server.id) {
      selectedServerId = servers.isEmpty ? null : servers.first.id;
    }

    notifyListeners();
    await refreshManagedStatuses();
  }

  void setSelectedServerContext(String? serverId) {
    if (serverId == null || selectedServerId == serverId) {
      return;
    }
    selectedServerId = serverId;
    notifyListeners();
  }

  Future<void> refreshServerPings() async {
    if (servers.isEmpty) {
      serverPings = <String, PingInfo>{};
      notifyListeners();
      return;
    }

    await Future.wait(servers.map(refreshServerPing));
    notifyListeners();
  }

  Future<void> refreshServerPing(ServerProfile? server) async {
    if (server == null) {
      return;
    }

    try {
      final ping = await _clientFactory(server).ping();
      serverPings = {...serverPings, server.id: ping};
      serverErrors = {
        for (final entry in serverErrors.entries)
          if (entry.key != server.id) entry.key: entry.value,
      };
    } on ApiError catch (error) {
      serverErrors = {...serverErrors, server.id: error.message};
    }

    notifyListeners();
  }

  Future<void> ensureDiscoveredServices(String serverId) async {
    if (discoveredServicesByServer.containsKey(serverId)) {
      return;
    }
    await refreshDiscoveredServicesForServer(serverId);
  }

  Future<void> refreshDiscoveredServicesForAll() async {
    if (servers.isEmpty) {
      discoveredServicesByServer = <String, List<ServiceSummary>>{};
      notifyListeners();
      return;
    }

    refreshingCatalog = true;
    notifyListeners();

    final nextCatalog = <String, List<ServiceSummary>>{
      ...discoveredServicesByServer,
    };

    try {
      for (final server in servers) {
        final services = await _loadCatalog(server);
        if (services != null) {
          nextCatalog[server.id] = services;
        }
      }
      discoveredServicesByServer = nextCatalog;
    } finally {
      refreshingCatalog = false;
      notifyListeners();
    }
  }

  Future<void> refreshDiscoveredServicesForServer(String serverId) async {
    final server = serverById(serverId);
    if (server == null) {
      return;
    }

    refreshingCatalog = true;
    notifyListeners();
    try {
      final services = await _loadCatalog(server);
      if (services != null) {
        discoveredServicesByServer = {
          ...discoveredServicesByServer,
          server.id: services,
        };
      }
    } finally {
      refreshingCatalog = false;
      notifyListeners();
    }
  }

  Future<List<ServiceSummary>?> _loadCatalog(ServerProfile server) async {
    try {
      final services = await _clientFactory(server).listServices();
      services.sort((a, b) => a.unitName.compareTo(b.unitName));
      serverErrors = {
        for (final entry in serverErrors.entries)
          if (entry.key != server.id) entry.key: entry.value,
      };
      return services;
    } on ApiError catch (error) {
      serverErrors = {...serverErrors, server.id: error.message};
      return null;
    }
  }

  Future<bool> addManagedServiceFromServer(
    String serverId,
    ServiceSummary service,
  ) async {
    if (isManagedServiceTracked(service.unitName)) {
      selectedServerId = serverId;
      notifyListeners();
      return false;
    }

    final managedService = ManagedService(
      id: _uuid.v4(),
      serviceName: service.unitName,
      pinnedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _storage.saveManagedService(managedService);
    managedServices = [...managedServices, managedService];
    selectedServerId = serverId;
    notifyListeners();
    await refreshManagedStatuses();
    return true;
  }

  Future<void> removeManagedService(String managedId) async {
    ManagedService? managed;
    for (final item in managedServices) {
      if (item.id == managedId) {
        managed = item;
        break;
      }
    }
    if (managed == null) {
      return;
    }

    await _storage.deleteManagedService(managedId);
    managedServices = managedServices.where((item) => item.id != managedId).toList();
    managedStatuses = {
      for (final entry in managedStatuses.entries)
        if (!entry.key.endsWith('|${managed.serviceName}')) entry.key: entry.value,
    };
    managedRefreshedAt = {
      for (final entry in managedRefreshedAt.entries)
        if (!entry.key.endsWith('|${managed.serviceName}')) entry.key: entry.value,
    };
    notifyListeners();
  }

  Future<void> refreshManagedStatuses() async {
    if (managedServices.isEmpty || servers.isEmpty) {
      managedStatuses = <String, ServiceSummary>{};
      managedRefreshedAt = <String, DateTime>{};
      notifyListeners();
      return;
    }

    refreshingManaged = true;
    notifyListeners();

    final nextStatuses = <String, ServiceSummary>{};
    final nextRefreshedAt = <String, DateTime>{};

    try {
      for (final server in servers) {
        for (final managed in managedServices) {
          try {
            final summary =
                await _clientFactory(server).getService(managed.serviceName);
            final key = _managedStatusKey(server.id, managed.serviceName);
            nextStatuses[key] = summary;
            nextRefreshedAt[key] = DateTime.now();
            serverErrors = {
              for (final entry in serverErrors.entries)
                if (entry.key != server.id) entry.key: entry.value,
            };
          } on ApiError catch (error) {
            if (error.isNotFound) {
              continue;
            }
            serverErrors = {...serverErrors, server.id: error.message};
            if (error.category != ApiErrorCategory.command) {
              break;
            }
          }
        }
      }

      managedStatuses = nextStatuses;
      managedRefreshedAt = nextRefreshedAt;
    } finally {
      refreshingManaged = false;
      notifyListeners();
    }
  }

  Future<void> performAction(
    ServerProfile server,
    ManagedService managedService,
    String action,
  ) async {
    final summary = await _clientFactory(server).performAction(
      managedService.serviceName,
      action,
    );
    final key = _managedStatusKey(server.id, managedService.serviceName);
    managedStatuses = {...managedStatuses, key: summary};
    managedRefreshedAt = {...managedRefreshedAt, key: DateTime.now()};
    notifyListeners();
  }

  ImportPreview buildImportPreview(String content) {
    final bundle = decodeExportBundle(content);
    return previewImport(
      bundle: bundle,
      existingServers: servers,
      existingManagedServices: managedServices,
    );
  }

  Future<void> applyImportPreview(ImportPreview preview) async {
    for (final server in preview.serversToInsert) {
      await _storage.saveServer(server);
    }
    for (final managedService in preview.managedServicesToInsert) {
      await _storage.saveManagedService(managedService);
    }
    servers = await _storage.loadServers();
    managedServices = await _storage.loadManagedServices();
    selectedServerId ??= servers.isEmpty ? null : servers.first.id;
    notifyListeners();
    await refreshAll();
  }

  bool _serverContainsService(String serverId, String serviceName) {
    if (managedStatuses.containsKey(_managedStatusKey(serverId, serviceName))) {
      return true;
    }

    final discovered = discoveredServicesByServer[serverId];
    if (discovered == null) {
      return false;
    }

    return discovered.any((service) => service.unitName == serviceName);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}

String _managedStatusKey(String serverId, String serviceName) {
  return '$serverId|$serviceName';
}
