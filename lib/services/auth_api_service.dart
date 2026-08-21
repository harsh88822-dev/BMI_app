import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';

class AuthApiService {
  AuthApiService({http.Client? client})
    : _client = client ?? http.Client(),
      _baseUrl = const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'https://api-dev.clockworkbmi.com/api',
      );

  final http.Client _client;
  final String _baseUrl;
  final ApiClient _apiClient = ApiClient();

  Future<AuthApiResponse> register({
    required String email,
    required String password,
  }) {
    return _post(
      '/auth/register',
      body: <String, dynamic>{'email': email, 'password': password},
    );
  }

  Future<AuthApiResponse> verifyOtp({
    required String email,
    required String otp,
  }) {
    return _post(
      '/auth/verify-otp',
      body: <String, dynamic>{'email': email, 'otp': otp},
    );
  }

  Future<AuthApiResponse> login({
    required String email,
    required String password,
  }) {
    return _post(
      '/auth/login',
      body: <String, dynamic>{'email': email, 'password': password},
    );
  }

  Future<AuthApiResponse> forgotPassword({required String email}) {
    return _post(
      '/auth/forgot-password',
      body: <String, dynamic>{'email': email},
    );
  }

  Future<AuthApiResponse> resetPassword({
    required String email,
    required String otp,
    required String newPassword,
  }) {
    return _post(
      '/auth/reset-password',
      body: <String, dynamic>{
        'email': email,
        'otp': otp,
        'newPassword': newPassword,
      },
    );
  }

  Future<AuthApiResponse> registerFirebaseToken({
    required String firebaseToken,
    required String platform,
  }) async {
    try {
      final response = await _apiClient.post(
        '/firebase/register-token',
        authenticated: true,
        logoutOnUnauthorized: false,
        body: <String, dynamic>{'token': firebaseToken, 'platform': platform},
      );
      final decoded = _decodeJson(response.body);
      final message = _extractMessage(decoded, response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return AuthApiResponse.success(message: message, data: decoded);
      }
      return AuthApiResponse.failure(message: message);
    } catch (_) {
      return AuthApiResponse.failure(
        message: 'Unable to register Firebase token.',
      );
    }
  }

  Future<AuthApiResponse> _post(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await _client.post(
        uri,
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      final decoded = _decodeJson(response.body);
      final message = _extractMessage(decoded, response);
      final token = _extractToken(decoded);
      final payloadData = _extractData(decoded);
      final apiStatus = _extractStatus(decoded);
      final isHttpSuccess =
          response.statusCode >= 200 && response.statusCode < 300;
      final isSuccess = isHttpSuccess && (apiStatus != false);
      debugPrint(
        'Auth $path HTTP ${response.statusCode} ok=$isSuccess '
        'token=${token == null ? 'missing' : 'len=${token.length}'}',
      );
      if (isSuccess) {
        return AuthApiResponse.success(
          message: message,
          token: token,
          data: payloadData,
        );
      }
      return AuthApiResponse.failure(message: message);
    } catch (_) {
      return AuthApiResponse.failure(
        message: 'Unable to reach server. Please try again.',
      );
    }
  }

  dynamic _decodeJson(String rawBody) {
    if (rawBody.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      return jsonDecode(rawBody);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String _extractMessage(dynamic decoded, http.Response response) {
    if (decoded is Map<String, dynamic>) {
      final dynamic directMessage = decoded['message'];
      if (directMessage is String && directMessage.trim().isNotEmpty) {
        return directMessage;
      }
      final dynamic error = decoded['error'];
      if (error is String && error.trim().isNotEmpty) {
        return error;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return 'Success';
    }
    return 'Request failed (${response.statusCode}).';
  }

  String? _extractToken(dynamic decoded) {
    final raw = _findToken(decoded, depth: 0);
    if (raw == null) return null;
    var token = raw.trim();
    if (token.toLowerCase().startsWith('bearer ')) {
      token = token.substring(7).trim();
    }
    return token.isEmpty ? null : token;
  }

  String? _findToken(dynamic node, {required int depth}) {
    if (node == null || depth > 6) return null;
    if (node is String) {
      final value = node.trim();
      if (value.length >= 20 &&
          (value.startsWith('eyJ') || value.split('.').length >= 3)) {
        return value;
      }
      return null;
    }
    if (node is! Map) return null;
    final map = <String, dynamic>{
      for (final entry in node.entries) entry.key.toString(): entry.value,
    };
    const keys = <String>[
      'token',
      'accessToken',
      'access_token',
      'jwt',
      'authToken',
      'auth_token',
      'idToken',
      'id_token',
    ];
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    const nestedKeys = <String>[
      'authorisation',
      'authorization',
      'auth',
      'data',
      'result',
      'payload',
      'user',
      'session',
    ];
    for (final key in nestedKeys) {
      if (!map.containsKey(key)) continue;
      final nested = _findToken(map[key], depth: depth + 1);
      if (nested != null) return nested;
    }
    for (final value in map.values) {
      if (value is Map) {
        final nested = _findToken(value, depth: depth + 1);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  bool? _extractStatus(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final status = decoded['status'];
      if (status is bool) return status;
      if (status is num) return status != 0;
      if (status is String) {
        final normalized = status.trim().toLowerCase();
        if (normalized == 'true' ||
            normalized == 'success' ||
            normalized == 'ok' ||
            normalized == '1') {
          return true;
        }
        if (normalized == 'false' ||
            normalized == 'error' ||
            normalized == 'fail' ||
            normalized == '0') {
          return false;
        }
      }
      final success = decoded['success'];
      if (success is bool) return success;
    }
    return null;
  }

  dynamic _extractData(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      return decoded['data'] ?? decoded;
    }
    return null;
  }

  String? _asNonEmptyString(dynamic value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return null;
  }
}

class AuthApiResponse {
  const AuthApiResponse._({
    required this.ok,
    required this.message,
    this.token,
    this.data,
  });

  final bool ok;
  final String message;
  final String? token;
  final dynamic data;

  factory AuthApiResponse.success({
    required String message,
    String? token,
    dynamic data,
  }) {
    return AuthApiResponse._(
      ok: true,
      message: message,
      token: token,
      data: data,
    );
  }

  factory AuthApiResponse.failure({required String message}) {
    return AuthApiResponse._(ok: false, message: message);
  }
}
