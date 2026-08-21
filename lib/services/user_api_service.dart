import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'session_storage_service.dart';

class UserApiService {
  UserApiService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient(),
      _sessionStorageService = SessionStorageService();

  final ApiClient _apiClient;
  final SessionStorageService _sessionStorageService;

  Future<ApiResult> getProfile() async {
    try {
      final response = await _apiClient.get('/profile', authenticated: true);
      return _toResult(response.body, response.statusCode);
    } catch (_) {
      return ApiResult.failure('Unable to fetch profile.');
    }
  }

  Future<ApiResult> getBmiHistory() async {
    try {
      final response = await _apiClient.get(
        '/bmi/history',
        authenticated: true,
      );
      return _toResult(response.body, response.statusCode);
    } catch (_) {
      return ApiResult.failure('Unable to fetch BMI history.');
    }
  }

  Future<ApiResult> getBmiDetail(int measurementId) async {
    try {
      final response = await _apiClient.get(
        '/bmi/detail/$measurementId',
        authenticated: true,
      );
      return _toResult(response.body, response.statusCode);
    } catch (_) {
      return ApiResult.failure('Unable to fetch BMI detail.');
    }
  }

  ApiResult _toResult(String body, int statusCode) {
    final decoded = _decodeBody(body);
    final message = _extractMessage(decoded, statusCode);
    final data = _extractData(decoded);
    final status = _extractStatus(decoded);
    final isHttpSuccess = statusCode >= 200 && statusCode < 300;
    final isSuccess = isHttpSuccess && (status != false);
    if (isSuccess) {
      return ApiResult.success(data, message: message);
    }
    return ApiResult.failure(message);
  }

  Future<ApiResult> updateProfile({
    required String firstName,
    required String lastName,
    required String mobileNumber,
    required String dob,
    required String heightCm,
    required String weightKg,
  }) async {
    final token = await _sessionStorageService.getToken();
    if (token == null || token.isEmpty) {
      return ApiResult.failure('Not authenticated.');
    }

    try {
      final uri = Uri.parse('${_apiClient.baseUrl}/profile/update');
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';

      request.fields.addAll({
        'first_name': firstName,
        'last_name': lastName,
        'mobile_number': mobileNumber,
        'dob': dob,
        'height_cm': heightCm,
        'weight_kg': weightKg,
      });

      final streamed = await request.send();
      final respStr = await streamed.stream.bytesToString();
      final decoded = _decodeBody(respStr);
      final message = _extractMessage(decoded, streamed.statusCode);
      final data = _extractData(decoded);
      final status = _extractStatus(decoded);
      final isHttpSuccess =
          streamed.statusCode >= 200 && streamed.statusCode < 300;
      final isSuccess = isHttpSuccess && (status != false);
      if (isSuccess) {
        return ApiResult.success(data, message: message);
      }
      return ApiResult.failure(message);
    } catch (_) {
      return ApiResult.failure('Unable to update profile.');
    }
  }

  Future<ApiResult> uploadGovernmentId({required File idDocumentFile}) async {
    final token = await _sessionStorageService.getToken();
    if (token == null || token.isEmpty) {
      return ApiResult.failure('Not authenticated.');
    }

    try {
      final uri = Uri.parse('${_apiClient.baseUrl}/verification/upload-id');
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(
        await http.MultipartFile.fromPath('id_document', idDocumentFile.path),
      );

      final streamed = await request.send();
      final respStr = await streamed.stream.bytesToString();
      final decoded = _decodeBody(respStr);
      final message = _extractMessage(decoded, streamed.statusCode);
      final data = _extractData(decoded);
      final status = _extractStatus(decoded);
      final isHttpSuccess =
          streamed.statusCode >= 200 && streamed.statusCode < 300;
      final isSuccess = isHttpSuccess && (status != false);
      if (isSuccess) {
        final extracted = _extractVerification(data);
        await _sessionStorageService.saveGovernmentIdUploaded(true);
        return ApiResult.success(extracted ?? data, message: message);
      }
      return ApiResult.failure(message);
    } catch (_) {
      return ApiResult.failure('Unable to upload ID document.');
    }
  }

