import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'agent_api.dart';
import 'app_controller.dart';
import 'import_export.dart';
import 'models.dart';
import 'web_file_io.dart';

export 'app_controller.dart';

const _uuid = Uuid();
const ciCdDeployTime = String.fromEnvironment(
  'CI_CD_DEPLOY_TIME',
  defaultValue: 'local build',
);

enum _AppPage { services, servers }

class CloudDaemonApp extends StatefulWidget {
  CloudDaemonApp({super.key, AppController? controller})
      : controller = controller ?? AppController();

  final AppController controller;

  @override
  State<CloudDaemonApp> createState() => _CloudDaemonAppState();
}

class _CloudDaemonAppState extends State<CloudDaemonApp> {
  late final AppController _controller;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  _AppPage _currentPage = _AppPage.services;

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
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
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

          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1120;
              final navigation = _AppNavigationDrawer(
                currentPage: _currentPage,
                onSelect: (page) {
                  setState(() => _currentPage = page);
                  if (!wide) {
                    Navigator.of(context).maybePop();
                  }
                },
              );

              return Scaffold(
                appBar: wide
                    ? null
                    : AppBar(
                        title: Text(_pageLabel(_currentPage)),
                      ),
                drawer: wide ? null : Drawer(child: navigation),
                body: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(wide ? 24 : 16),
                    child: wide
                        ? Row(
                            children: [
                              SizedBox(width: 280, child: navigation),
                              const SizedBox(width: 24),
                              Expanded(child: _buildPageContent()),
                            ],
                          )
                        : _buildPageContent(),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPageContent() {
    return switch (_currentPage) {
      _AppPage.services => _ServicesPage(
          controller: _controller,
          onAddManagedService: () => _showManagedServicePicker(context),
          onShowLogs: _showLogs,
        ),
      _AppPage.servers => _ServersPage(
          controller: _controller,
          onAddServer: () => _showServerForm(context),
          onEditServer: (server) => _showServerForm(context, existing: server),
          onDeleteServer: (server) => _confirmDeleteServer(context, server),
          onImport: () => _importConfig(context),
          onExport: () => _exportConfig(context),
          onAddManagedServiceForServer: (serverId) => _showManagedServicePicker(
            context,
            initialServerId: serverId,
            fixedServer: true,
          ),
          onShowLogs: _showLogs,
        ),
    };
  }

  void _showLogs(ServerProfile server, String serviceName) {
    showDialog<void>(
      context: _navigatorKey.currentContext ?? context,
      builder: (_) => ServiceLogsDialog(
        server: server,
        serviceName: serviceName,
      ),
    );
  }

  Future<void> _showManagedServicePicker(
    BuildContext context, {
    String? initialServerId,
    bool fixedServer = false,
  }) async {
    final addedService = await showDialog<String>(
      context: _navigatorKey.currentContext ?? context,
      builder: (_) => _ManagedServicePickerDialog(
        controller: _controller,
        initialServerId: initialServerId,
        fixedServer: fixedServer,
      ),
    );
    if (!context.mounted || addedService == null) {
      return;
    }

    _showMessage(context, '$addedService added to managed services.');
  }

  Future<void> _showServerForm(
    BuildContext context, {
    ServerProfile? existing,
  }) async {
    final result = await showDialog<ServerProfile>(
      context: _navigatorKey.currentContext ?? context,
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

  Future<void> _confirmDeleteServer(
    BuildContext context,
    ServerProfile server,
  ) async {
    final confirmed = await showDialog<bool>(
          context: _navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Delete ${server.name}?'),
            content: const Text(
              'This removes the server profile only. Managed service favorites stay available for other servers.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    await _controller.deleteServer(server.id);
    if (context.mounted) {
      _showMessage(context, 'Server deleted.');
    }
  }

  Future<void> _exportConfig(BuildContext context) async {
    if (_controller.servers.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: _navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Export configuration'),
            content: const Text(
              'The exported JSON will include agent tokens. Keep the file somewhere safe.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
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
    if (!context.mounted || content == null || content.trim().isEmpty) {
      return;
    }

    final preview = _controller.buildImportPreview(content);
    final approved = await showDialog<bool>(
          context: _navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
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
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
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

  void _showMessage(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        backgroundColor: isError ? colorScheme.error : colorScheme.primary,
        content: Text(message),
      ),
    );
  }
}

class _AppNavigationDrawer extends StatelessWidget {
  const _AppNavigationDrawer({
    required this.currentPage,
    required this.onSelect,
  });

  final _AppPage currentPage;
  final ValueChanged<_AppPage> onSelect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: NavigationDrawer(
        selectedIndex: currentPage.index,
        onDestinationSelected: (index) => onSelect(_AppPage.values[index]),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CloudDaemon',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const NavigationDrawerDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: Text('Services'),
          ),
          const SizedBox(height: 10),
          const NavigationDrawerDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: Text('Servers'),
          ),
        ],
      ),
    );
  }
}

class _ServicesPage extends StatelessWidget {
  const _ServicesPage({
    required this.controller,
    required this.onAddManagedService,
    required this.onShowLogs,
  });

  final AppController controller;
  final VoidCallback onAddManagedService;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    final groups = controller.buildManagedServiceGroups();

    return _ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeader(
            title: 'Services',
            subtitle:
                'Managed services grouped by unit, with live status across the servers that currently expose them.',
            actions: [
              FilledButton.icon(
                key: const ValueKey('open-global-add-dialog'),
                onPressed: controller.servers.isEmpty ? null : onAddManagedService,
                icon: const Icon(Icons.add),
                label: const Text('Add managed service'),
              ),
              FilledButton.tonalIcon(
                onPressed: controller.refreshingManaged && controller.refreshingCatalog
                    ? null
                    : () => unawaited(controller.refreshAll()),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh all'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (controller.servers.isEmpty)
            const Expanded(
              child: _EmptyState(
                title: 'No servers yet',
                message: 'Switch to the Servers page to add your first VPS.',
              ),
            )
          else if (groups.isEmpty)
            const Expanded(
              child: _EmptyState(
                title: 'No managed services yet',
                message:
                    'Use the + button to choose a server, search its services, and add a managed unit.',
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.refreshAll,
                child: ListView.separated(
                  itemCount: groups.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return _ServiceGroupCard(
                      group: group,
                      controller: controller,
                      onShowLogs: onShowLogs,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ServersPage extends StatelessWidget {
  const _ServersPage({
    required this.controller,
    required this.onAddServer,
    required this.onEditServer,
    required this.onDeleteServer,
    required this.onImport,
    required this.onExport,
    required this.onAddManagedServiceForServer,
    required this.onShowLogs,
  });

  final AppController controller;
  final VoidCallback onAddServer;
  final ValueChanged<ServerProfile> onEditServer;
  final ValueChanged<ServerProfile> onDeleteServer;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final ValueChanged<String> onAddManagedServiceForServer;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    final sections = controller.buildServerSections();

    return _ContentShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeader(
            title: 'Servers',
            subtitle:
                'Fleet overview first, then per-server managed services and maintenance actions.',
            actions: [
              FilledButton.icon(
                onPressed: onAddServer,
                icon: const Icon(Icons.add),
                label: const Text('Add server'),
              ),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import'),
              ),
              OutlinedButton.icon(
                onPressed: controller.servers.isEmpty ? null : onExport,
                icon: const Icon(Icons.download),
                label: const Text('Export'),
              ),
              FilledButton.tonalIcon(
                onPressed: controller.refreshingManaged && controller.refreshingCatalog
                    ? null
                    : () => unawaited(controller.refreshAll()),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh all'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _SummaryChip(
                label: 'Servers configured',
                value: '${controller.servers.length}',
              ),
              _SummaryChip(
                label: 'Managed services',
                value: '${controller.managedServices.length}',
              ),
              const _SummaryChip(
                label: 'Web build',
                value: ciCdDeployTime,
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (sections.isEmpty)
            const Expanded(
              child: _EmptyState(
                title: 'No servers configured',
                message: 'Add a server to start discovering and managing services.',
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.refreshAll,
                child: ListView.separated(
                  itemCount: sections.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final section = sections[index];
                    return _ServerSectionCard(
                      section: section,
                      controller: controller,
                      onEditServer: onEditServer,
                      onDeleteServer: onDeleteServer,
                      onAddManagedService: onAddManagedServiceForServer,
                      onShowLogs: onShowLogs,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ContentShell extends StatelessWidget {
  const _ContentShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: child,
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: actions),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceCardColor(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _ServiceGroupCard extends StatelessWidget {
  const _ServiceGroupCard({
    required this.group,
    required this.controller,
    required this.onShowLogs,
  });

  final ManagedServiceGroup group;
  final AppController controller;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('service-group-${group.managedService.serviceName}'),
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
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      group.managedService.serviceName,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    _ListStateChip(label: '${group.entries.length}'),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove managed service',
                onPressed: () =>
                    unawaited(controller.removeManagedService(group.managedService.id)),
                icon: const Icon(Icons.push_pin_outlined),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (group.entries.isEmpty)
            Text(
              'No known servers currently expose this unit.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            Column(
              children: [
                for (var i = 0; i < group.entries.length; i++) ...[
                  _ManagedServiceRow(
                    key: ValueKey(
                      'service-row-${group.managedService.serviceName}-${group.entries[i].server.id}',
                    ),
                    controller: controller,
                    placement: group.entries[i],
                    onShowLogs: onShowLogs,
                    showServerLabel: true,
                  ),
                  if (i < group.entries.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _ServerSectionCard extends StatelessWidget {
  const _ServerSectionCard({
    required this.section,
    required this.controller,
    required this.onEditServer,
    required this.onDeleteServer,
    required this.onAddManagedService,
    required this.onShowLogs,
  });

  final ServerManagedServicesSection section;
  final AppController controller;
  final ValueChanged<ServerProfile> onEditServer;
  final ValueChanged<ServerProfile> onDeleteServer;
  final ValueChanged<String> onAddManagedService;
  final void Function(ServerProfile server, String serviceName) onShowLogs;

  @override
  Widget build(BuildContext context) {
    final server = section.server;

    return Container(
      key: ValueKey('server-card-${server.id}'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surfaceCardColor(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            server.name,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _StatusBadge(
                          label: section.error == null ? 'online' : 'offline',
                          color: section.error == null
                              ? Theme.of(context).colorScheme.primary
                              : _warningColor(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(server.baseUrl),
                    if (section.error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        section.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: ValueKey('open-add-dialog-${server.id}'),
                    onPressed: () => onAddManagedService(server.id),
                    icon: const Icon(Icons.add),
                    label: const Text('Add service'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onEditServer(server),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onDeleteServer(server),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text(
                'Managed services',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              _ListStateChip(label: '${section.entries.length}'),
            ],
          ),
          const SizedBox(height: 12),
          if (section.entries.isEmpty)
            Text(
              'No managed services currently exist on this server.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            Column(
              children: [
                for (var i = 0; i < section.entries.length; i++) ...[
                  _ManagedServiceRow(
                    key: ValueKey(
                      'server-row-${server.id}-${section.entries[i].managedService.serviceName}',
                    ),
                    controller: controller,
                    placement: section.entries[i],
                    onShowLogs: onShowLogs,
                    showServerLabel: false,
                  ),
                  if (i < section.entries.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _ManagedServiceRow extends StatelessWidget {
  const _ManagedServiceRow({
    super.key,
    required this.controller,
    required this.placement,
    required this.onShowLogs,
    required this.showServerLabel,
  });

  final AppController controller;
  final ManagedServicePlacement placement;
  final void Function(ServerProfile server, String serviceName) onShowLogs;
  final bool showServerLabel;

  @override
  Widget build(BuildContext context) {
    final summary = placement.summary;
    final primaryAction = _primaryAction(summary);
    final showCompactServiceLayout = showServerLabel;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panelColor(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            showCompactServiceLayout
                                ? placement.server.name
                                : placement.managedService.serviceName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (!showCompactServiceLayout && placement.error != null)
                          _StatusBadge(
                            label: 'Server issue',
                            color: _warningColor(context),
                          ),
                      ],
                    ),
                    if (!showCompactServiceLayout) ...[
                      const SizedBox(height: 4),
                      Text(
                        summary?.description.isNotEmpty == true
                            ? summary!.description
                            : 'No service metadata yet.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (showCompactServiceLayout) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (summary != null)
                  _StatusBadge(
                    key: ValueKey(
                      'service-state-${placement.managedService.serviceName}-${placement.server.id}',
                    ),
                    label: summary.activeState,
                    color: _activeColor(summary.activeState),
                  ),
                const Spacer(),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.end,
                      children: [
                        if (primaryAction != null)
                          FilledButton.icon(
                            key: ValueKey(
                              'primary-action-${placement.managedService.serviceName}-${placement.server.id}',
                            ),
                            onPressed: () => _runAction(context, primaryAction),
                            icon: Icon(
                              primaryAction == 'stop'
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline,
                            ),
                            label: Text(primaryAction == 'stop' ? 'Stop' : 'Start'),
                          ),
                        FilledButton.tonalIcon(
                          key: ValueKey(
                            'restart-action-${placement.managedService.serviceName}-${placement.server.id}',
                          ),
                          onPressed: summary == null || !summary.canRestart
                              ? null
                              : () => _runAction(context, 'restart'),
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('Restart'),
                        ),
                        OutlinedButton.icon(
                          key: ValueKey(
                            'logs-action-${placement.managedService.serviceName}-${placement.server.id}',
                          ),
                          onPressed: summary == null
                              ? null
                              : () => onShowLogs(
                                    placement.server,
                                    placement.managedService.serviceName,
                                  ),
                          icon: const Icon(Icons.subject),
                          label: const Text('Logs'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (!showCompactServiceLayout) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusBadge(
                  label: 'active: ${summary?.activeState ?? 'unknown'}',
                  color: _activeColor(summary?.activeState),
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
                  label: placement.refreshedAt == null
                      ? 'Not refreshed'
                      : 'Refreshed ${_relativeTime(placement.refreshedAt!)}',
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ],
            ),
          ],
          if (placement.error != null) ...[
            const SizedBox(height: 10),
            Text(
              placement.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (!showCompactServiceLayout) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: summary == null || !summary.canStart
                      ? null
                      : () => _runAction(context, 'start'),
                  child: const Text('Start'),
                ),
                FilledButton.tonal(
                  onPressed: summary == null || !summary.canRestart
                      ? null
                      : () => _runAction(context, 'restart'),
                  child: const Text('Restart'),
                ),
                OutlinedButton(
                  onPressed: summary == null || !summary.canStop
                      ? null
                      : () => _runAction(context, 'stop'),
                  child: const Text('Stop'),
                ),
                OutlinedButton.icon(
                  onPressed: summary == null
                      ? null
                      : () => onShowLogs(
                            placement.server,
                            placement.managedService.serviceName,
                          ),
                  icon: const Icon(Icons.subject),
                  label: const Text('Logs'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String? _primaryAction(ServiceSummary? summary) {
    if (summary == null) {
      return null;
    }
    if (summary.activeState == 'active' && summary.canStop) {
      return 'stop';
    }
    if (summary.activeState != 'active' && summary.canStart) {
      return 'start';
    }
    return null;
  }

  Future<void> _runAction(BuildContext context, String action) async {
    try {
      await controller.performAction(
        placement.server,
        placement.managedService,
        action,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${placement.managedService.serviceName}: $action sent.'),
        ),
      );
    } on ApiError catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(error.message),
        ),
      );
    }
  }
}

class _ManagedServicePickerDialog extends StatefulWidget {
  const _ManagedServicePickerDialog({
    required this.controller,
    this.initialServerId,
    required this.fixedServer,
  });

  final AppController controller;
  final String? initialServerId;
  final bool fixedServer;

  @override
  State<_ManagedServicePickerDialog> createState() =>
      _ManagedServicePickerDialogState();
}

class _ManagedServicePickerDialogState extends State<_ManagedServicePickerDialog> {
  final TextEditingController _searchController = TextEditingController();

  String? _selectedServerId;
  String? _selectedServiceName;
  String _query = '';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _selectedServerId = widget.initialServerId ??
        widget.controller.selectedServerId ??
        (widget.controller.servers.isEmpty ? null : widget.controller.servers.first.id);
    if (_selectedServerId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedServerId != null) {
          unawaited(_loadCatalog(_selectedServerId!, forceRefresh: false));
        }
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add managed service'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final selectedServer = _selectedServerId == null
                ? null
                : widget.controller.serverById(_selectedServerId!);
            final services = selectedServer == null
                ? const <ServiceSummary>[]
                : widget.controller.servicesForServer(selectedServer.id);
            final filtered = services.where((service) {
              if (_query.isEmpty) {
                return true;
              }

              final lower = _query.toLowerCase();
              return service.unitName.toLowerCase().contains(lower) ||
                  service.description.toLowerCase().contains(lower);
            }).toList();

            final selectedService = _selectedFrom(filtered, _selectedServiceName);
            final alreadyAdded = selectedService != null &&
                widget.controller.isManagedServiceTracked(selectedService.unitName);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.fixedServer) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedServer?.id,
                    decoration: const InputDecoration(labelText: 'Server'),
                    items: [
                      for (final server in widget.controller.servers)
                        DropdownMenuItem<String>(
                          value: server.id,
                          child: Text(server.name),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedServerId = value;
                        _selectedServiceName = null;
                      });
                      unawaited(_loadCatalog(value, forceRefresh: false));
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: 'Search services by name or description',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) =>
                            setState(() => _query = value.trim()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: _selectedServerId == null || widget.controller.refreshingCatalog
                          ? null
                          : () => unawaited(
                                _loadCatalog(_selectedServerId!, forceRefresh: true),
                              ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_selectedServerId != null &&
                    widget.controller.serverErrors[_selectedServerId!] != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(widget.controller.serverErrors[_selectedServerId!]!),
                  ),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text(
                            'No services match the current server and search filter.',
                          ),
                        )
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final service = filtered[index];
                            final isAdded = widget.controller
                                .isManagedServiceTracked(service.unitName);
                            final isSelected =
                                _selectedServiceName == service.unitName;

                            return ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              tileColor: isSelected
                                  ? _selectionTint(context)
                                  : _panelColor(context),
                              enabled: !isAdded,
                              title: Text(service.unitName),
                              subtitle: Text(
                                service.description.isEmpty
                                    ? 'No description'
                                    : service.description,
                              ),
                              trailing: isAdded
                                  ? const _ListStateChip(label: 'Added')
                                  : isSelected
                                      ? const Icon(Icons.check_circle)
                                      : null,
                              onTap: isAdded
                                  ? null
                                  : () => setState(
                                        () => _selectedServiceName = service.unitName,
                                      ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Managed services stay global. Choosing a server here only decides which catalog you search from.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (alreadyAdded) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This service is already in the managed list.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(_submitting ? 'Adding...' : 'Add selected service'),
        ),
      ],
    );
  }

  bool get _canSubmit {
    final serverId = _selectedServerId;
    final serviceName = _selectedServiceName;
    if (_submitting || serverId == null || serviceName == null) {
      return false;
    }
    return !widget.controller.isManagedServiceTracked(serviceName);
  }

  Future<void> _loadCatalog(
    String serverId, {
    required bool forceRefresh,
  }) async {
    widget.controller.setSelectedServerContext(serverId);
    if (forceRefresh) {
      await widget.controller.refreshDiscoveredServicesForServer(serverId);
    } else {
      await widget.controller.ensureDiscoveredServices(serverId);
    }
  }

  Future<void> _submit() async {
    final serverId = _selectedServerId;
    final serviceName = _selectedServiceName;
    if (serverId == null || serviceName == null) {
      return;
    }

    final service = _selectedFrom(
      widget.controller.servicesForServer(serverId),
      serviceName,
    );
    if (service == null) {
      return;
    }

    setState(() => _submitting = true);
    final added = await widget.controller.addManagedServiceFromServer(
      serverId,
      service,
    );
    if (!mounted) {
      return;
    }

    if (added) {
      Navigator.of(context).pop(service.unitName);
      return;
    }

    setState(() => _submitting = false);
  }

  ServiceSummary? _selectedFrom(
    List<ServiceSummary> services,
    String? serviceName,
  ) {
    if (serviceName == null) {
      return null;
    }
    for (final service in services) {
      if (service.unitName == serviceName) {
        return service;
      }
    }
    return null;
  }
}

class _ListStateChip extends StatelessWidget {
  const _ListStateChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _surfaceCardColor(context),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
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
          ..addAll(_sortLogsNewestFirst(logs));
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
        setState(() => _logs.insert(0, log));
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
      child: SizedBox(
        width: 960,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.serviceName} logs',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(widget.server.name),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
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
                      : ListView.separated(
                          itemCount: _logs.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            thickness: 1,
                            color: _logDividerColor(context),
                          ),
                          itemBuilder: (context, index) {
                            final log = _logs[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    log.line,
                                    style: TextStyle(
                                      color: _logTextColor(context),
                                      fontFamily: 'Courier',
                                      fontSize: 15,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _friendlyLogTimestamp(log.ts),
                                    style: TextStyle(
                                      color: _logMetaTextColor(context),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<LogEntry> _sortLogsNewestFirst(List<LogEntry> logs) {
    final sorted = [...logs];
    sorted.sort((a, b) {
      final aTime = _parseLogTimestamp(a.ts);
      final bTime = _parseLogTimestamp(b.ts);
      if (aTime == null && bTime == null) {
        return 0;
      }
      if (aTime == null) {
        return 1;
      }
      if (bTime == null) {
        return -1;
      }
      return bTime.compareTo(aTime);
    });
    return sorted;
  }
}

DateTime? _parseLogTimestamp(String raw) {
  final trimmed = raw.trim();
  final direct = DateTime.tryParse(trimmed);
  if (direct != null) {
    return direct.toLocal();
  }

  final match = RegExp(
    r'(\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?',
  ).firstMatch(trimmed);
  if (match == null) {
    return null;
  }

  final candidate = match.group(0);
  if (candidate == null) {
    return null;
  }

  return DateTime.tryParse(candidate)?.toLocal();
}

String _friendlyLogTimestamp(String raw) {
  final parsed = _parseLogTimestamp(raw);
  if (parsed == null) {
    return raw;
  }

  final year = parsed.year.toString().padLeft(4, '0');
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  final hour = parsed.hour.toString().padLeft(2, '0');
  final minute = parsed.minute.toString().padLeft(2, '0');
  final second = parsed.second.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute:$second';
}

Color _logDividerColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark
      ? const Color(0xFF153246)
      : const Color(0xFF1B415A).withValues(alpha: 0.35);
}

Color _logMetaTextColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF9FBDD1) : const Color(0xFFBAD8EA);
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
  const _StatusBadge({
    super.key,
    required this.label,
    required this.color,
  });

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

String _pageLabel(_AppPage page) {
  return switch (page) {
    _AppPage.services => 'Services',
    _AppPage.servers => 'Servers',
  };
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

Color _activeColor(String? state) {
  switch (state) {
    case 'active':
      return const Color(0xFF167D68);
    case 'failed':
      return const Color(0xFFCC3D3D);
    case 'activating':
      return const Color(0xFFC77B1C);
    default:
      return const Color(0xFF5A7386);
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
