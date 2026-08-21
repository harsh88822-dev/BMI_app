import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size absoluteImageSize;
  final InputImageRotation rotation;
  final bool isStable;
  final List<Rect> detectedCubeBoxes; // kept for API compat, unused now

  PosePainter(
    this.poses,
    this.absoluteImageSize,
    this.rotation, {
    this.isStable = true,
    this.detectedCubeBoxes = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    final jointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = isStable ? Colors.greenAccent : Colors.redAccent;

    final leftPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.yellowAccent;

    final rightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.lightBlueAccent;

    final centerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = isStable ? Colors.greenAccent : Colors.redAccent;

    for (final pose in poses) {
      // Draw joints
      pose.landmarks.forEach((_, landmark) {
        canvas.drawCircle(
          _landmarkOffset(landmark.x, landmark.y, size),
          5,
          jointPaint,
        );
      });

      void paintLine(PoseLandmarkType t1, PoseLandmarkType t2, Paint p) {
        final j1 = pose.landmarks[t1];
        final j2 = pose.landmarks[t2];
        if (j1 == null || j2 == null) return;
        canvas.drawLine(
          _landmarkOffset(j1.x, j1.y, size),
          _landmarkOffset(j2.x, j2.y, size),
          p,
        );
      }

      // Arms
      paintLine(
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.leftElbow,
        leftPaint,
      );
      paintLine(
        PoseLandmarkType.leftElbow,
        PoseLandmarkType.leftWrist,
        leftPaint,
      );
      paintLine(
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.rightElbow,
        rightPaint,
      );
      paintLine(
        PoseLandmarkType.rightElbow,
        PoseLandmarkType.rightWrist,
        rightPaint,
      );
      // Torso
      paintLine(
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.rightShoulder,
        centerPaint,
      );
      paintLine(
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.leftHip,
        leftPaint,
      );
      paintLine(
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.rightHip,
        rightPaint,
      );
      paintLine(
        PoseLandmarkType.leftHip,
        PoseLandmarkType.rightHip,
        centerPaint,
      );
      // Legs
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, leftPaint);
      paintLine(
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.leftAnkle,
        leftPaint,
      );
      paintLine(
        PoseLandmarkType.rightHip,
        PoseLandmarkType.rightKnee,
        rightPaint,
      );
      paintLine(
        PoseLandmarkType.rightKnee,
        PoseLandmarkType.rightAnkle,
        rightPaint,
      );
    }
  }

  /// Maps ML Kit image coords → canvas, including sensor rotation.
  /// Matches google_mlkit_commons coordinate translator for back camera.
  Offset _landmarkOffset(double x, double y, Size canvasSize) {
    final imgW = absoluteImageSize.width;
    final imgH = absoluteImageSize.height;
    if (imgW <= 0 || imgH <= 0 || canvasSize.isEmpty) {
      return Offset.zero;
    }

    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return Offset(
          x * canvasSize.width / imgH,
          y * canvasSize.height / imgW,
        );
      case InputImageRotation.rotation270deg:
        return Offset(
          canvasSize.width - x * canvasSize.width / imgH,
          canvasSize.height - y * canvasSize.height / imgW,
        );
      case InputImageRotation.rotation180deg:
        return Offset(
          canvasSize.width - x * canvasSize.width / imgW,
          canvasSize.height - y * canvasSize.height / imgH,
        );
      case InputImageRotation.rotation0deg:
        return Offset(
          x * canvasSize.width / imgW,
          y * canvasSize.height / imgH,
        );
    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    if (oldDelegate.isStable != isStable) return true;
    if (oldDelegate.rotation != rotation) return true;
    if (oldDelegate.absoluteImageSize != absoluteImageSize) return true;
    if (oldDelegate.poses.length != poses.length) return true;
    if (poses.isEmpty) return oldDelegate.poses.isNotEmpty;
    // Repaint when any landmark moves — needed so skeleton follows the turn.
    final a = poses.first.landmarks;
    final b = oldDelegate.poses.first.landmarks;
    if (a.length != b.length) return true;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null) return true;
      if ((entry.value.x - other.x).abs() > 0.5 ||
          (entry.value.y - other.y).abs() > 0.5) {
        return true;
      }
    }
    return false;
  }
}
