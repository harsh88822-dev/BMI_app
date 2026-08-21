import 'dart:io';
import 'dart:math' show atan, pi;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../main.dart';

/// Reads the back-camera vertical field of view from native camera APIs,
/// with a safe fallback when unavailable.
class CameraFovService {
  CameraFovService._();

  static const MethodChannel _channel =
      MethodChannel('com.clockworkbmi.app/camera_fov');

  static double? _cachedVerticalFovDegrees;

  static Future<double> verticalFovDegrees() async {
    if (_cachedVerticalFovDegrees != null) {
      return _cachedVerticalFovDegrees!;
    }

    try {
      final result = await _channel.invokeMethod<double>(
        'getBackCameraVerticalFovDegrees',
      );
      if (result != null && result.isFinite && result > 0) {
        final clamped = result.clamp(
          MIN_CAMERA_VFOV_DEGREES,
          MAX_CAMERA_VFOV_DEGREES,
        );
        _cachedVerticalFovDegrees = clamped.toDouble();
        debugPrint('CameraFovService: native VFOV=${clamped.toStringAsFixed(1)}°');
        return _cachedVerticalFovDegrees!;
      }
    } on PlatformException catch (e) {
      debugPrint('CameraFovService: native FOV unavailable (${e.code})');
    } catch (e) {
      debugPrint('CameraFovService: FOV lookup failed: $e');
    }

    // Typical rear wide camera on phones — better than a single hardcoded value.
    final fallback = Platform.isAndroid ? 56.0 : 62.0;
    _cachedVerticalFovDegrees = fallback;
    debugPrint('CameraFovService: using fallback VFOV=${fallback.toStringAsFixed(1)}°');
    return fallback;
  }

  static double focalLengthPx({
    required double imageHeightPx,
    required double verticalFovDegrees,
  }) {
    final halfFovRad = verticalFovDegrees * pi / 180 / 2;
    return imageHeightPx / (2 * atan(halfFovRad));
  }
}
