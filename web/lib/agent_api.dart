import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class AgentApiClient {
  AgentApiClient(this.server, {http.Client? client})
      : _client = client ?? http.Client();

  final ServerProfile server;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final base = Uri.parse(server.baseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath$path',
      queryParameters: queryParameters,
    );
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Authorization': 'Bearer ${server.token}',
      };

  Future<PingInfo> ping() async {
    final json = await _getJson('/api/v1/ping');
    return PingInfo.fromJson(json);
  }

  Future<List<ServiceSummary>> listServices({String? query}) async {
    final json = await _getJson(
      '/api/v1/services',
      queryParameters: query == null || query.isEmpty ? null : {'query': query},
    );
    final items = (json['services'] as List<dynamic>? ?? <dynamic>[]);
    return items
        .map((item) => ServiceSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ServiceSummary> getService(String serviceName) async {
    final json = await _getJson('/api/v1/services/$serviceName');
    return ServiceSummary.fromJson(json['service'] as Map<String, dynamic>);
  }

  Future<ServiceSummary> performAction(
    String serviceName,
    String action,
  ) async {
    final response = await _send(
      () => _client.post(
        _uri('/api/v1/services/$serviceName/actions'),
        headers: {
          ..._headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'action': action}),
      ),
    );
    return ServiceSummary.fromJson(
      (jsonDecode(response.body) as Map<String, dynamic>)['service']
          as Map<String, dynamic>,
    );
  }

  Future<List<LogEntry>> getRecentLogs(String serviceName, {int lines = 200}) async {
    final json = await _getJson(
      '/api/v1/services/$serviceName/logs',
      queryParameters: {'lines': '$lines'},
    );
    final items = (json['logs'] as List<dynamic>? ?? <dynamic>[]);
    return items
        .map((item) => LogEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Stream<LogEntry> tailLogs(String serviceName) {
    final base = Uri.parse(server.baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = base.replace(
      scheme: scheme,
      path: '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}/api/v1/ws/logs',
      queryParameters: {'service': serviceName, 'token': server.token},
    );
    final channel = WebSocketChannel.connect(wsUri);
    return channel.stream.transform(
      StreamTransformer<dynamic, LogEntry>.fromHandlers(
        handleData: (dynamic raw, EventSink<LogEntry> sink) {
          final payload = jsonDecode(raw as String) as Map<String, dynamic>;
          if (payload['type'] == 'error') {
            sink.addError(ApiError(payload['message'] as String? ?? 'Log stream failed'));
            return;
          }
          sink.add(LogEntry.fromJson(payload));
        },
        handleDone: (sink) => sink.close(),
      ),
    );
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final response = await _send(
      () => _client.get(
        _uri(path, queryParameters),
        headers: _headers,
      ),
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<http.Response> _send(Future<http.Response> Function() runRequest) async {
    try {
      final response = await runRequest().timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      final body = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      final error = body['error'] as Map<String, dynamic>?;
      final message = error?['message'] as String? ?? 'Request failed.';
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw ApiError(message, category: ApiErrorCategory.auth);
      }
      throw ApiError(message, category: ApiErrorCategory.command);
    } on TimeoutException {
      throw ApiError(
        'Connection timed out. Check the agent URL and network.',
        category: ApiErrorCategory.connection,
      );
    } on http.ClientException catch (error) {
      throw ApiError(
        error.message,
        category: ApiErrorCategory.connection,
      );
    } on FormatException {
      throw ApiError(
        'The agent returned invalid JSON.',
        category: ApiErrorCategory.connection,
      );
    }
  }
}
