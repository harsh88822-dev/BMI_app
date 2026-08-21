import 'dart:math' show pow;

import '../main.dart';

/// Shared height / weight / BMI math used by the scan pipeline.
abstract final class BodyMetrics {
  static const double minHeightM = 1.4;
  static const double maxHeightM = 2.1;
  static const double minWidthM = 0.2;
  static const double maxWidthM = 0.8;
  static const double minDepthM = 0.15;
  static const double maxDepthM = 0.6;
  static const double minWeightKg = 30.0;
  static const double maxWeightKg = 250.0;

  /// Density constant in main.dart is g/cm³; convert to kg/m³ for volume in m³.
  static const double densityKgPerM3 = HUMAN_DENSITY * 1000000;

  static double cmPerPixel({
    required double? lockedCmPerPixel,
    required double guideRealHeightCm,
    required double guideHeightPx,
  }) {
    if (lockedCmPerPixel != null &&
        lockedCmPerPixel.isFinite &&
        lockedCmPerPixel > 0) {
      return lockedCmPerPixel;
    }
    if (guideHeightPx <= 0) return 0;
    return guideRealHeightCm / guideHeightPx;
  }

  static double heightMetersFromScreenPx({
    required double heightPx,
    required double cmPerPx,
    bool applyHeadToeCorrection = true,
  }) {
    if (heightPx <= 0 || cmPerPx <= 0) return 0;
    var heightCm = heightPx * cmPerPx;
    if (applyHeadToeCorrection) {
      heightCm *= HEIGHT_CORRECTION_FACTOR;
    }
    return (heightCm / 100).clamp(minHeightM, maxHeightM);
  }

  static double weightKgFromDimensions({
    required double heightM,
    required double widthM,
    required double depthM,
    double shapeFactor = BODY_SHAPE_FACTOR,
  }) {
    if (heightM <= 0 || widthM <= 0 || depthM <= 0) return 0;
    final volumeM3 =
        heightM * widthM.clamp(minWidthM, maxWidthM) * depthM.clamp(minDepthM, maxDepthM) * shapeFactor;
    return (volumeM3 * densityKgPerM3).clamp(minWeightKg, maxWeightKg);
  }

  static double bmi({
    required double weightKg,
    required double heightM,
  }) {
    if (weightKg <= 0 || heightM <= 0) return 0;
    return weightKg / pow(heightM, 2);
  }
}
