import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight scan diagnostics for debugging Android reliability issues.
class ScanTelemetryService {
  ScanTelemetryService._();

  static const String _logKey = 'scan_telemetry_log';
  static const int _maxEntries = 40;

  static Future<void> log({
    required String stage,
    required String outcome,
    Map<String, dynamic>? details,
  }) async {
    final entry = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'stage': stage,
      'outcome': outcome,
      if (details != null) ...details,
    };

    debugPrint('[ScanTelemetry] ${jsonEncode(entry)}');

    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_logKey) ?? <String>[];
      existing.add(jsonEncode(entry));
      while (existing.length > _maxEntries) {
        existing.removeAt(0);
      }
      await prefs.setStringList(_logKey, existing);
    } catch (e) {
      debugPrint('ScanTelemetryService: persist failed: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> recentEntries({int limit = 20}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_logKey) ?? <String>[];
      final parsed = <Map<String, dynamic>>[];
      for (final line in raw.reversed) {
        if (parsed.length >= limit) break;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            parsed.add(decoded.map((k, v) => MapEntry(k.toString(), v)));
          }
        } catch (_) {}
      }
      return parsed;
    } catch (_) {
      return const [];
    }
  }
}
