import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_session_notifier.dart';
import 'session_storage_service.dart';

class ApiClient {
  ApiClient({
    http.Client? httpClient,
    SessionStorageService? sessionStorageService,
  }) : _httpClient = httpClient ?? http.Client(),
       _sessionStorageService =
           sessionStorageService ?? SessionStorageService(),
       _baseUrl = const String.fromEnvironment(
         'API_BASE_URL',
         defaultValue: 'https://api-dev.clockworkbmi.com/api',
       );

  final http.Client _httpClient;
  final SessionStorageService _sessionStorageService;
  final String _baseUrl;

  String get baseUrl => _baseUrl;

  Future<http.Response> get(
    String path, {
    bool authenticated = false,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final mergedHeaders = await _buildHeaders(
      authenticated: authenticated,
      headers: headers,
    );
    final response = await _httpClient.get(uri, headers: mergedHeaders);
    await _handleUnauthorized(
      response,
      authenticated: authenticated,
    );
    return response;
  }

  Future<http.Response> post(
    String path, {
    bool authenticated = false,
    bool logoutOnUnauthorized = true,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final mergedHeaders = await _buildHeaders(
      authenticated: authenticated,
      headers: headers,
    );
    final response = await _httpClient.post(
      uri,
      headers: mergedHeaders,
      body: body == null ? null : jsonEncode(body),
    );
    await _handleUnauthorized(
      response,
      authenticated: authenticated,
      logoutOnUnauthorized: logoutOnUnauthorized,
    );
    return response;
  }

  Future<http.Response> delete(
    String path, {
    bool authenticated = false,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final mergedHeaders = await _buildHeaders(
      authenticated: authenticated,
      headers: headers,
    );
    final response = await _httpClient.delete(uri, headers: mergedHeaders);
    await _handleUnauthorized(
      response,
      authenticated: authenticated,
    );
    return response;
  }

  Future<Map<String, String>> _buildHeaders({
    required bool authenticated,
    Map<String, String>? headers,
  }) async {
    final merged = <String, String>{
      'Content-Type': 'application/json',
      ...?headers,
    };
    if (authenticated) {
      final token = await _sessionStorageService.getToken();
      if (token == null || token.isEmpty) {
        await AuthSessionNotifier.instance.invalidateSession();
        return merged;
      }
      merged['Authorization'] = 'Bearer $token';
    }
    return merged;
  }

  Future<void> _handleUnauthorized(
    http.Response response, {
    required bool authenticated,
    bool logoutOnUnauthorized = true,
  }) async {
    if (!authenticated || !logoutOnUnauthorized) return;
    if (response.statusCode == 401) {
      await AuthSessionNotifier.instance.invalidateSession();
    }
  }
}
