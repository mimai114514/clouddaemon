class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.token,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String token;

  ServerProfile copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? token,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'base_url': baseUrl,
      'token': token,
    };
  }

  static ServerProfile fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: json['base_url'] as String,
      token: json['token'] as String,
    );
  }
}

class ManagedService {
  ManagedService({
    required this.id,
    required this.serviceName,
    required this.pinnedAt,
  });

  final String id;
  final String serviceName;
  final String pinnedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'service_name': serviceName,
      'pinned_at': pinnedAt,
    };
  }

  static ManagedService fromJson(Map<String, dynamic> json) {
    return ManagedService(
      id: json['id'] as String,
      serviceName: json['service_name'] as String,
      pinnedAt: json['pinned_at'] as String,
    );
  }
}

class ServiceSummary {
  ServiceSummary({
    required this.unitName,
    required this.description,
    required this.loadState,
    required this.activeState,
    required this.subState,
    required this.canStart,
    required this.canStop,
    required this.canRestart,
    this.statusText,
  });

  final String unitName;
  final String description;
  final String loadState;
  final String activeState;
  final String subState;
  final bool canStart;
  final bool canStop;
  final bool canRestart;
  final String? statusText;

  factory ServiceSummary.fromJson(Map<String, dynamic> json) {
    return ServiceSummary(
      unitName: json['unit_name'] as String,
      description: (json['description'] as String?) ?? '',
      loadState: (json['load_state'] as String?) ?? '',
      activeState: (json['active_state'] as String?) ?? '',
      subState: (json['sub_state'] as String?) ?? '',
      canStart: (json['can_start'] as bool?) ?? false,
      canStop: (json['can_stop'] as bool?) ?? false,
      canRestart: (json['can_restart'] as bool?) ?? false,
      statusText: json['status_text'] as String?,
    );
  }
}

class PingInfo {
  PingInfo({
    required this.version,
    required this.hostname,
    required this.systemdAvailable,
    required this.now,
  });

  final String version;
  final String hostname;
  final bool systemdAvailable;
  final String now;

  factory PingInfo.fromJson(Map<String, dynamic> json) {
    return PingInfo(
      version: (json['version'] as String?) ?? 'unknown',
      hostname: (json['hostname'] as String?) ?? 'unknown',
      systemdAvailable: (json['systemd_available'] as bool?) ?? false,
      now: (json['now'] as String?) ?? '',
    );
  }
}

class LogEntry {
  LogEntry({
    required this.line,
    required this.ts,
    required this.service,
  });

  final String line;
  final String ts;
  final String service;

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      line: (json['line'] as String?) ?? '',
      ts: (json['ts'] as String?) ?? '',
      service: (json['service'] as String?) ?? '',
    );
  }
}

class ExportBundle {
  ExportBundle({
    required this.version,
    required this.exportedAt,
    required this.servers,
    required this.managedServices,
  });

  final int version;
  final String exportedAt;
  final List<ServerProfile> servers;
  final List<ManagedService> managedServices;

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'exported_at': exportedAt,
      'servers': servers.map((server) => server.toJson()).toList(),
      'managed_services': managedServices.map((service) => service.toJson()).toList(),
    };
  }

  factory ExportBundle.fromJson(Map<String, dynamic> json) {
    final rawServers = (json['servers'] as List<dynamic>? ?? <dynamic>[]);
    final rawServices =
        (json['managed_services'] as List<dynamic>? ?? <dynamic>[]);
    return ExportBundle(
      version: (json['version'] as num?)?.toInt() ?? 1,
      exportedAt: (json['exported_at'] as String?) ?? '',
      servers: rawServers
          .map((server) => ServerProfile.fromJson(server as Map<String, dynamic>))
          .toList(),
      managedServices: rawServices
          .map(
            (service) =>
                ManagedService.fromJson(service as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class ImportPreview {
  ImportPreview({
    required this.serversToInsert,
    required this.managedServicesToInsert,
    required this.skippedServers,
    required this.skippedManagedServices,
    required this.errors,
  });

  final List<ServerProfile> serversToInsert;
  final List<ManagedService> managedServicesToInsert;
  final int skippedServers;
  final int skippedManagedServices;
  final List<String> errors;

  int get addedServers => serversToInsert.length;
  int get addedManagedServices => managedServicesToInsert.length;
}

class ApiError implements Exception {
  ApiError(this.message, {this.category = ApiErrorCategory.command});

  final String message;
  final ApiErrorCategory category;

  @override
  String toString() => message;
}

enum ApiErrorCategory { auth, connection, command }
