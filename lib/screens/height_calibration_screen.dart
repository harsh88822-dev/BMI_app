import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wakelock_plus/wakelock_plus.dart';
import '../pose_detector_view.dart';
import '../main.dart';
import '../services/camera_fov_service.dart';
import '../services/height_calibration_service.dart';
import '../theme/app_theme.dart';

enum CalibrationStep {
  onboarding,
  floorScan,
  readyToMeasure,
  processing,
  success,
}

class HeightCalibrationScreen extends StatefulWidget {
  final VoidCallback? onCalibrationComplete;
  /// When true (measurement prep flow), skip/finish navigates to [PoseDetectorView]
  /// using this screen's own [BuildContext] — avoids a disposed parent context.
  final bool proceedToScanOnComplete;

  const HeightCalibrationScreen({
    super.key,
    this.onCalibrationComplete,
    this.proceedToScanOnComplete = false,
  });

  @override
  State<HeightCalibrationScreen> createState() => _HeightCalibrationScreenState();
}

class _HeightCalibrationScreenState extends State<HeightCalibrationScreen> {
  CalibrationStep _currentStep = CalibrationStep.onboarding;

  // AR Managers
  ARSessionManager? _arSessionManager;
  ARAnchorManager? _arAnchorManager;

  // Measurement State
  ARPlaneAnchor? _calibrationAnchor;
  vm.Matrix4? _lockedFloorTransform;
  double? _lockedDistance; // meters
  double? _calibratedHeightCm;
  double _adjustedHeightCm = 175.0;
  String? _errorMessage;
  bool _measureInFlight = false;
  bool _autoLockInFlight = false;
  Timer? _floorAutoLockTimer;