  Future<BmiUploadUrlResponse> requestBmiUploadUrl({
    required File videoFile,
    required double heightDetectedCm,
    required double weightEstimatedKg,
    required double estimatedBmi,
    required Map<String, dynamic> processingMetadata,
  }) async {
    final token = await _sessionStorageService.getToken();
    if (token == null || token.isEmpty) {
      debugPrint('BMI upload aborted: no auth token in session');
      return BmiUploadUrlResponse.failure(
        'Not authenticated. Please sign in again.',
      );
    }

    try {
      final uri = Uri.parse('${_apiClient.baseUrl}/bmi/request-upload-url');
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/json';
      request.files.add(await http.MultipartFile.fromPath('video', videoFile.path));
      request.fields['height_detected'] = heightDetectedCm.toStringAsFixed(2);
      request.fields['weight_estimated'] = weightEstimatedKg.toStringAsFixed(2);
      // Keep legacy typo key for backward compatibility with current backend contract.
      request.fields['weigt_estimated'] = weightEstimatedKg.toStringAsFixed(2);
      request.fields['estimated_bmi'] = estimatedBmi.toStringAsFixed(2);
      request.fields['processing_metadata'] = jsonEncode(processingMetadata);
      debugPrint(
        'BMI upload starting tokenLen=${token.length} '
        'file=${videoFile.path} exists=${videoFile.existsSync()}',
      );

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      debugPrint(
        'BMI upload HTTP ${streamed.statusCode} '
        'url=$uri bytes=${await videoFile.length()} body=${body.length > 800 ? body.substring(0, 800) : body}',
      );
      final decoded = _decodeBody(body);
      final message = _extractMessage(decoded, streamed.statusCode);
      final data = _extractData(decoded);
      final status = _extractStatus(decoded);
      final isHttpSuccess = streamed.statusCode >= 200 && streamed.statusCode < 300;
      final ok = isHttpSuccess && (status != false);
      if (ok) {
        return BmiUploadUrlResponse.success(
          message: message,
          data: data,
          raw: decoded,
        );
      }
      return BmiUploadUrlResponse.failure(
        message,
        data: data,
        raw: decoded,
      );
    } catch (e, st) {
      debugPrint('BMI upload failed: $e\n$st');
      return BmiUploadUrlResponse.failure(
        'Unable to process scan verification right now. Please try again.',
      );
    }
  }

  dynamic _extractVerification(dynamic data) {
    if (data is Map<String, dynamic>) {
      final verification = data['verification'];
      if (verification is Map<String, dynamic>) return verification;
    }
    return null;
  }

  Future<ApiResult> deleteAccount() async {
    final token = await _sessionStorageService.getToken();
    if (token == null || token.isEmpty) {
      return ApiResult.failure('Not authenticated.');
    }

    try {
      final response = await _apiClient.delete(
        '/auth/delete-account',
        authenticated: true,
      );
      final decoded = _decodeBody(response.body);
      final message = _extractMessage(decoded, response.statusCode);
      final data = _extractData(decoded);
      final status = _extractStatus(decoded);
      final isHttpSuccess =
          response.statusCode >= 200 && response.statusCode < 300;
      final isSuccess = isHttpSuccess && (status != false);
      if (isSuccess) {
        return ApiResult.success(data, message: message);
      }
      return ApiResult.failure(message);
    } catch (_) {
      return ApiResult.failure('Unable to delete account.');
    }
  }

  Future<ApiResult> getNotifications() async {
    try {
      final response = await _apiClient.get(
        '/notifications',
        authenticated: true,
      );
      return _toResult(response.body, response.statusCode);
    } catch (_) {
      return ApiResult.failure('Unable to fetch notifications.');
    }
  }

  dynamic _decodeBody(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(body);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String _extractMessage(dynamic decoded, int statusCode) {
    if (decoded is Map<String, dynamic>) {
      final msg = decoded['message'];
      if (msg is String && msg.trim().isNotEmpty) return msg;
      final err = decoded['error'];
      if (err is String && err.trim().isNotEmpty) return err;
    }
    if (statusCode >= 200 && statusCode < 300) return 'Success';
    return 'Request failed ($statusCode).';
  }

  dynamic _extractData(dynamic decoded) {
    if (decoded is Map<String, dynamic>) return decoded['data'];
    return null;
  }

  bool? _extractStatus(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final success = decoded['success'];
      if (success is bool) return success;
      final status = decoded['status'];
      if (status is bool) return status;
    }
    return null;
  }
}

class ApiResult {
  const ApiResult._({required this.ok, this.data, this.message});

  final bool ok;
  final dynamic data;
  final String? message;

  factory ApiResult.success(dynamic data, {String? message}) =>
      ApiResult._(ok: true, data: data, message: message);

  factory ApiResult.failure(String message) =>
      ApiResult._(ok: false, data: null, message: message);
}

class BmiUploadUrlResponse {
  const BmiUploadUrlResponse._({
    required this.ok,
    required this.message,
    this.data,
    this.raw,
  });

  final bool ok;
  final String message;
  final dynamic data;
  final dynamic raw;

  factory BmiUploadUrlResponse.success({
    required String message,
    dynamic data,
    dynamic raw,
  }) =>
      BmiUploadUrlResponse._(ok: true, message: message, data: data, raw: raw);

  factory BmiUploadUrlResponse.failure(
    String message, {
    dynamic data,
    dynamic raw,
  }) =>
      BmiUploadUrlResponse._(ok: false, message: message, data: data, raw: raw);
}
