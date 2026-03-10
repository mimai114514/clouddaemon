import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'agent_api.dart';
import 'import_export.dart';
import 'models.dart';
import 'storage.dart';
import 'web_file_io.dart';

const _uuid = Uuid();
const appVersion = '1.0.0+1';

class CloudDaemonApp extends StatefulWidget {
  CloudDaemonApp({super.key, AppController? controller})
      : controller = controller ?? AppController();

  final AppController controller;

  @override
  State<CloudDaemonApp> createState() => _CloudDaemonAppState();
}

class _CloudDaemonAppState extends State<CloudDaemonApp> {
  late final AppController _controller;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloudDaemon',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (_controller.initializing) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          return Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth > 1120;
                  final sidebar = _ServerSidebar(
                    controller: _controller,
                    onAdd: () => _showServerForm(context),
                    onEdit: _controller.selectedServer == null
                        ? null
                        : () => _showServerForm(
                              context,
                              existing: _controller.selectedServer,
                            ),
                    onDelete: _controller.selectedServer == null
                        ? null
                        : () => _confirmDeleteServer(context),
                    onTrustSelfSigned: _controller.selectedServer == null
                        ? null
                        : () => _trustSelfSignedCertificate(
                              context,
                              _controller.selectedServer!,
                            ),
                    onImport: () => _importConfig(context),
                    onExport: _controller.servers.isEmpty
                        ? null
                        : () => _exportConfig(context),
                  );

                  final content = _DashboardContent(
                    controller: _controller,
                    selectedTab: _selectedTab,
                    onTabChanged: (index) => setState(() => _selectedTab = index),
                    onShowLogs: (server, serviceName) {
                      showDialog<void>(
                        context: context,
                        builder: (_) => ServiceLogsDialog(
                          server: server,
                          serviceName: serviceName,
                        ),
                      );
                    },
                  );

