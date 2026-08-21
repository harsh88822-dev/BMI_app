import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../screens/height_calibration_screen.dart';
import '../services/height_calibration_service.dart';
import 'measurement_onboarding_video.dart';

class MeasurementPrepScreen extends StatefulWidget {
  const MeasurementPrepScreen({super.key});

  @override
  State<MeasurementPrepScreen> createState() => _MeasurementPrepScreenState();
}

class _MeasurementPrepScreenState extends State<MeasurementPrepScreen> {
  final GlobalKey<MeasurementOnboardingVideoState> _videoKey =
      GlobalKey<MeasurementOnboardingVideoState>();

  Future<bool> _ensureScanPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.photos,
    ].request();

    final cameraOk = statuses[Permission.camera]?.isGranted ?? false;
    if (cameraOk) return true;

    if (!mounted) return false;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Camera access needed'),
        content: const Text(
          'Clockwork BMI needs camera access to run the body scan. '
          'Please enable Camera in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await openAppSettings();
    }
    return false;
  }

  void _beginMeasurement() async {
    final allowed = await _ensureScanPermissions();
    if (!allowed || !mounted) return;

    await _videoKey.currentState?.stopPlayback();
    if (!mounted) return;

    // Always start from AR height — every measurement begins from the start.
    await HeightCalibrationService.clearCalibratedHeight();
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const HeightCalibrationScreen(
          proceedToScanOnComplete: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;

    return Scaffold(
      appBar: AppBar(title: const Text('How to scan')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight;
            final videoHeight = math
                .min(
                  available * (isTablet ? 0.72 : 0.68),
                  isTablet ? 560.0 : 480.0,
                )
                .clamp(240.0, 600.0);

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 28 : 16,
                vertical: 12,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: MeasurementOnboardingVideo(
                        key: _videoKey,
                        height: videoHeight,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _beginMeasurement,
                      icon: const Icon(Icons.play_arrow_rounded, size: 26),
                      style: FilledButton.styleFrom(
                        textStyle: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      label: const Text("Let's Go"),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
