import 'package:clouddaemon_web/app.dart';
import 'package:clouddaemon_web/models.dart';
import 'package:clouddaemon_web/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final prod = ServerProfile(
    id: 'prod',
    name: 'prod',
    baseUrl: 'https://prod.example.com',
    token: 'prod-token',
  );
  final staging = ServerProfile(
    id: 'staging',
    name: 'staging',
    baseUrl: 'https://staging.example.com',
    token: 'staging-token',
  );

  final nginx = ServiceSummary(
    unitName: 'nginx.service',
    description: 'Nginx web server',
    loadState: 'loaded',
    activeState: 'active',
    subState: 'running',
    canStart: false,
    canStop: true,
    canRestart: true,
  );
  test(
    'addManagedServiceFromServer keeps managed services globally deduplicated',
    () async {
      final controller = await _buildController(
        servers: [prod, staging],
        managedServices: [_managed('managed-nginx', 'nginx.service')],
        dataByServerId: _defaultServerData(),
      );

      final added = await controller.addManagedServiceFromServer(
        prod.id,
        nginx,
      );

      expect(added, isFalse);
      expect(controller.managedServices, hasLength(1));
      expect(controller.managedServices.single.serviceName, 'nginx.service');
    },
  );

  test(
    'refreshManagedStatuses ignores service-unavailable command errors',
    () async {
      final dataByServerId = _defaultServerData();
      final stagingData = dataByServerId['staging']!;
      dataByServerId['staging'] = _FakeServerData(
        ping: stagingData.ping,
        discoveredServices: stagingData.discoveredServices,
        serviceStates: stagingData.serviceStates,
        getServiceErrors: {
          'docker.service': ApiError(
            'service "docker.service" is not availble',
            category: ApiErrorCategory.command,
            statusCode: 500,
          ),
        },
      );

      final controller = await _buildController(
        servers: [prod, staging],
        managedServices: [
          _managed('managed-nginx', 'nginx.service'),
          _managed('managed-docker', 'docker.service'),
        ],
        dataByServerId: dataByServerId,
      );

      controller.discoveredServicesByServer = <String, List<ServiceSummary>>{};
      await controller.refreshManagedStatuses();

      expect(controller.serverErrors.containsKey(staging.id), isFalse);
      expect(controller.statusFor(staging.id, 'nginx.service'), isNotNull);
      expect(controller.statusFor(staging.id, 'docker.service'), isNull);
    },
  );

  testWidgets('desktop shell has no outer padding', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [_managed('managed-nginx', 'nginx.service')],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    final shellPadding = tester.widget<Padding>(
      find.byKey(const ValueKey('app-shell-padding')),
    );
    expect(shellPadding.padding, EdgeInsets.zero);
  });

  testWidgets('service page groups managed services by service name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [
        _managed('managed-nginx', 'nginx.service'),
        _managed('managed-docker', 'docker.service'),
      ],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    final nginxGroup = find.byKey(
      const ValueKey('service-group-nginx.service'),
    );
    final dockerGroup = find.byKey(
      const ValueKey('service-group-docker.service'),
    );

    expect(nginxGroup, findsOneWidget);
    expect(dockerGroup, findsOneWidget);
    expect(
      find.descendant(
        of: nginxGroup,
        matching: find.textContaining('currently expose'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: nginxGroup, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nginxGroup, matching: find.text('prod')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nginxGroup, matching: find.text('staging')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dockerGroup, matching: find.text('prod')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dockerGroup, matching: find.text('staging')),
      findsNothing,
    );
  });

  testWidgets(
    'server page shows only managed services that exist on each server',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1200));
      final controller = await _buildController(
        servers: [prod, staging],
        managedServices: [
          _managed('managed-nginx', 'nginx.service'),
          _managed('managed-docker', 'docker.service'),
        ],
        dataByServerId: _defaultServerData(),
      );

      await tester.pumpWidget(CloudDaemonApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(NavigationDrawerDestination, 'Servers'),
      );
      await tester.pumpAndSettle();

      final prodCard = find.byKey(const ValueKey('server-card-prod'));
      final stagingCard = find.byKey(const ValueKey('server-card-staging'));

      expect(prodCard, findsOneWidget);
      expect(stagingCard, findsOneWidget);
      expect(
        find.descendant(of: prodCard, matching: find.text('docker.service')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: stagingCard, matching: find.text('docker.service')),
        findsNothing,
      );
      expect(
        find.descendant(of: stagingCard, matching: find.text('nginx.service')),
        findsOneWidget,
      );
    },
  );

  testWidgets('server add flow creates one new global managed service', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [_managed('managed-nginx', 'nginx.service')],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Servers'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-add-dialog-prod')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('docker.service'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add selected service'));
    await tester.pumpAndSettle();

    expect(
      controller.managedServices.map((item) => item.serviceName),
      containsAll(<String>['nginx.service', 'docker.service']),
    );

    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Services'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('service-group-docker.service')),
      findsOneWidget,
    );
  });

  testWidgets('navigation drawer switching keeps service data visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [_managed('managed-nginx', 'nginx.service')],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('service-group-nginx.service')),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Servers'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Services'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('service-group-nginx.service')),
      findsOneWidget,
    );
    expect(find.text('prod'), findsOneWidget);
  });

  testWidgets('services page uses compact row layout and dynamic actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [
        _managed('managed-nginx', 'nginx.service'),
        _managed('managed-docker', 'docker.service'),
      ],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    final nginxRow = find.byKey(
      const ValueKey('service-row-nginx.service-prod'),
    );
    final dockerRow = find.byKey(
      const ValueKey('service-row-docker.service-prod'),
    );

    expect(nginxRow, findsOneWidget);
    expect(dockerRow, findsOneWidget);
    expect(
      find.descendant(
        of: nginxRow,
        matching: find.text('https://prod.example.com'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: nginxRow, matching: find.text('nginx.service')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: nginxRow,
        matching: find.byKey(
          const ValueKey('service-state-nginx.service-prod'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nginxRow, matching: find.textContaining('sub:')),
      findsNothing,
    );
    expect(
      find.descendant(of: nginxRow, matching: find.textContaining('load:')),
      findsNothing,
    );
    expect(
      find.descendant(of: nginxRow, matching: find.textContaining('Refreshed')),
      findsNothing,
    );
    final statusOffset = tester.getTopLeft(
      find.byKey(const ValueKey('service-state-nginx.service-prod')),
    );
    final primaryActionOffset = tester.getTopLeft(
      find.byKey(const ValueKey('primary-action-nginx.service-prod')),
    );
    final serverNameOffset = tester.getTopLeft(
      find.descendant(of: nginxRow, matching: find.text('prod')),
    );
    expect(statusOffset.dy, greaterThan(serverNameOffset.dy));
    expect(
      (primaryActionOffset.dy - statusOffset.dy).abs(),
      lessThanOrEqualTo(4),
    );
    expect(
      find.descendant(
        of: nginxRow,
        matching: find.byKey(
          const ValueKey('primary-action-nginx.service-prod'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: nginxRow,
        matching: find.byKey(
          const ValueKey('restart-action-nginx.service-prod'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: nginxRow,
        matching: find.byKey(const ValueKey('logs-action-nginx.service-prod')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dockerRow,
        matching: find.byKey(
          const ValueKey('primary-action-docker.service-prod'),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('server cards use inline online badge and simplified metadata', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [
        _managed('managed-nginx', 'nginx.service'),
        _managed('managed-docker', 'docker.service'),
      ],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Servers'),
    );
    await tester.pumpAndSettle();

    final prodCard = find.byKey(const ValueKey('server-card-prod'));

    expect(
      find.descendant(of: prodCard, matching: find.text('online')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: prodCard, matching: find.textContaining('Catalog')),
      findsNothing,
    );
    expect(
      find.descendant(of: prodCard, matching: find.text('Trust cert')),
      findsNothing,
    );
    expect(
      find.descendant(of: prodCard, matching: find.text('Managed services')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: prodCard, matching: find.text('2')),
      findsOneWidget,
    );
  });

  testWidgets('refresh states do not render top loading bars', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [_managed('managed-nginx', 'nginx.service')],
      dataByServerId: _defaultServerData(),
    );

    controller.refreshingCatalog = true;
    controller.refreshingManaged = true;
    controller.notifyListeners();

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(
      find.widgetWithText(NavigationDrawerDestination, 'Servers'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('navigation drawer removes intro copy and spaces destinations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    final controller = await _buildController(
      servers: [prod, staging],
      managedServices: [_managed('managed-nginx', 'nginx.service')],
      dataByServerId: _defaultServerData(),
    );

    await tester.pumpWidget(CloudDaemonApp(controller: controller));
    await tester.pumpAndSettle();

    expect(
      find.text('Service and server operations from one browser console.'),
      findsNothing,
    );

    final servicesDestination = find.widgetWithText(
      NavigationDrawerDestination,
      'Services',
    );
    final serversDestination = find.widgetWithText(
      NavigationDrawerDestination,
      'Servers',
    );

    final servicesBottom = tester.getBottomLeft(servicesDestination).dy;
    final serversTop = tester.getTopLeft(serversDestination).dy;

    expect(serversTop - servicesBottom, greaterThanOrEqualTo(8));
  });
}

Future<AppController> _buildController({
  required List<ServerProfile> servers,
  required List<ManagedService> managedServices,
  required Map<String, _FakeServerData> dataByServerId,
}) async {
  final controller = AppController(
    storage: _FakeAppStorage(
      initialServers: servers,
      initialManagedServices: managedServices,
    ),
    clientFactory: (server) => _FakeAgentClient(dataByServerId[server.id]!),
  );
  await controller.initialize();
  return controller;
}

ManagedService _managed(String id, String serviceName) {
  return ManagedService(
    id: id,
    serviceName: serviceName,
    pinnedAt: '2026-03-11T00:00:00Z',
  );
}

Map<String, _FakeServerData> _defaultServerData() {
  return {
    'prod': _FakeServerData(
      ping: PingInfo(
        version: '1.0.0',
        hostname: 'prod-host',
        systemdAvailable: true,
        now: '2026-03-11T00:00:00Z',
      ),
      discoveredServices: [
        ServiceSummary(
          unitName: 'docker.service',
          description: 'Docker engine',
          loadState: 'loaded',
          activeState: 'inactive',
          subState: 'dead',
          canStart: true,
          canStop: false,
          canRestart: true,
        ),
        ServiceSummary(
          unitName: 'nginx.service',
          description: 'Nginx web server',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          canStart: false,
          canStop: true,
          canRestart: true,
        ),
      ],
      serviceStates: {
        'docker.service': ServiceSummary(
          unitName: 'docker.service',
          description: 'Docker engine',
          loadState: 'loaded',
          activeState: 'inactive',
          subState: 'dead',
          canStart: true,
          canStop: false,
          canRestart: true,
        ),
        'nginx.service': ServiceSummary(
          unitName: 'nginx.service',
          description: 'Nginx web server',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          canStart: false,
          canStop: true,
          canRestart: true,
        ),
      },
    ),
    'staging': _FakeServerData(
      ping: PingInfo(
        version: '1.0.1',
        hostname: 'staging-host',
        systemdAvailable: true,
        now: '2026-03-11T00:00:00Z',
      ),
      discoveredServices: [
        ServiceSummary(
          unitName: 'nginx.service',
          description: 'Nginx web server',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          canStart: false,
          canStop: true,
          canRestart: true,
        ),
      ],
      serviceStates: {
        'nginx.service': ServiceSummary(
          unitName: 'nginx.service',
          description: 'Nginx web server',
          loadState: 'loaded',
          activeState: 'active',
          subState: 'running',
          canStart: false,
          canStop: true,
          canRestart: true,
        ),
      },
    ),
  };
}

class _FakeAppStorage extends AppStorage {
  _FakeAppStorage({
    required List<ServerProfile> initialServers,
    required List<ManagedService> initialManagedServices,
  }) : _servers = [...initialServers],
       _managedServices = [...initialManagedServices];

  List<ServerProfile> _servers;
  List<ManagedService> _managedServices;

  @override
  Future<void> init() async {}

  @override
  Future<List<ServerProfile>> loadServers() async => [..._servers];

  @override
  Future<void> saveServer(ServerProfile server) async {
    final index = _servers.indexWhere((item) => item.id == server.id);
    if (index == -1) {
      _servers = [..._servers, server];
      return;
    }
    _servers = [..._servers]..[index] = server;
  }

  @override
  Future<void> deleteServer(String serverId) async {
    _servers = _servers.where((item) => item.id != serverId).toList();
  }

  @override
  Future<List<ManagedService>> loadManagedServices() async => [
    ..._managedServices,
  ];

  @override
  Future<void> saveManagedService(ManagedService managedService) async {
    final index = _managedServices.indexWhere(
      (item) => item.id == managedService.id,
    );
    if (index == -1) {
      _managedServices = [..._managedServices, managedService];
      return;
    }
    _managedServices = [..._managedServices]..[index] = managedService;
  }

  @override
  Future<void> deleteManagedService(String id) async {
    _managedServices = _managedServices.where((item) => item.id != id).toList();
  }
}

class _FakeServerData {
  _FakeServerData({
    required this.ping,
    required this.discoveredServices,
    required this.serviceStates,
    Map<String, ApiError>? getServiceErrors,
  }) : getServiceErrors = getServiceErrors ?? const {};

  final PingInfo ping;
  final List<ServiceSummary> discoveredServices;
  final Map<String, ServiceSummary> serviceStates;
  final Map<String, ApiError> getServiceErrors;
}

class _FakeAgentClient implements AgentClient {
  _FakeAgentClient(this.data);

  final _FakeServerData data;

  @override
  Future<PingInfo> ping() async => data.ping;

  @override
  Future<List<ServiceSummary>> listServices({String? query}) async {
    return [...data.discoveredServices];
  }

  @override
  Future<ServiceSummary> getService(String serviceName) async {
    final explicitError = data.getServiceErrors[serviceName];
    if (explicitError != null) {
      throw explicitError;
    }

    final service = data.serviceStates[serviceName];
    if (service == null) {
      throw ApiError(
        'Service not found.',
        category: ApiErrorCategory.command,
        statusCode: 404,
      );
    }
    return service;
  }

  @override
  Future<ServiceSummary> performAction(
    String serviceName,
    String action,
  ) async {
    final service = await getService(serviceName);
    return service;
  }
}