                  if (!wide) {
                    return Column(
                      children: [
                        Expanded(flex: 4, child: sidebar),
                        const SizedBox(height: 16),
                        Expanded(flex: 7, child: content),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      SizedBox(width: 330, child: sidebar),
                      const SizedBox(width: 24),
                      Expanded(child: content),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showServerForm(
    BuildContext context, {
    ServerProfile? existing,
  }) async {
    final result = await showDialog<ServerProfile>(
      context: context,
      builder: (_) => _ServerFormDialog(existing: existing),
    );
    if (result == null) {
      return;
    }
    await _controller.saveServer(result);
    if (context.mounted) {
      _showMessage(context, 'Server saved.');
    }
  }

  Future<void> _confirmDeleteServer(BuildContext context) async {
    final server = _controller.selectedServer;
    if (server == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('Delete ${server.name}?'),
            content: const Text(
              'This removes the server profile only. Managed service favorites stay available for other servers.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    await _controller.deleteSelectedServer();
    if (context.mounted) {
      _showMessage(context, 'Server deleted.');
    }
  }

  Future<void> _exportConfig(BuildContext context) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Export configuration'),
            content: const Text(
              'The exported JSON will include agent tokens. Keep the file somewhere safe.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Export'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    final content = encodeExportBundle(
      buildExportBundle(
        servers: _controller.servers,
        managedServices: _controller.managedServices,
      ),
    );
    final filename =
        'clouddaemon-export-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json';

    await downloadTextFile(filename: filename, content: content);
    if (context.mounted) {
      _showMessage(context, 'Export downloaded.');
    }
  }

  Future<void> _importConfig(BuildContext context) async {
    final content = await pickTextFile();
    if (!context.mounted) {
      return;
    }
    if (content == null || content.trim().isEmpty) {
      return;
    }
    if (!context.mounted) {
      return;
    }

    final preview = _controller.buildImportPreview(content);
    final approved = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Import preview'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add servers: ${preview.addedServers}'),
                Text('Skip servers: ${preview.skippedServers}'),
                Text('Add managed services: ${preview.addedManagedServices}'),
                Text('Skip managed services: ${preview.skippedManagedServices}'),
                Text('Errors: ${preview.errors.length}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Import'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved) {
      return;
    }

    await _controller.applyImportPreview(preview);
    if (context.mounted) {
      _showMessage(
        context,
        'Imported ${preview.addedServers} servers and ${preview.addedManagedServices} managed services.',
      );
    }
  }

  void _showMessage(BuildContext context, String message, {bool isError = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: isError ? colorScheme.error : colorScheme.primary,
        content: Text(message),
      ),
    );
  }

  Future<void> _trustSelfSignedCertificate(
    BuildContext context,
    ServerProfile server,
  ) async {
    final trustUrl = _buildTrustUrl(server.baseUrl);
    if (trustUrl == null) {
      _showMessage(
        context,
        'Agent URL 无法解析，请先检查节点地址。',
        isError: true,
      );
      return;
    }

    await openExternalUrl(trustUrl);
    if (context.mounted) {
      _showMessage(
        context,
        '已打开证书信任地址，请在新标签页里完成证书确认后再回到面板。',
      );
    }
  }
}

class AppController extends ChangeNotifier {
  AppController({AppStorage? storage}) : _storage = storage ?? AppStorage();

  final AppStorage _storage;

  bool initializing = true;
  bool refreshingCatalog = false;
  bool refreshingManaged = false;
  List<ServerProfile> servers = <ServerProfile>[];
  List<ManagedService> managedServices = <ManagedService>[];
  Map<String, PingInfo> serverPings = <String, PingInfo>{};
  Map<String, String> serverErrors = <String, String>{};
  Map<String, List<ServiceSummary>> discoveredServicesByServer = <String, List<ServiceSummary>>{};
  Map<String, ServiceSummary> managedStatuses = <String, ServiceSummary>{};
  Map<String, DateTime> managedRefreshedAt = <String, DateTime>{};
  String? selectedServerId;
  Timer? _refreshTimer;

  ServerProfile? get selectedServer {
    for (final server in servers) {
      if (server.id == selectedServerId) {
        return server;
      }
    }
    return servers.isEmpty ? null : servers.first;
  }

  List<ServiceSummary> get selectedServerServices {
    final server = selectedServer;
    if (server == null) {
      return const <ServiceSummary>[];
    }
    return discoveredServicesByServer[server.id] ?? const <ServiceSummary>[];
  }

  List<ManagedService> managedForSelectedServer() {
    return managedServices;
  }

  Future<void> initialize() async {
    await _storage.init();
    servers = await _storage.loadServers();
    managedServices = await _storage.loadManagedServices();
    selectedServerId = servers.isEmpty ? null : servers.first.id;
    initializing = false;
    notifyListeners();
    await refreshAll();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(refreshManagedStatuses()),
    );
  }

  Future<void> refreshAll() async {
    await Future.wait(<Future<void>>[
      refreshServerPings(),
      refreshManagedStatuses(),
      refreshDiscoveredServices(),
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
    await refreshDiscoveredServices();
    await refreshManagedStatuses();
  }

  Future<void> deleteSelectedServer() async {
    final server = selectedServer;
    if (server == null) {
      return;
    }
    await _storage.deleteServer(server.id);
    servers = servers.where((item) => item.id != server.id).toList();
    discoveredServicesByServer.remove(server.id);
    serverPings.remove(server.id);
    serverErrors.remove(server.id);
    selectedServerId = servers.isEmpty ? null : servers.first.id;
    notifyListeners();
    await refreshManagedStatuses();
  }

  Future<void> selectServer(String serverId) async {
    selectedServerId = serverId;
    notifyListeners();
    await Future.wait(<Future<void>>[
      refreshServerPing(selectedServer),
      refreshDiscoveredServices(),
      refreshManagedStatuses(),
    ]);
  }

  Future<void> refreshServerPings() async {
    await Future.wait(servers.map(refreshServerPing));
    notifyListeners();
  }

  Future<void> refreshServerPing(ServerProfile? server) async {
    if (server == null) {
      return;
    }
    try {
      final ping = await AgentApiClient(server).ping();
      serverPings = {...serverPings, server.id: ping};
      serverErrors.remove(server.id);
    } on ApiError catch (error) {
      serverErrors = {...serverErrors, server.id: error.message};
    }
    notifyListeners();
  }

  Future<void> refreshDiscoveredServices() async {
    final server = selectedServer;
    if (server == null) {
      return;
    }
    refreshingCatalog = true;
    notifyListeners();
    try {
      final services = await AgentApiClient(server).listServices();
      services.sort((a, b) => a.unitName.compareTo(b.unitName));
      discoveredServicesByServer = {
        ...discoveredServicesByServer,
        server.id: services,
      };
      serverErrors.remove(server.id);
    } on ApiError catch (error) {
      serverErrors = {...serverErrors, server.id: error.message};
    } finally {
      refreshingCatalog = false;
      notifyListeners();
    }
  }

  Future<void> addManagedService(ServiceSummary service) async {
    final exists = managedServices.any(
      (managed) => managed.serviceName == service.unitName,
    );
    if (exists) {
      return;
    }

    final managedService = ManagedService(
      id: _uuid.v4(),
      serviceName: service.unitName,
      pinnedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _storage.saveManagedService(managedService);
    managedServices = [...managedServices, managedService];
    notifyListeners();
    await refreshManagedStatuses();
  }

  Future<void> removeManagedService(String managedId) async {
    await _storage.deleteManagedService(managedId);
    managedServices = managedServices.where((item) => item.id != managedId).toList();
    managedStatuses.remove(managedId);
    managedRefreshedAt.remove(managedId);
    notifyListeners();
  }

  Future<void> refreshManagedStatuses() async {
    final server = selectedServer;
    if (managedServices.isEmpty || server == null) {
      managedStatuses = {};
      managedRefreshedAt = {};
      notifyListeners();
      return;
    }
    refreshingManaged = true;
    notifyListeners();

    final nextStatuses = <String, ServiceSummary>{};
    final nextRefreshedAt = <String, DateTime>{};

    await Future.wait(
      managedServices.map((managed) async {
        try {
          final summary =
              await AgentApiClient(server).getService(managed.serviceName);
          final key = _managedStatusKey(server.id, managed.id);
          nextStatuses[key] = summary;
          nextRefreshedAt[key] = DateTime.now();
        } on ApiError catch (error) {
          serverErrors = {...serverErrors, server.id: error.message};
        }
      }),
    );

    managedStatuses = nextStatuses;
    managedRefreshedAt = nextRefreshedAt;
    refreshingManaged = false;
    notifyListeners();
  }

  Future<void> performAction(ManagedService managedService, String action) async {
    final server = selectedServer;
    if (server == null) {
      throw ApiError('Server not found for ${managedService.serviceName}.');
    }
    final summary =
        await AgentApiClient(server).performAction(managedService.serviceName, action);
    final key = _managedStatusKey(server.id, managedService.id);
    managedStatuses = {...managedStatuses, key: summary};
    managedRefreshedAt = {
      ...managedRefreshedAt,
      key: DateTime.now(),
    };
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

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}

class _ServerSidebar extends StatelessWidget {
  const _ServerSidebar({
    required this.controller,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onTrustSelfSigned,
    required this.onImport,
    required this.onExport,
  });

  final AppController controller;
  final VoidCallback onAdd;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onTrustSelfSigned;
  final VoidCallback onImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            const Text(
              'CloudDaemon',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Direct browser-to-agent control for systemd services.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  label: const Text('Add VPS'),
                ),
                OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import'),
                ),
                OutlinedButton.icon(
                  onPressed: onExport,
                  icon: const Icon(Icons.download),
                  label: const Text('Export'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: onTrustSelfSigned,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Trust Cert'),
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: controller.servers.isEmpty
                  ? const Center(
                      child: Text('No servers yet. Add one to begin.'),
                    )
                  : ListView.separated(
                      itemCount: controller.servers.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final server = controller.servers[index];
                        final isSelected = server.id == controller.selectedServerId;
                        final ping = controller.serverPings[server.id];
                        final error = controller.serverErrors[server.id];
                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => unawaited(controller.selectServer(server.id)),
                          child: Ink(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              color: isSelected
                                  ? _selectionTint(context)
                                  : _panelColor(context),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  server.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  server.baseUrl,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _StatusBadge(
                                  label: error == null
                                      ? 'Online ${ping?.hostname ?? ''}'.trim()
                                      : 'Offline',
                                  color: error == null
                                      ? Theme.of(context).colorScheme.primary
                                      : _warningColor(context),
                                ),
                                if (error != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    error,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).colorScheme.error,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            Text(
              'Web app $appVersion',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.controller,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onShowLogs,
  });

  final AppController controller;
  final int selectedTab;
  final ValueChanged<int> onTabChanged;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controller.selectedServer?.name ?? 'Choose a server',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              controller.selectedServer?.baseUrl ??
                  'Add a VPS from the left panel to get started.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(value: 0, label: Text('Managed')),
                ButtonSegment<int>(value: 1, label: Text('Discover')),
                ButtonSegment<int>(value: 2, label: Text('Settings')),
              ],
              selected: {selectedTab},
              onSelectionChanged: (selection) => onTabChanged(selection.first),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: switch (selectedTab) {
                0 => _ManagedServicesView(
                    controller: controller,
                    onShowLogs: onShowLogs,
                  ),
                1 => _DiscoverServicesView(controller: controller),
                _ => _SettingsView(controller: controller),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ManagedServicesView extends StatelessWidget {
  const _ManagedServicesView({
    required this.controller,
    required this.onShowLogs,
  });

  final AppController controller;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    final items = controller.managedForSelectedServer();
    if (controller.selectedServer == null) {
      return const Center(child: Text('Select a server to view managed services.'));
    }
    if (items.isEmpty) {
      return const Center(
        child: Text('No managed services yet. Discover services and pin them here.'),
      );
    }

    return RefreshIndicator(
      onRefresh: controller.refreshManagedStatuses,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final managed = items[index];
          final statusKey = _managedStatusKey(controller.selectedServer!.id, managed.id);
          final summary = controller.managedStatuses[statusKey];
          final refreshedAt = controller.managedRefreshedAt[statusKey];
          final server = controller.selectedServer!;
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _surfaceCardColor(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            managed.serviceName,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(summary?.description ?? 'No service metadata yet.'),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => unawaited(controller.removeManagedService(managed.id)),
                      icon: const Icon(Icons.push_pin_outlined),
                      tooltip: 'Remove from managed list',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatusBadge(
                      label: 'active: ${summary?.activeState ?? 'unknown'}',
                      color: _activeColor(
                        summary?.activeState,
                        isDark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    _StatusBadge(
                      label: 'sub: ${summary?.subState ?? 'unknown'}',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    _StatusBadge(
                      label: 'load: ${summary?.loadState ?? 'unknown'}',
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    _StatusBadge(
                      label: refreshedAt == null
                          ? 'Not refreshed'
                          : 'Refreshed ${_relativeTime(refreshedAt)}',
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton(
                      onPressed: summary == null || !summary.canStart
                          ? null
                          : () => _runAction(context, controller, managed, 'start'),
                      child: const Text('Start'),
                    ),
                    FilledButton.tonal(
                      onPressed: summary == null || !summary.canRestart
                          ? null
                          : () => _runAction(context, controller, managed, 'restart'),
                      child: const Text('Restart'),
                    ),
                    OutlinedButton(
                      onPressed: summary == null || !summary.canStop
                          ? null
                          : () => _runAction(context, controller, managed, 'stop'),
                      child: const Text('Stop'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => onShowLogs(server, managed.serviceName),
                      icon: const Icon(Icons.subject),
                      label: const Text('Logs'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    AppController controller,
    ManagedService managed,
    String action,
  ) async {
    try {
      await controller.performAction(managed, action);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${managed.serviceName}: $action sent.')),
        );
      }
    } on ApiError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(error.message),
          ),
        );
      }
    }
  }
}

class _DiscoverServicesView extends StatefulWidget {
  const _DiscoverServicesView({required this.controller});

  final AppController controller;

  @override
  State<_DiscoverServicesView> createState() => _DiscoverServicesViewState();
}

class _DiscoverServicesViewState extends State<_DiscoverServicesView> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.controller.selectedServer;
    if (server == null) {
      return const Center(child: Text('Select a server to discover services.'));
    }

    final filtered = widget.controller.selectedServerServices.where((service) {
      if (_query.isEmpty) {
        return true;
      }
      final lower = _query.toLowerCase();
      return service.unitName.toLowerCase().contains(lower) ||
          service.description.toLowerCase().contains(lower);
    }).toList();

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Search services by name or description',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: widget.controller.refreshingCatalog
                  ? null
                  : () => unawaited(widget.controller.refreshDiscoveredServices()),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No services match the current filter.'))
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final service = filtered[index];
                    final isPinned = widget.controller.managedServices.any(
                      (managed) => managed.serviceName == service.unitName,
                    );
                    return Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: _surfaceCardColor(context),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  service.unitName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(service.description),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _StatusBadge(
                                      label: service.activeState,
                                      color: _activeColor(
                                        service.activeState,
                                        isDark:
                                            Theme.of(context).brightness ==
                                                Brightness.dark,
                                      ),
                                    ),
                                    _StatusBadge(
                                      label: service.subState,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.tonalIcon(
                            onPressed: isPinned
                                ? null
                                : () => unawaited(widget.controller.addManagedService(service)),
                            icon: const Icon(Icons.push_pin),
                            label: Text(isPinned ? 'Added' : 'Add'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _surfaceCardColor(context),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Project summary',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text('Servers configured: ${controller.servers.length}'),
              Text('Managed services pinned: ${controller.managedServices.length}'),
              Text('Web build: $appVersion'),
              const SizedBox(height: 12),
              const Text(
                'This PWA stores VPS profiles and managed services in IndexedDB inside this browser.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ServiceLogsDialog extends StatefulWidget {
  const ServiceLogsDialog({
    super.key,
    required this.server,
    required this.serviceName,
  });

  final ServerProfile server;
  final String serviceName;

  @override
  State<ServiceLogsDialog> createState() => _ServiceLogsDialogState();
}

class _ServiceLogsDialogState extends State<ServiceLogsDialog> {
  late final AgentApiClient _client;
  final List<LogEntry> _logs = <LogEntry>[];
  StreamSubscription<LogEntry>? _subscription;
  bool _loading = true;
  bool _tailing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = AgentApiClient(widget.server);
    unawaited(_loadRecentLogs());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _loadRecentLogs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final logs = await _client.getRecentLogs(widget.serviceName);
      if (!mounted) {
        return;
      }
      setState(() {
        _logs
          ..clear()
          ..addAll(logs);
      });
    } on ApiError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggleTail() async {
    if (_tailing) {
      await _subscription?.cancel();
      if (mounted) {
        setState(() => _tailing = false);
      }
      return;
    }

    setState(() {
      _tailing = true;
      _error = null;
    });
    _subscription = _client.tailLogs(widget.serviceName).listen(
      (log) {
        if (!mounted) {
          return;
        }
        setState(() => _logs.add(log));
      },
      onError: (Object error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _tailing = false;
          _error = error.toString();
        });
      },
      onDone: () {
        if (!mounted) {
          return;
        }
        setState(() => _tailing = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 960,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.serviceName} logs',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(widget.server.name),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _loadRecentLogs,
                  icon: const Icon(Icons.history),
                  label: const Text('Reload 200 lines'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _toggleTail,
                  icon: Icon(_tailing ? Icons.pause_circle : Icons.play_circle),
                  label: Text(_tailing ? 'Stop tail' : 'Start tail'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(_error!),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _logPanelBackground(context),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Text(
                              '[${log.ts}] ${log.line}',
                              style: TextStyle(
                                color: _logTextColor(context),
                                fontFamily: 'Courier',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({this.existing});

  final ServerProfile? existing;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _urlController =
        TextEditingController(text: widget.existing?.baseUrl ?? 'https://');
    _tokenController = TextEditingController(text: widget.existing?.token ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add VPS' : 'Edit VPS'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Server name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Agent base URL'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(labelText: 'Bearer token'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: const Icon(Icons.health_and_safety),
                  label: const Text('Test'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _openTrustPage,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Trust Cert'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _testResult ?? 'Ping the agent before saving if you want.',
                    style: TextStyle(
                      color: _testResult?.startsWith('Connected') ?? false
                          ? _successColor(context)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final server = ServerProfile(
              id: widget.existing?.id ?? _uuid.v4(),
              name: _nameController.text.trim(),
              baseUrl: _urlController.text.trim(),
              token: _tokenController.text.trim(),
            );
            Navigator.of(context).pop(server);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _testConnection() async {
    final server = ServerProfile(
      id: widget.existing?.id ?? 'preview',
      name: _nameController.text.trim(),
      baseUrl: _urlController.text.trim(),
      token: _tokenController.text.trim(),
    );
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final ping = await AgentApiClient(server).ping();
      if (!mounted) {
        return;
      }
      setState(() {
        _testResult = 'Connected to ${ping.hostname} (${ping.version})';
      });
    } on ApiError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _testResult = error.message);
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _openTrustPage() async {
    final trustUrl = _buildTrustUrl(_urlController.text.trim());
    if (trustUrl == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _testResult = '请输入正确的 Agent URL，再尝试信任证书。';
      });
      return;
    }

    await openExternalUrl(trustUrl);
    if (!mounted) {
      return;
    }
    setState(() {
      _testResult = '已打开证书信任地址，请在新标签页确认风险后再回来测试。';
    });
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF56B7F6),
    brightness: brightness,
  );

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF08131D) : const Color(0xFFF2F8FD),
    useMaterial3: true,
    fontFamily: 'Georgia',
    cardTheme: CardThemeData(
      color: isDark ? const Color(0xFF102231) : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF13293A) : const Color(0xFFF7FBFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? const Color(0xFF102231) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
  );
}

String _relativeTime(DateTime dateTime) {
  final delta = DateTime.now().difference(dateTime);
  if (delta.inSeconds < 60) {
    return '${delta.inSeconds}s ago';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes}m ago';
  }
  return '${delta.inHours}h ago';
}

String _managedStatusKey(String serverId, String managedId) {
  return '$serverId|$managedId';
}

Color _activeColor(String? state, {bool isDark = false}) {
  switch (state) {
    case 'active':
      return isDark ? const Color(0xFF65D6B3) : const Color(0xFF167D68);
    case 'failed':
      return isDark ? const Color(0xFFFF8A8A) : const Color(0xFFCC3D3D);
    case 'activating':
      return isDark ? const Color(0xFFFFC97A) : const Color(0xFFC77B1C);
    default:
      return isDark ? const Color(0xFF9EB7C9) : const Color(0xFF5A7386);
  }
}

Color _surfaceCardColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF122736) : const Color(0xFFF7FBFF);
}

Color _panelColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF102231) : const Color(0xFFF7FBFF);
}

Color _selectionTint(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF17364B) : const Color(0xFFD8F0FF);
}

Color _warningColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFFFC97A) : const Color(0xFFC77B1C);
}

Color _successColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF65D6B3) : const Color(0xFF167D68);
}

Color _logPanelBackground(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF06101A) : const Color(0xFF0C2232);
}

Color _logTextColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFE3F2FF) : const Color(0xFFE8F6FF);
}

String? _buildTrustUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return null;
  }

  final basePath = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;

  return uri.replace(path: '$basePath/api/v1/ping').toString();
}