  // Pose Detector for single image processing
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.base,
      mode: PoseDetectionMode.single,
    ),
  );

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
  }

  @override
  void dispose() {
    _floorAutoLockTimer?.cancel();
    unawaited(WakelockPlus.disable());
    // May already be disposed in _exitCalibration before camera handoff.
    try {
      _arSessionManager?.dispose();
    } catch (_) {}
    _arSessionManager = null;
    try {
      _poseDetector.close();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() {
        _currentStep = CalibrationStep.floorScan;
      });
      _startFloorAutoLock();
    } else {
      setState(() {
        _errorMessage = "Camera permission is required for AR calibration.";
      });
    }
  }

  void _onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    _arSessionManager = arSessionManager;
    _arAnchorManager = arAnchorManager;

    _arSessionManager!.onInitialize(
      // Floor dots help users place the marker (was working before).
      // Snapshot path still clears feature points before PixelCopy to avoid OOM.
      showFeaturePoints: true,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
      showAnimatedGuide: false,
    );

    _arSessionManager!.onPlaneOrPointTap = _onPlaneOrPointTapped;
    _startFloorAutoLock();
  }

  Future<void> _onPlaneOrPointTapped(
    List<ARHitTestResult> hitTestResults, {
    bool silent = false,
  }) async {
    if (_currentStep != CalibrationStep.floorScan) return;
    if (_lockedDistance != null) return;
    if (hitTestResults.isEmpty) {
      if (!silent) {
        setState(() {
          _errorMessage =
              "Waiting for the white floor grid. Move the phone slowly over the tiles, then tap the floor by the person's feet.";
        });
      }
      return;
    }

    // Prefer a tracked plane (white grid); fall back to feature-point hits.
    // Instant Placement is disabled for height — it was placing a 1.4m fake
    // marker with only yellow dots and no white plane mesh.
    ARHitTestResult? selectedHit;
    for (final result in hitTestResults) {
      if (result.type == ARHitTestResultType.plane) {
        selectedHit = result;
        break;
      }
    }
    if (selectedHit == null) {
      for (final result in hitTestResults) {
        if (result.type == ARHitTestResultType.point) {
          selectedHit = result;
          break;
        }
      }
    }
    if (selectedHit == null) {
      if (!silent) {
        setState(() {
          _errorMessage =
              "No floor plane yet. Keep scanning until a white grid appears on the floor, then tap it.";
        });
      }
      return;
    }

    // Reject absurd distances (tap through window / sky).
    if (selectedHit.distance <= 0.15 || selectedHit.distance > 6.0) {
      if (!silent) {
        setState(() {
          _errorMessage =
              "That spot looks too far/near (${selectedHit!.distance.toStringAsFixed(1)}m). Aim at the floor near the person's feet and try again.";
        });
      }
      return;
    }

    final hit = selectedHit!;
    _floorAutoLockTimer?.cancel();
    ARPlaneAnchor? anchor;
    try {
      anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      final didAddAnchor = await _arAnchorManager?.addAnchor(anchor);
      if (didAddAnchor != true) {
        anchor = null;
      }
    } catch (_) {
      anchor = null;
    }

    if (!mounted) return;
    setState(() {
      _calibrationAnchor = anchor;
      _lockedFloorTransform = hit.worldTransform;
      _lockedDistance = hit.distance;
      _currentStep = CalibrationStep.readyToMeasure;
      _errorMessage = null;
    });
    unawaited(_prewarmPoseDetector());
  }

  /// Locks an invisible floor point at screen center once a real plane exists.
  Future<void> _tryAutoLockFloor() async {
    if (_currentStep != CalibrationStep.floorScan) return;
    if (_lockedDistance != null || _autoLockInFlight) return;
    final session = _arSessionManager;
    if (session == null) return;

    _autoLockInFlight = true;
    try {
      var hits = await session.hitTestFloor();
      if (hits.isEmpty) {
        hits = await session.hitTestScreen(
          approxDistanceMeters: 1.4,
          allowInstantPlacement: false,
        );
      }
      if (!mounted || _currentStep != CalibrationStep.floorScan) return;
      if (hits.isEmpty) return;
      final hasPlane = hits.any((h) => h.type == ARHitTestResultType.plane);
      if (!hasPlane) return;
      await _onPlaneOrPointTapped(hits, silent: true);
    } catch (_) {
      // Keep scanning until a real plane appears.
    } finally {
      _autoLockInFlight = false;
    }
  }

  void _startFloorAutoLock() {
    _floorAutoLockTimer?.cancel();
    _floorAutoLockTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      unawaited(_tryAutoLockFloor());
    });
  }

  Future<void> _exitCalibration() async {
    _floorAutoLockTimer?.cancel();
    if (!mounted) return;
    // Release AR/camera before opening the BMI pose camera — overlapping
    // CameraX + ARCore sessions crash on first Measure→Scan handoff.
    try {
      _arSessionManager?.dispose();
    } catch (_) {}
    _arSessionManager = null;
    _arAnchorManager = null;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    if (widget.onCalibrationComplete != null) {
      widget.onCalibrationComplete!();
      return;
    }
    if (widget.proceedToScanOnComplete) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PoseDetectorView()),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  void _skipCalibration() async {
    await HeightCalibrationService.clearCalibratedHeight();
    await _exitCalibration();
  }

  void _finishCalibration() async {
    if (_calibratedHeightCm != null) {
      await HeightCalibrationService.saveCalibratedHeight(_adjustedHeightCm);
    }
    await _exitCalibration();
  }

  /// AR snapshot already returns [MemoryImage] bytes — avoid PNG re-encode
  /// which can hang / OOM on mid-range Android during Measure Height.
  Future<Uint8List> _bytesFromSnapshot(ImageProvider imageProvider) async {
    if (imageProvider is MemoryImage) {
      return imageProvider.bytes;
    }

    final ImageStream stream =
        imageProvider.resolve(const ImageConfiguration());
    final Completer<Uint8List> completer = Completer<Uint8List>();

    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo imageInfo, bool synchronousCall) async {
        try {
          final ByteData? byteData =
              await imageInfo.image.toByteData(format: ui.ImageByteFormat.png);
          if (!completer.isCompleted) {
            if (byteData == null) {
              completer.completeError(Exception('Failed to decode snapshot.'));
            } else {
              completer.complete(byteData.buffer.asUint8List());
            }
          }
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
      onError: (dynamic exception, StackTrace? stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(exception, stackTrace);
        }
      },
    );

    stream.addListener(listener);
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      stream.removeListener(listener);
    }
  }

  Future<T> _withTimeout<T>(
    Future<T> future, {
    required Duration timeout,
    required String label,
  }) {
    return future.timeout(
      timeout,
      onTimeout: () => throw Exception('$label timed out. Try Measure again.'),
    );
  }

  /// Load ML Kit pose model before Measure so first tap isn't cold-start + snapshot.
  Future<void> _prewarmPoseDetector() async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 64, 64),
        Paint()..color = const Color(0xFF888888),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) return;
      final dir = await getTemporaryDirectory();
      final tiny = File('${dir.path}/pose_prewarm.png');
      await tiny.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      await _poseDetector
          .processImage(InputImage.fromFilePath(tiny.path))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('Pose prewarm skipped: $e');
    }
  }

  Future<void> _processCalibration() async {
    if (_measureInFlight) return;
    if (_lockedDistance == null || _arSessionManager == null) {
      setState(() {
        _errorMessage =
            'Floor is not locked yet. Move slowly until the white grid appears, then tap the floor by the feet.';
        _currentStep = CalibrationStep.floorScan;
      });
      _startFloorAutoLock();
      return;
    }

    _measureInFlight = true;
    setState(() {
      _currentStep = CalibrationStep.processing;
      _errorMessage = null;
    });

    // Brief settle so GL / ARCore aren't mid-update during first PixelCopy.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) {
      _measureInFlight = false;
      return;
    }

    File? tempFile;
    ui.Image? uiImage;
    try {
      Uint8List bytes = Uint8List(0);
      try {
        final imageProvider = await _withTimeout(
          _arSessionManager!.snapshot(),
          timeout: const Duration(seconds: 4),
          label: 'AR snapshot',
        );
        bytes = await _bytesFromSnapshot(imageProvider);
      } catch (e) {
        debugPrint('AR snapshot failed, trying camera jpeg: $e');
      }
      if (bytes.isEmpty) {
        final jpeg = await _arSessionManager!.captureCameraJpeg().timeout(
          const Duration(seconds: 4),
          onTimeout: () => null,
        );
        if (jpeg != null && jpeg.isNotEmpty) {
          bytes = jpeg;
        }
      }
      if (bytes.isEmpty) {
        throw Exception('Could not capture the AR image. Try Measure again.');
      }

      // Decode only for dimensions, then dispose — feed original JPEG to ML Kit
      // so landmark coords match imageWidth/Height (no PNG re-encode / OOM).
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      uiImage = frameInfo.image;
      final double imageHeight = uiImage.height.toDouble();
      final double imageWidth = uiImage.width.toDouble();
      try {
        uiImage.dispose();
      } catch (_) {}
      uiImage = null;

      final tempDir = await getTemporaryDirectory();
      final isJpeg = bytes.length >= 3 &&
          bytes[0] == 0xFF &&
          bytes[1] == 0xD8 &&
          bytes[2] == 0xFF;
      tempFile = File(
        '${tempDir.path}/calib_snapshot_${DateTime.now().millisecondsSinceEpoch}.${isJpeg ? 'jpg' : 'png'}',
      );
      await tempFile.writeAsBytes(bytes, flush: true);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final poses = await _withTimeout(
        _poseDetector.processImage(inputImage),
        timeout: const Duration(seconds: 12),
        label: 'Pose analysis',
      );

      if (poses.isEmpty) {
        throw Exception(
          'No person detected. Step back so head and feet are both visible, then Measure.',
        );
      }

      final pose = poses.first;
      final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
      final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
      final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
      final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
      final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
      final rightHip = pose.landmarks[PoseLandmarkType.rightHip];

      if (leftShoulder == null || rightShoulder == null) {
        throw Exception(
          'Step back so the full body (head to feet) is visible, then Measure.',
        );
      }

      // Ankle likelihood is often low with sandals / partial framing.
      // Prefer ankles when usable; otherwise estimate feet from hips.
      final anklesUsable = leftAnkle != null &&
          rightAnkle != null &&
          leftAnkle.likelihood >= 0.2 &&
          rightAnkle.likelihood >= 0.2;

      final hipY = leftHip?.y ?? rightHip?.y;
      late final double footY;
      if (anklesUsable) {
        footY = (leftAnkle.y + rightAnkle.y) / 2.0;
      } else if (hipY != null) {
        final shoulderMidY = (leftShoulder.y + rightShoulder.y) / 2.0;
        final torso = (hipY - shoulderMidY).abs();
        // Legs are typically a bit longer than torso; approximate ankles.
        footY = hipY + torso * 1.18;
      } else {
        throw Exception(
          'Feet not visible. Step back until head and feet are in frame, then Measure.',
        );
      }

      final double headOffset =
          ((leftShoulder.y + rightShoulder.y) / 2.0 - (hipY ?? leftShoulder.y))
              .abs() *
          0.78;
      final double headY =
          ((leftShoulder.y + rightShoulder.y) / 2.0) - headOffset;
      final double pixelHeight = (footY - headY).abs();

      if (pixelHeight <= 0) {
        throw Exception('Invalid pose landmarks height.');
      }

      double distance = _lockedDistance ?? 2.0;
      final anchor = _calibrationAnchor;
      if (anchor != null) {
        try {
          final currentDistance =
              await _arSessionManager!.getDistanceFromAnchor(anchor);
          if (currentDistance != null && currentDistance > 0) {
            distance = currentDistance;
          }
        } catch (e) {
          debugPrint('AR distance fallback to locked: $e');
        }
      }

      vm.Matrix4? cameraPose;
      vm.Matrix4? anchorPose = _lockedFloorTransform;
      try {
        cameraPose = await _arSessionManager!.getCameraPose();
        if (anchor != null) {
          anchorPose =
              await _arSessionManager!.getPose(anchor) ?? anchorPose;
        }
      } catch (e) {
        debugPrint('Failed to retrieve AR poses: $e');
      }

      final verticalFovDegrees = await CameraFovService.verticalFovDegrees();
      final focalLength = CameraFovService.focalLengthPx(
        imageHeightPx: imageHeight,
        verticalFovDegrees: verticalFovDegrees,
      );

      late final double calibratedCm;

      if (cameraPose != null && anchorPose != null) {
        final cameraTranslation = cameraPose.getTranslation();
        final anchorTranslation = anchorPose.getTranslation();

        final double dxAnchor = anchorTranslation.x - cameraTranslation.x;
        final double dzAnchor = anchorTranslation.z - cameraTranslation.z;
        final double dHoriz = sqrt(dxAnchor * dxAnchor + dzAnchor * dzAnchor);

        final double headX = (leftShoulder.x + rightShoulder.x) / 2.0;
        final double xHeadC = headX - (imageWidth / 2.0);
        final double yHeadC = (imageHeight / 2.0) - headY;
        final double zHeadC = -focalLength;

        final rayDirCamera = vm.Vector3(xHeadC, yHeadC, zHeadC)..normalize();
        final rayDirWorld = cameraPose.rotated3(rayDirCamera);

        final double uX = anchorTranslation.x - cameraTranslation.x;
        final double uZ = anchorTranslation.z - cameraTranslation.z;
        final double vX = rayDirWorld.x;
        final double vZ = rayDirWorld.z;

        final double vSq = vX * vX + vZ * vZ;
        double physicalHeightM = 0.0;
        if (vSq > 0.0) {
          final double s = (uX * vX + uZ * vZ) / vSq;
          final double yIntersect = cameraTranslation.y + s * rayDirWorld.y;
          physicalHeightM = yIntersect - anchorTranslation.y;
        }

        if (physicalHeightM <= 0.5 ||
            physicalHeightM > 3.0 ||
            physicalHeightM.isNaN) {
          final double perpDistance = dHoriz > 0.0 ? dHoriz : distance;
          physicalHeightM = perpDistance * (pixelHeight / focalLength);
        } else {
          final double perpDistance = dHoriz > 0.0 ? dHoriz : distance;
          final pinholeHeightM =
              perpDistance * (pixelHeight / focalLength);
          if (pinholeHeightM > physicalHeightM * 1.04) {
            physicalHeightM =
                (physicalHeightM * 0.35) + (pinholeHeightM * 0.65);
          }
        }

        calibratedCm = physicalHeightM * 100.0 * HEIGHT_CORRECTION_FACTOR;
      } else {
        const double assumedCamHeight = 1.3;
        final double dHorizEst = sqrt(
          max(0.1, distance * distance - assumedCamHeight * assumedCamHeight),
        );
        final double physicalHeightM = dHorizEst * (pixelHeight / focalLength);
        calibratedCm = physicalHeightM * 100.0 * HEIGHT_CORRECTION_FACTOR;
      }

      if (calibratedCm < 100.0 || calibratedCm > 250.0) {
        throw Exception(
          'Height ${calibratedCm.toStringAsFixed(1)} cm looks off. '
          'Step back for full body, Rescan floor, then Measure again.',
        );
      }

      if (!mounted) return;
      setState(() {
        _calibratedHeightCm = calibratedCm;
        _adjustedHeightCm = double.parse(calibratedCm.toStringAsFixed(1));
        _currentStep = CalibrationStep.success;
        _errorMessage = null;
      });
    } catch (e) {
      debugPrint('AR measure failed: $e');
      if (!mounted) return;
      setState(() {
        _currentStep = CalibrationStep.readyToMeasure;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _measureInFlight = false;
      try {
        uiImage?.dispose();
      } catch (_) {}
      if (tempFile != null) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  /// Compact bottom card for AR steps so head–feet stay visible in the camera.
  Widget _buildArBottomCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.parchment.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: child,
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.parchment.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: child,
    );
  }

  Widget _buildStepProgress() {
    int activeIndex = 0;
    if (_currentStep == CalibrationStep.floorScan) activeIndex = 1;
    if (_currentStep == CalibrationStep.readyToMeasure) activeIndex = 2;
    if (_currentStep == CalibrationStep.processing) activeIndex = 3;
    if (_currentStep == CalibrationStep.success) activeIndex = 4;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        bool isDone = index < activeIndex;
        bool isActive = index == activeIndex;
        return Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone
                    ? AppTheme.deepBlue
                    : isActive
                        ? AppTheme.champagne
                        : AppTheme.divider,
              ),
            ),
            if (index < 4)
              Container(
                width: 24,
                height: 2,
                color: isDone ? AppTheme.deepBlue : AppTheme.divider,
              ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Height Calibration"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_currentStep != CalibrationStep.processing &&
              _currentStep != CalibrationStep.success)
            TextButton(
              onPressed: _skipCalibration,
              child: const Text('Skip AR'),
            ),
        ],
      ),
      body: Stack(
        children: [
          // Background/AR View
          if (_currentStep == CalibrationStep.floorScan ||
              _currentStep == CalibrationStep.readyToMeasure ||
              _currentStep == CalibrationStep.processing)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            )
          else
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.parchment, Colors.white],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

          // Instruction overlays — middle area is tap-through so AR floor taps work.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: _buildStepProgress(),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade900.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  Expanded(
                    child: IgnorePointer(
                      child: const SizedBox.expand(),
                    ),
                  ),
                  if (_currentStep == CalibrationStep.onboarding ||
                      _currentStep == CalibrationStep.success)
                    _buildGlassCard(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_currentStep == CalibrationStep.onboarding) ...[
                            const Text(
                              "Calibrate with AR",
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.ink),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              "To ensure precise body metrics without assuming a fixed guide height, we will use AR to detect the floor and measure your exact physical height.",
                              style: TextStyle(fontSize: 14, color: AppTheme.inkMuted, height: 1.4),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            FilledButton(
                              onPressed: _requestPermissions,
                              child: const Text("Start AR Calibration"),
                            ),
                          ],
                          if (_currentStep == CalibrationStep.success) ...[
                            const Icon(
                              Icons.check_circle_rounded,
                              color: AppTheme.deepBlue,
                              size: 48,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "Calibration Complete!",
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.ink),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "Fine-tune the height below if the AR measurement is slightly off.",
                              style: TextStyle(fontSize: 12, color: AppTheme.inkMuted),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppTheme.divider),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton.filledTonal(
                                        onPressed: () {
                                          setState(() {
                                            _adjustedHeightCm = (_adjustedHeightCm - 0.5).clamp(120.0, 220.0);
                                          });
                                        },
                                        icon: const Icon(Icons.remove, size: 20),
                                        style: IconButton.styleFrom(
                                          foregroundColor: AppTheme.deepBlue,
                                          backgroundColor: AppTheme.deepBlue.withValues(alpha: 0.1),
                                          minimumSize: const Size(40, 40),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            "${_adjustedHeightCm.toStringAsFixed(1)} cm",
                                            maxLines: 1,
                                            style: const TextStyle(
                                              fontSize: 28,
                                              fontWeight: FontWeight.w800,
                                              color: AppTheme.ink,
                                              fontFeatures: [ui.FontFeature.tabularFigures()],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      IconButton.filledTonal(
                                        onPressed: () {
                                          setState(() {
                                            _adjustedHeightCm = (_adjustedHeightCm + 0.5).clamp(120.0, 220.0);
                                          });
                                        },
                                        icon: const Icon(Icons.add, size: 20),
                                        style: IconButton.styleFrom(
                                          foregroundColor: AppTheme.deepBlue,
                                          backgroundColor: AppTheme.deepBlue.withValues(alpha: 0.1),
                                          minimumSize: const Size(40, 40),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: AppTheme.deepBlue,
                                      inactiveTrackColor: AppTheme.divider,
                                      thumbColor: AppTheme.deepBlue,
                                      overlayColor: AppTheme.deepBlue.withValues(alpha: 0.12),
                                      trackHeight: 4,
                                    ),
                                    child: Slider(
                                      value: _adjustedHeightCm.clamp(120.0, 220.0),
                                      min: 120.0,
                                      max: 220.0,
                                      divisions: 200,
                                      onChanged: (val) {
                                        setState(() {
                                          _adjustedHeightCm = double.parse(val.toStringAsFixed(1));
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _finishCalibration,
                              child: const Text("Confirm & Proceed to Scan"),
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    _buildArBottomCard(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_currentStep == CalibrationStep.floorScan) ...[
                            const Text(
                              "Floor detection",
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.ink),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "Move the phone slowly over the floor until a white grid appears, then tap the floor by the person's feet. Height locks automatically once the floor is found.",
                              style: TextStyle(fontSize: 12.5, color: AppTheme.inkMuted, height: 1.3),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _skipCalibration,
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                              ),
                              child: const Text('Continue without AR'),
                            ),
                          ],

                          if (_currentStep == CalibrationStep.readyToMeasure) ...[
                            Text(
                              "Full body in frame · floor ${_lockedDistance?.toStringAsFixed(2)}m",
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppTheme.ink),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              "Step back until head and feet are visible, then Measure.",
                              style: TextStyle(fontSize: 12, color: AppTheme.inkMuted, height: 1.25),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () {
                                      setState(() {
                                        _calibrationAnchor = null;
                                        _lockedFloorTransform = null;
                                        _lockedDistance = null;
                                        _errorMessage = null;
                                        _currentStep = CalibrationStep.floorScan;
                                      });
                                      _startFloorAutoLock();
                                    },
                                    style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                    child: const Text("Rescan"),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _measureInFlight ? null : _processCalibration,
                                    style: FilledButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                    child: const Text("Measure Height"),
                                  ),
                                ),
                              ],
                            ),
                          ],

                          if (_currentStep == CalibrationStep.processing) ...[
                            const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.deepBlue),
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  "Measuring height…",
                                  style: TextStyle(fontSize: 13, color: AppTheme.inkMuted, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
