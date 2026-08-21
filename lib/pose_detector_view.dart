import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'camera_view.dart';
import 'measurement/body_metrics.dart';
import 'measurement/face_verification_state.dart';
import 'painters/pose_painter.dart';
import 'result_screen.dart';
import 'main.dart';
import 'services/user_api_service.dart';
import 'services/height_calibration_service.dart';
import 'services/scan_telemetry_service.dart';
import 'widgets/bmi_loader.dart';

enum ScanPhase {
  calibration,
  staticMeasurement,
  readyToRotate,
  rotation,
  completed,
}

class PoseDetectorView extends StatefulWidget {
  const PoseDetectorView({super.key});

  @override
  State<StatefulWidget> createState() => _PoseDetectorViewState();
}

class _PoseDetectorViewState extends State<PoseDetectorView>
    with WidgetsBindingObserver {
  static const int _minValidRotationFrames = 45;
  static const double _minValidRotationFrameRatio = 0.35;
  static const double _targetRotationQualityScore = 0.68;
  static const double _minRotationQualityScoreToSubmit = 0.60;
  static const int _minRotationStableSamples = 30;
  static const int _minMetricStableSamples = 24;
  static const int _minFrontWidthSamples = 8;
  static const int _minSideDepthSamples = 8;
  /// Collect both views during the turn; keep mins reachable in ~12–20s.
  int get _effectiveMinFrontSamples =>
      Platform.isAndroid ? 3 : 4;
  int get _effectiveMinSideSamples =>
      Platform.isAndroid ? 3 : 4;
  static const double _maxAllowedRelativeDispersion = 0.18;
  static const double _maxAllowedMetricDispersion = 0.14;
  static const double _shoulderToHeightRatio = 0.25;
  static const double _fallbackHeightMeters = 1.70;
  /// Count quality samples from the first valid frames of the turn.
  // Collect front/side early on both platforms so short turns still get width/depth.
  int get _qualityWarmupFrames => Platform.isAndroid ? 0 : 6;
  static const int _maxStreamRecoveryAttempts = 5;
  static const int _streamStartupGraceSeconds = 8;
  /// Segmentation disabled during 360 on both platforms (pose-only volume).
  int get _segmentationFrameInterval => 999999;
  static const int _minSilhouetteSamples = 6;
  static const double _maskForegroundThreshold = 0.55;

  final GlobalKey<CameraViewState> _cameraViewKey =
      GlobalKey<CameraViewState>();
  PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.base,
      mode: PoseDetectionMode.stream,
    ),
  );

  PoseDetectionMode _poseDetectionModeForCurrentPhase() {
    // Always use stream mode so the skeleton tracks the body as the person
    // turns. Load is controlled by camera frame stride + single in-flight processImage.
    return PoseDetectionMode.stream;
  }

  final SelfieSegmenter _selfieSegmenter = SelfieSegmenter(
    mode: SegmenterMode.stream,
  );

  bool _canProcess = true;
  bool _isBusy = false;
  bool _isSegmenting = false;
  CustomPainter? _customPainter;
  String _text = 'Stand inside the guide box';
  final _cameraLensDirection = CameraLensDirection.back;

  // Scanning state
  ScanPhase currentPhase = ScanPhase.calibration;
  int _frameCount = 0;
  int _staticFrameCount = 0;
  int _totalFrames = 0;
  int _rotationValidFrameCount = 0;
  int _rotationMissingShoulderFrameCount = 0;
  int _rotationMissingAnkleFrameCount = 0;
  bool _personInFrame = false;
  String? _latestVideoPath;
  bool _isSubmittingManualCalibration = false;
  int _verificationStepIndex = 0;
  Timer? _verificationStepTimer;
  DateTime _lastFrameTime = DateTime.now();
  DateTime? _busySince;
  Timer? _frameReceptionWatchdog;
  Timer? _rotationDurationGuard;
  Timer? _frameProgressGuard;
  Timer? _rotationFailsafeTimer;
  DateTime? _rotationStartedAt;
  bool _autoStoppedByDurationCap = false;
  bool _qualityTooLowAtAutoStop = false;
  bool _autoStoppedByStreamIssue = false;
  bool _isRecoveringStream = false;
  bool _isStoppingAfterCompletion = false;
  bool _navigatingToResults = false;
  bool _showInlineResults = false;
  bool _androidVerifyStarted = false;
  _LocalEstimate? _inlineResult;
  ValueNotifier<FaceVerificationState>? _inlineFaceVerify;
  bool _isScanRecording = false;
  int _uploadClipSeconds = 8;
  DateTime? _uploadClipStartedAt;
  int _streamRecoveryAttempts = 0;
  int _lastGuardObservedFrameCount = 0;
  int _lastGuardObservedCallbackCount = 0;
  int _cameraCallbackCount = 0;
  InputImage? _pendingInputImage;
  Timer? _androidScanHealthMonitor;
  int _lastHealthObservedFrameCount = 0;
  int _lastHealthObservedCallbackCount = 0;
  int _lastHealthObservedValidCount = 0;
  /// Caps detector thrash when valid frames freeze (was resetting forever at 9/36).
  int _validStallUnstickCount = 0;
  DateTime? _lastValidStallUnstickAt;
  int _lastSegmentedFrameCount = -999;
  int _lastPoseDiagCallbackCount = 0;
  int _lastPoseDiagFrameCount = 0;
  int _lastPoseDiagValidCount = 0;
  int _lastPoseDiagPaintedCount = 0;
  bool _isPoseDetectorResetting = false;
  DateTime? _lastPoseDetectorResetAt;
  bool _processingInFlight = false;
  int _processingGeneration = 0;
  static const Duration _poseProcessTimeout = Duration(milliseconds: 2500);
  DateTime? _lastValidProgressAt;
  int _lastObservedValidForProgress = 0;
  int _lastPaintSetStateValid = 0;
  DateTime? _lastPaintSetStateAt;
  /// Last non-empty skeleton — short grace only (not forever), or the overlay
  /// freezes while valid stays at 0/target (video 14.22.07 @ ~43s).
  CustomPainter? _lastGoodPosePainter;
  DateTime? _lastGoodPosePainterAt;
  /// Cached in build() — async pose path must not call MediaQuery.
  double _screenHeightCached = 0;
  double _screenWidthCached = 0;
  Timer? _rotationProgressWatchdog;
  Timer? _uploadClipProgressTicker;
  Timer? _completionFailsafe;
  final Duration _frameReceptionTimeout = const Duration(seconds: 5);
  static const Color _brandBlue = Color(0xFF1243A8);
  static const Color _brandOrange = Color(0xFFFF6A00);

  // Calibrated physical height in cm (loaded from SharedPreferences)
  double? _calibratedHeightCm;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_enableWakeLock());
    _loadCalibratedHeight();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enableWakeLock());
      if (currentPhase == ScanPhase.rotation && !_isStoppingAfterCompletion) {
        // Never reinit mid-360 while recording (Android CameraX + iOS AVCapture).
        if (_isScanRecording) return;
        final cam = _cameraViewKey.currentState;
        if (cam != null &&
            (cam.isRecordingActive || cam.isAndroidScanRecording)) {
          return;
        }
        unawaited(_recoverCameraPipeline(forceReinit: false));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Keep wake lock requested; OS may still pause the camera briefly.
      debugPrint('Scan lifecycle: $state — camera may pause briefly');
    }
  }

  Future<void> _enableWakeLock() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('WakeLock enable failed: $e');
    }
  }

  Future<void> _disableWakeLock() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('WakeLock disable failed: $e');
    }
  }

  Future<void> _loadCalibratedHeight() async {
    final height = await HeightCalibrationService.getCalibratedHeight();
    if (mounted) {
      setState(() {
        _calibratedHeightCm = height;
      });
    }
  }

  // Scale calibration via on-screen guide box (cm per **screen** pixel).
  double? cmPerPixel;

  // Locked measurements (Phase 2) — stored in **screen pixel** space to match
  // [cmPerPixel] and the guide frame overlay.
  double? lockedHeightPx;
  double? lockedShoulderWidthPx;
  double _maxBodyAreaPx = 0;
  double _smoothedHeight = 0;
  double _smoothedWidth = 0;
  double _smoothedDepth = 0;
  double _maxWidth = 0;
  double _minWidth = double.infinity;
  bool _isRotationComplete = false;
  int _stableFrameCount = 0;
  double _smoothedHeightPx = 0;
  double _smoothedWidthPx = 0;
  double _maxWidthPx = 0;
  double _minWidthPx = double.infinity;

  // Measurement samples
  List<double> heightSamplesPx = [];
  List<double> shoulderWidthSamplesPx = [];
  final List<double> _rotationHeightSamplesPx = <double>[];
  final List<double> _rotationShoulderSamplesPx = <double>[];
  final List<double> _rotationEstimatedHeightSamplesM = <double>[];
  final List<double> _rotationWidthSamplesM = <double>[];
  final List<double> _rotationFrontWidthSamplesM = <double>[];
  final List<double> _rotationSideDepthSamplesM = <double>[];
  final List<double> _rotationFrontHipWidthSamplesM = <double>[];
  final List<double> _silhouetteFrontWidthSamplesM = <double>[];
  final List<double> _silhouetteSideDepthSamplesM = <double>[];
  final List<double> _silhouetteWaistSamplesM = <double>[];

  // Guide box real-world height (cm) — treated as 185cm standard
  static const double guideRealHeightCm = 185.0;

  // Guide box pixel dimensions — set in build() from screen size
  double _guideHeightPx = 0;
  double _guideTopY = 0;
  double _guideBottomY = 0;

  /// Maps a vertical distance measured in ML Kit image coordinates to the
  /// corresponding distance in screen pixels (same space as [_guideHeightPx]).
  double _verticalImageDeltaToScreenPx(
    double deltaImage,
    Size imageSize,
    InputImageRotation rotation,
  ) {
    final screenH = _screenHeightCached > 0
        ? _screenHeightCached
        : MediaQuery.sizeOf(context).height;
    final rotated =
        rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final denom = rotated ? imageSize.width : imageSize.height;
    if (denom <= 0) return 0;
    return deltaImage * screenH / denom;
  }

  /// Maps a horizontal distance in image coordinates to screen pixels.
  double _horizontalImageDeltaToScreenPx(
    double deltaImage,
    Size imageSize,
    InputImageRotation rotation,
  ) {
    final screenW = _screenWidthCached > 0
        ? _screenWidthCached
        : MediaQuery.sizeOf(context).width;
    final rotated =
        rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final denom = rotated ? imageSize.height : imageSize.width;
    if (denom <= 0) return 0;
    return deltaImage * screenW / denom;
  }

  double trimmedMean(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.from(values)..sort();

    // Discard top and bottom 25% of samples to remove noisy extremes
    int trimCount = (sorted.length * 0.25).floor();

    // Fallback if list is too small to trim
    if (trimCount * 2 >= sorted.length) return sorted.first;

    final trimmed = sorted.sublist(trimCount, sorted.length - trimCount);
    double sum = 0;
    for (var v in trimmed) {
      sum += v;
    }
    return sum / trimmed.length;
  }

  double _smooth(double prev, double current) {
    if (prev <= 0) return current;
    return (prev * 0.7) + (current * 0.3);
  }

  double _heightFromBodyWidth(double widthM) {
    final heightFromWidth = widthM / _shoulderToHeightRatio;
    final height = (heightFromWidth * 0.6) + (_fallbackHeightMeters * 0.4);
    return height.clamp(BodyMetrics.minHeightM, BodyMetrics.maxHeightM);
  }

  double _effectiveCmPerPixel() {
    return BodyMetrics.cmPerPixel(
      lockedCmPerPixel: cmPerPixel,
      guideRealHeightCm: guideRealHeightCm,
      guideHeightPx: _guideHeightPx,
    );
  }

  /// Lateral scale for shoulders/depth. Does not bake in head/toe height
  /// correction (that correction is only for vertical pose height).
  double _lateralCmPerPixel() {
    if (_calibratedHeightCm != null &&
        lockedHeightPx != null &&
        lockedHeightPx! > 0) {
      return _calibratedHeightCm! / lockedHeightPx!;
    }
    return _effectiveCmPerPixel();
  }

  /// Best height source: AR measurement, then stand-still lock.
  double? _lockedHeightMeters() {
    if (_calibratedHeightCm != null &&
        _calibratedHeightCm!.isFinite &&
        _calibratedHeightCm! > 100) {
      return (_calibratedHeightCm! / 100.0).clamp(
        BodyMetrics.minHeightM,
        BodyMetrics.maxHeightM,
      );
    }
    if (lockedHeightPx == null || lockedHeightPx! <= 0) return null;
    return BodyMetrics.heightMetersFromScreenPx(
      heightPx: lockedHeightPx!,
      cmPerPx: _lateralCmPerPixel(),
    );
  }

  double _poseHeightMeters(
    double screenHeightPx, {
    bool applyCorrection = true,
  }) {
    return BodyMetrics.heightMetersFromScreenPx(
      heightPx: screenHeightPx,
      cmPerPx: _effectiveCmPerPixel(),
      applyHeadToeCorrection: applyCorrection,
    );
  }

  double _estimateWeightKg({
    required double heightM,
    required double widthM,
    required double depthM,
  }) {
    final silhouetteReady = min(
      _silhouetteFrontWidthSamplesM.length,
      _silhouetteSideDepthSamplesM.length,
    );
    final silhouetteQuality =
        (silhouetteReady / _minSilhouetteSamples).clamp(0.0, 1.0);
    const silhouetteShapeFactor = 0.395;
    // Android is pose-only (no silhouette). Shoulder landmarks under-read
    // torso, so do not apply the extra 0.88 cut that was shrinking weight.
    final poseOnlyShapeFactor = BODY_SHAPE_FACTOR;
    final shapeFactor = poseOnlyShapeFactor * (1.0 - silhouetteQuality) +
        silhouetteShapeFactor * silhouetteQuality;
    var weightKg = BodyMetrics.weightKgFromDimensions(
      heightM: heightM,
      widthM: widthM,
      depthM: depthM,
      shapeFactor: shapeFactor,
    );
    if (silhouetteQuality < 0.15) {
      weightKg *= POSE_WEIGHT_CALIBRATION;
    }
    return weightKg;
  }

  bool _canStartRecording() {
    if (currentPhase == ScanPhase.rotation) return true;
    return currentPhase == ScanPhase.readyToRotate &&
        lockedHeightPx != null &&
        lockedShoulderWidthPx != null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _canProcess = false;
    _poseDetector.close();
    _selfieSegmenter.close();
    _frameReceptionWatchdog?.cancel(); // Cancel watchdog on dispose
    _verificationStepTimer?.cancel();
    _rotationDurationGuard?.cancel();
    _frameProgressGuard?.cancel();
    _androidScanHealthMonitor?.cancel();
    _rotationProgressWatchdog?.cancel();
    _uploadClipProgressTicker?.cancel();
    _completionFailsafe?.cancel();
    _rotationFailsafeTimer?.cancel();
    unawaited(_disableWakeLock());
    super.dispose();
  }

  /// Leave capture: stop recording if active, then pop (prep / dashboard).
  Future<void> _exitCapture() async {
    await _cameraViewKey.currentState?.stopVideoRecording();
    await _disableWakeLock();
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  Future<void> _submitCompletedScan({
    required bool enforceQualityChecks,
  }) async {
    final videoPath = _latestVideoPath;
    if (videoPath == null ||
        videoPath.isEmpty ||
        _isSubmittingManualCalibration) {
      return;
    }
    final videoFile = File(videoPath);
    if (!videoFile.existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verification video file is missing. Please retake.'),
        ),
      );
      return;
    }
    final blockReason = enforceQualityChecks
        ? _manualCalibrationBlockReason()
        : null;
    if (blockReason != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(blockReason)));
      return;
    }

    final estimate = _buildSubmissionEstimate();
    if (estimate == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not read enough body landmarks. Please retake with full body visible.',
          ),
        ),
      );
      return;
    }

    setState(() => _isSubmittingManualCalibration = true);
    _startVerificationSteps();
    try {
      final qualityBreakdown = _rotationQualityBreakdown();
      final response = await UserApiService().requestBmiUploadUrl(
        videoFile: videoFile,
        heightDetectedCm: estimate.heightCm,
        weightEstimatedKg: estimate.weightKg,
        estimatedBmi: estimate.bmi,
        processingMetadata: <String, dynamic>{
        'cm_per_pixel': estimate.cmPerPixel,
        'median_height_px': estimate.heightPx,
        'median_shoulder_width_px': estimate.shoulderWidthPx,
        'max_body_area_px': estimate.maxBodyAreaPx,
        'depth_px': estimate.depthPx,
        'max_width_px': _maxWidthPx,
        'min_width_px': _minWidthPx.isFinite ? _minWidthPx : null,
        'frame_count': _frameCount,
        'valid_rotation_frame_count': _rotationValidFrameCount,
        'missing_shoulder_frame_count': _rotationMissingShoulderFrameCount,
        'missing_ankle_frame_count': _rotationMissingAnkleFrameCount,
        'quality_coverage_score': qualityBreakdown.coverageScore,
        'quality_stability_score': qualityBreakdown.stabilityScore,
        'quality_completeness_score': qualityBreakdown.completenessScore,
        'quality_final_score': qualityBreakdown.finalScore,
        'quality_min_submit_score': _minRotationQualityScoreToSubmit,
        'quality_target_score': _targetRotationQualityScore,
        'quality_max_relative_dispersion': _maxAllowedRelativeDispersion,
        'metric_height_sample_count': _rotationEstimatedHeightSamplesM.length,
        'metric_width_sample_count': _rotationWidthSamplesM.length,
        'front_width_sample_count': _rotationFrontWidthSamplesM.length,
        'side_depth_sample_count': _rotationSideDepthSamplesM.length,
        'silhouette_front_width_sample_count':
            _silhouetteFrontWidthSamplesM.length,
        'silhouette_side_depth_sample_count':
            _silhouetteSideDepthSamplesM.length,
        'silhouette_waist_sample_count': _silhouetteWaistSamplesM.length,
        'silhouette_front_width_m': _robustMetricMean(
          _silhouetteFrontWidthSamplesM,
          fallback: 0,
          minSamples: _minSilhouetteSamples,
        ),
        'silhouette_side_depth_m': _robustMetricMean(
          _silhouetteSideDepthSamplesM,
          fallback: 0,
          minSamples: _minSilhouetteSamples,
        ),
        'estimated_waist_width_m': _robustMetricMean(
          _silhouetteWaistSamplesM,
          fallback: 0,
          minSamples: _minSilhouetteSamples,
        ),
        'metric_height_dispersion': _metricRelativeDispersion(
          _rotationEstimatedHeightSamplesM,
        ),
        'metric_width_dispersion': _metricRelativeDispersion(
          _rotationWidthSamplesM,
        ),
        'height_m': estimate.heightCm / 100,
        'width_m': estimate.widthM,
        'depth_m': estimate.depthM,
        'quality_min_stable_samples': _minRotationStableSamples,
        'phase': currentPhase.name,
        },
      );
      if (!mounted) return;

      if (response.ok) {
        final serverMeasurement = _asStringMap(response.data);
        _openResultScreen(
          showFaceMismatchWarning: false,
          faceMismatchMessage: null,
          serverMeasurement: serverMeasurement,
        );
        return;
      }

      final shouldContinue = await _showFaceMismatchDialog(response.message);
      if (!mounted) return;
      if (shouldContinue == true) {
        final serverMeasurement = _asStringMap(response.data);
        _openResultScreen(
          showFaceMismatchWarning: true,
          faceMismatchMessage: response.message,
          serverMeasurement: serverMeasurement,
        );
        return;
      }
      // User dismissed / declined face check — still show local BMI.
      _openResultScreen(
        showFaceMismatchWarning: true,
        faceMismatchMessage: response.message.isNotEmpty
            ? response.message
            : 'Face verification did not pass. Showing estimated BMI from your scan.',
        serverMeasurement: null,
      );
    } catch (e) {
      debugPrint('Scan verification submit failed: $e');
      if (!mounted) return;
      unawaited(
        ScanTelemetryService.log(
          stage: 'server_upload',
          outcome: 'failed',
          details: {'error': e.toString()},
        ),
      );
      _openResultScreen(
        showFaceMismatchWarning: true,
        faceMismatchMessage:
            'Could not verify scan with server. Showing estimated BMI from your scan.',
        serverMeasurement: null,
      );
    } finally {
      if (mounted) {
        _stopVerificationSteps();
        setState(() => _isSubmittingManualCalibration = false);
      }
    }
  }

  Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  _LocalEstimate? _buildSubmissionEstimate() {
    final estimate = _buildLocalEstimate();
    if (estimate != null) return estimate;

    final useCmPerPixel = _effectiveCmPerPixel();
    if (useCmPerPixel <= 0) return null;

    final heightPx = _resolvedHeightPx() > 0
        ? _resolvedHeightPx()
        : (lockedHeightPx ?? _guideHeightPx);
    final shoulderWidthPx = _resolvedShoulderWidthPx() > 0
        ? _resolvedShoulderWidthPx()
        : (lockedShoulderWidthPx ?? heightPx * _shoulderToHeightRatio);
    final maxBodyAreaPx = _resolvedMaxBodyAreaPx(heightPx, shoulderWidthPx);
    final heightM = _lockedHeightMeters() ??
        BodyMetrics.heightMetersFromScreenPx(
          heightPx: heightPx,
          cmPerPx: useCmPerPixel,
        );
    final widthM = _resolvedWidthM();
    final depthM = _resolvedDepthM(widthM);
    final depthPx = depthM > 0
        ? (depthM * 100) / _lateralCmPerPixel()
        : _resolvedDepthPx(shoulderWidthPx);
    final heightCm = heightM * 100;
    final weightKg = _estimateWeightKg(
      heightM: heightM,
      widthM: widthM,
      depthM: depthM,
    );
    final bmi = BodyMetrics.bmi(weightKg: weightKg, heightM: heightM);
    if (!heightCm.isFinite || !weightKg.isFinite || !bmi.isFinite) {
      return null;
    }

    return _LocalEstimate(
      cmPerPixel: useCmPerPixel,
      heightPx: heightPx,
      shoulderWidthPx: shoulderWidthPx,
      maxBodyAreaPx: maxBodyAreaPx,
      depthPx: depthPx,
      heightCm: heightCm,
      widthM: widthM,
      depthM: depthM,
      weightKg: weightKg,
      bmi: bmi,
    );
  }

  /// Always-on numbers from AR height + typical body proportions.
  _LocalEstimate? _lastResortEstimate() {
    final heightM = _resolvedHeightM();
    if (!heightM.isFinite || heightM <= 0) return null;
    final widthM = _resolvedWidthM();
    final depthM = _resolvedDepthM(widthM);
    final weightKg = _estimateWeightKg(
      heightM: heightM,
      widthM: widthM,
      depthM: depthM,
    );
    final bmi = BodyMetrics.bmi(weightKg: weightKg, heightM: heightM);
    if (!weightKg.isFinite || !bmi.isFinite || weightKg <= 0 || bmi <= 0) {
      return null;
    }
    final useCmPerPixel = _effectiveCmPerPixel() > 0
        ? _effectiveCmPerPixel()
        : 0.12;
    return _LocalEstimate(
      cmPerPixel: useCmPerPixel,
      heightPx: _resolvedHeightPx() > 0 ? _resolvedHeightPx() : _guideHeightPx,
      shoulderWidthPx: _resolvedShoulderWidthPx() > 0
          ? _resolvedShoulderWidthPx()
          : heightM * 100 * _shoulderToHeightRatio / useCmPerPixel,
      maxBodyAreaPx: _resolvedMaxBodyAreaPx(
        _resolvedHeightPx(),
        _resolvedShoulderWidthPx(),
      ),
      depthPx: _resolvedDepthPx(_resolvedShoulderWidthPx()),
      heightCm: heightM * 100,
      widthM: widthM,
      depthM: depthM,
      weightKg: weightKg,
      bmi: bmi,
    );
  }

  /// Last-chance BMI so "Preparing your BMI…" never wedges with an empty video.
  _LocalEstimate? _buildFallbackEstimate() {
    final useCmPerPixel = _effectiveCmPerPixel();
    if (useCmPerPixel <= 0) return null;
    _prepareMetricsFromPartialScan();
    if ((!_minWidth.isFinite || _minWidth <= 0) && _maxWidth > 0) {
      _minWidth = _maxWidth * BODY_DEPTH_RATIO;
    }
    final heightPx = _resolvedHeightPx() > 0
        ? _resolvedHeightPx()
        : (lockedHeightPx ?? _guideHeightPx);
    if (heightPx <= 0) return null;
    final shoulderWidthPx = _resolvedShoulderWidthPx() > 0
        ? _resolvedShoulderWidthPx()
        : (lockedShoulderWidthPx ?? heightPx * _shoulderToHeightRatio);
    final heightM = _resolvedHeightM();
    final widthM = _resolvedWidthM();
    final depthM = _resolvedDepthM(widthM);
    final weightKg = _estimateWeightKg(
      heightM: heightM,
      widthM: widthM,
      depthM: depthM,
    );
    final bmi = BodyMetrics.bmi(weightKg: weightKg, heightM: heightM);
    if (heightM <= 0 || weightKg <= 0 || bmi <= 0) return null;
    if (!heightM.isFinite || !weightKg.isFinite || !bmi.isFinite) return null;
    return _LocalEstimate(
      cmPerPixel: useCmPerPixel,
      heightPx: heightPx,
      shoulderWidthPx: shoulderWidthPx,
      maxBodyAreaPx: _resolvedMaxBodyAreaPx(heightPx, shoulderWidthPx),
      depthPx: _resolvedDepthPx(shoulderWidthPx),
      heightCm: heightM * 100,
      widthM: widthM,
      depthM: depthM,
      weightKg: weightKg,
      bmi: bmi,
    );
  }

  void _startVerificationSteps() {
    _verificationStepTimer?.cancel();
    setState(() {
      _verificationStepIndex = 0;
    });
    _verificationStepTimer = Timer.periodic(
      const Duration(milliseconds: 1400),
      (timer) {
        if (!mounted || !_isSubmittingManualCalibration) {
          timer.cancel();
          return;
        }
        setState(() {
          if (_verificationStepIndex < 2) {
            _verificationStepIndex++;
          }
        });
      },
    );
  }

  void _stopVerificationSteps() {
    _verificationStepTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _isSubmittingManualCalibration = false;
      _verificationStepIndex = 0;
    });
  }

  void _startRotationDurationGuard() {
    _rotationDurationGuard?.cancel();
    _rotationStartedAt = DateTime.now();
    _autoStoppedByDurationCap = false;
    _qualityTooLowAtAutoStop = false;
    _rotationDurationGuard = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (!mounted || currentPhase != ScanPhase.rotation) {
        timer.cancel();
        return;
      }
      final startedAt = _rotationStartedAt;
      if (startedAt == null) return;
      final maxSeconds = _rotationMaxSecondsForDevice();
      final elapsed = DateTime.now().difference(startedAt).inSeconds;
      debugPrint(
        'DurationGuard tick: elapsed=${elapsed}s/$maxSeconds '
        'valid=$_rotationValidFrameCount processed=$_frameCount',
      );
      if (mounted && !_isStoppingAfterCompletion) {
        setState(() {});
      }
      if (elapsed >= _minScanSecondsForDevice() &&
          !_isStoppingAfterCompletion &&
          _shouldCompleteRotationScan()) {
        debugPrint(
          'DurationGuard finished scan (min window) elapsed=${elapsed}s '
          'valid=$_rotationValidFrameCount',
        );
        await _completeRotationRecording(
          stoppedByDurationCap: false,
          reason: 'duration_guard_min_window',
        );
        if (_showInlineResults ||
            _navigatingToResults ||
            currentPhase != ScanPhase.rotation) {
          timer.cancel();
        }
        return;
      }
      if (elapsed >= maxSeconds) {
        debugPrint(
          'DurationGuard finished scan elapsed=${elapsed}s '
          'valid=$_rotationValidFrameCount',
        );
        await _completeRotationRecording(
          stoppedByDurationCap: true,
          reason: 'duration_guard',
        );
        if (_showInlineResults ||
            _navigatingToResults ||
            currentPhase != ScanPhase.rotation) {
          timer.cancel();
        }
      }
    });
  }

  Future<void> _startRotationScan() async {
    if (!_canStartRecording()) {
      if (!mounted) return;
      setState(() {
        _text = currentPhase.index < ScanPhase.readyToRotate.index
            ? 'Stand still in the guide until height is locked'
            : 'Complete the stand-still step before recording';
      });
      return;
    }

    // Keep the already-running image stream. Do NOT restart it on Android —
    // that was freezing pose around frame ~31 on Galaxy M35.
    if (!Platform.isAndroid) {
      await _cameraViewKey.currentState?.ensureImageStreamRunning();
    }
    if (!mounted) return;
    await _enableWakeLock();

    setState(() {
      _isScanRecording = true;
      currentPhase = ScanPhase.rotation;
      _frameCount = 0;
      _rotationValidFrameCount = 0;
      _validStallUnstickCount = 0;
      _lastValidStallUnstickAt = null;
      _lastGoodPosePainter = null;
      _lastGoodPosePainterAt = null;
      _customPainter = null;
      _rotationMissingShoulderFrameCount = 0;
      _rotationMissingAnkleFrameCount = 0;
      _autoStoppedByDurationCap = false;
      _qualityTooLowAtAutoStop = false;
      _autoStoppedByStreamIssue = false;
      _isRecoveringStream = false;
      _isStoppingAfterCompletion = false;
      _streamRecoveryAttempts = 0;
      _lastGuardObservedFrameCount = 0;
      _lastGuardObservedCallbackCount = 0;
      _cameraCallbackCount = 0;
      _pendingInputImage = null;
      _isBusy = false;
      _busySince = null;
      _processingInFlight = false;
      _processingGeneration = 0;
      _maxBodyAreaPx = 0;
      _smoothedHeightPx = 0;
      _smoothedWidthPx = 0;
      _maxWidthPx = 0;
      _minWidthPx = double.infinity;
      _smoothedHeight = 0;
      _smoothedWidth = 0;
      _smoothedDepth = 0;
      _maxWidth = 0;
      _minWidth = double.infinity;
      _isRotationComplete = false;
      _stableFrameCount = 0;
      _rotationHeightSamplesPx.clear();
      _rotationShoulderSamplesPx.clear();
      _clearRotationMetricSamples();
      _clearSilhouetteSamples();
      _text = '[0/${_rotationValidFrameTarget()}] Scanning... Spin 360° slowly';
      _latestVideoPath = null;
      _lastFrameTime = DateTime.now();
    });

    if (Platform.isAndroid) {
      // Keep the already-running detector. Record the full 360° to disk
      // via VideoCapture onAvailable so pose and preview share one stream.
      _processingGeneration++;
      _processingInFlight = false;
      _isBusy = false;
      _busySince = null;
      _pendingInputImage = null;
      _lastValidProgressAt = DateTime.now();
      _lastObservedValidForProgress = 0;
      _lastPaintSetStateValid = 0;
      _lastPaintSetStateAt = null;
      _startRotationDurationGuard();
      _startAndroidScanHealthMonitor();
      _startRotationProgressWatchdog();
      _cameraViewKey.currentState?.markPoseOnlyScan();
      var recordingStarted =
          await _cameraViewKey.currentState?.startVideoRecording(
                keepPoseStream: true,
              ) ??
              false;
      if (!recordingStarted) {
        await Future.delayed(const Duration(milliseconds: 350));
        recordingStarted =
            await _cameraViewKey.currentState?.startVideoRecording(
                  keepPoseStream: true,
                ) ??
                false;
      }
      if (!recordingStarted) {
        await _cameraViewKey.currentState?.prepareForPoseOnlyScan();
      }
      debugPrint(
        'Android 360 scan recordingStarted=$recordingStarted '
        '(pose continues from video frames)',
      );
    } else {
      _startFrameReceptionWatchdog();
      _startRotationDurationGuard();
      _startFrameProgressGuard();
      _startRotationFailsafeTimer();
      _startRotationProgressWatchdog();
      _lastValidProgressAt = DateTime.now();
      _lastObservedValidForProgress = 0;

      var recordingStarted =
          await _cameraViewKey.currentState?.startVideoRecording(
                keepPoseStream: true,
              ) ??
              false;
      if (!recordingStarted) {
        await Future.delayed(const Duration(milliseconds: 350));
        recordingStarted =
            await _cameraViewKey.currentState?.startVideoRecording(
                  keepPoseStream: true,
                ) ??
                false;
      }
      if (!recordingStarted) {
        debugPrint(
          'Scan video did not start during rotation; upload clip at end.',
        );
      }
    }

    unawaited(
      ScanTelemetryService.log(
        stage: 'rotation_start',
        outcome: 'started',
        details: {
          'required_frames': _rotationValidFrameTarget(),
          'max_seconds': _rotationMaxSecondsForDevice(),
          'calibrated_height_cm': _calibratedHeightCm,
        },
      ),
    );
  }

  void _onRecordPressed() {
    if (currentPhase == ScanPhase.rotation && _isScanRecording) {
      unawaited(_handleUserStopRecording());
      return;
    }
    if (_canStartRecording()) {
      unawaited(_startRotationScan());
    }
  }

  Future<void> _handleUserStopRecording() async {
    if (currentPhase == ScanPhase.rotation) {
      _prepareMetricsFromPartialScan();
      await _completeRotationRecording(
        stoppedByDurationCap: false,
        reason: 'user_stop',
      );
      return;
    }
    await _cameraViewKey.currentState?.stopVideoRecording();
  }

  /// Fill width/depth/rotation flags when the user stops early so BMI can run.
  void _prepareMetricsFromPartialScan() {
    if (_frameCount < 6 && _rotationValidFrameCount < 6) return;

    _isRotationComplete = true;
    if (_stableFrameCount < 10) {
      _stableFrameCount = max(11, _rotationValidFrameCount);
    }

    if (_maxWidth <= 0) {
      final width = _robustMetricMean(
        _rotationFrontWidthSamplesM,
        fallback: _robustMetricMean(_rotationWidthSamplesM, fallback: _smoothedWidth),
        minSamples: 3,
      );
      if (width > 0) _maxWidth = width;
    }

    if (!_minWidth.isFinite || _minWidth <= 0) {
      final depth = _robustMetricMean(
        _rotationSideDepthSamplesM,
        fallback: _robustMetricMean(
          _silhouetteSideDepthSamplesM,
          fallback: 0,
          minSamples: 3,
        ),
        minSamples: 3,
      );
      _minWidth = depth > 0 ? depth : (_maxWidth > 0 ? _maxWidth * BODY_DEPTH_RATIO : 0);
    }
  }

  Future<void> _completeRotationRecording({
    required bool stoppedByDurationCap,
    String reason = 'unspecified',
  }) async {
    debugPrint('############################');
    debugPrint('COMPLETE ROTATION CALLED');
    debugPrint(
      'reason=$reason durationCap=$stoppedByDurationCap '
      'valid=$_rotationValidFrameCount processed=$_frameCount '
      'front=${_rotationFrontWidthSamplesM.length} '
      'side=${_rotationSideDepthSamplesM.length} '
      'phase=$currentPhase stopping=$_isStoppingAfterCompletion',
    );
    debugPrint(StackTrace.current.toString());
    debugPrint('############################');

    if (_showInlineResults || _navigatingToResults) return;
    // A previous complete set the overlay then never opened results.
    // Do not return — still show BMI (Android + iOS).
    if (_isStoppingAfterCompletion) {
      debugPrint('COMPLETE already stopping — forcing BMI results');
      _showInlineBmiResults(
        _buildSubmissionEstimate() ??
            _buildFallbackEstimate() ??
            _lastResortEstimate(),
      );
      return;
    }
    if (currentPhase != ScanPhase.rotation) {
      return;
    }

    // Refuse auto-complete when we barely captured anything — keep scanning
    // instead of jumping to BMI with a frozen skeleton / 0 valid frames.
    // Duration cap / user stop must always finish (otherwise the counter
    // climbs past 500/48 with no results screen).
    final isUserStop = reason == 'user_stop';
    final isHardStop = isUserStop ||
        stoppedByDurationCap ||
        reason.contains('duration');
    final minForAuto = Platform.isAndroid
        ? ANDROID_MIN_USABLE_VALID_FRAMES
        : IOS_MIN_USABLE_VALID_FRAMES;
    if (!isHardStop && _rotationValidFrameCount < minForAuto) {
      debugPrint(
        'COMPLETE ROTATION REJECTED: valid=$_rotationValidFrameCount '
        '< min=$minForAuto (reason=$reason) — keep scanning',
      );
      // Kick the camera stream; do not end the turn.
      unawaited(
        _cameraViewKey.currentState?.nudgeImageStreamDuringPoseScan(),
      );
      if (Platform.isAndroid) {
        _unstickAndroidScanPipeline(
          reason: 'reject_early_complete_$reason',
          restartCameraStream: true,
        );
      }
      return;
    }

    _isStoppingAfterCompletion = true;
    _autoStoppedByDurationCap = stoppedByDurationCap;
    _qualityTooLowAtAutoStop = false;
    _prepareMetricsFromPartialScan();
    // Preserve start time only for diagnostics; clip length is fixed/short now.
    _stopRotationDurationGuard();
    _stopFrameProgressGuard();
    _stopAndroidScanHealthMonitor();
    _stopRotationProgressWatchdog();
    _stopRotationFailsafeTimer();
    _frameReceptionWatchdog?.cancel();

    _canProcess = false;
    _completionFailsafe?.cancel();
    _completionFailsafe = Timer(const Duration(seconds: 10), () {
      if (!mounted || _showInlineResults || _navigatingToResults) return;
      debugPrint('Completion failsafe: still finishing after 10s — forcing BMI');
      unawaited(_forceFinishOrRetryFromPreparing());
    });
    try {
      unawaited(_enableWakeLock());

      if (!mounted) return;

      if ((!_minWidth.isFinite || _minWidth <= 0) && _maxWidth > 0) {
        _minWidth = _maxWidth * BODY_DEPTH_RATIO;
      }
      _isRotationComplete = true;
      _LocalEstimate? estimate;
      try {
        estimate =
            _buildSubmissionEstimate() ??
            _buildFallbackEstimate() ??
            _lastResortEstimate();
      } catch (e, st) {
        debugPrint('Estimate failed: $e\n$st');
        estimate = _lastResortEstimate();
      }

      // Both platforms: stop recording with a timeout, then show BMI first.
      // Blocking upload before UI hung Android and can hang iOS TestFlight.
      String? path;
      try {
        path = await Future.any<String?>([
          _cameraViewKey.currentState?.stopVideoRecording(
                suppressCallback: true,
              ) ??
              Future<String?>.value(null),
          Future<String?>.delayed(const Duration(seconds: 6), () => null),
        ]);
      } catch (e) {
        debugPrint('Stop 360 video failed: $e');
      }
      if (path != null && path.isNotEmpty) {
        _latestVideoPath = path;
        debugPrint('360 video saved: $path');
      } else {
        debugPrint('360 video missing after stop');
      }
      _showInlineBmiResults(estimate);
      return;
    } catch (e, st) {
      debugPrint('completeRotationRecording failed: $e\n$st');
      _completionFailsafe?.cancel();
      if (mounted && !_showInlineResults) {
        unawaited(_forceFinishOrRetryFromPreparing());
      }
    } finally {
      if (!_navigatingToResults && !_showInlineResults) {
        _canProcess = true;
      }
    }
  }

  /// After BMI is shown: upload the 360 clip for face↔ID match.
  /// Never blocks ResultScreen. Updates [faceVerify] when done.
  Future<void> _backgroundFaceVerification(
    ValueNotifier<FaceVerificationState> faceVerify,
  ) async {
    void setPhase(FaceVerificationState next) {
      try {
        faceVerify.value = next;
      } catch (_) {
        // ResultScreen may have disposed the notifier if user left early.
      }
    }

    try {
      unawaited(_enableWakeLock());
      setPhase(FaceVerificationState.pending);
      await Future.delayed(const Duration(milliseconds: 400));

      String? path = _latestVideoPath;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        debugPrint('Verify: using full 360 video $path');
      } else {
        final cameraState = _cameraViewKey.currentState;
        if (cameraState != null) {
          debugPrint('Verify: recording fallback 12s clip');
          path = await Future.any<String?>([
            cameraState.recordUploadVideoAfterScan(seconds: 12),
            Future<String?>.delayed(const Duration(seconds: 18), () => null),
          ]);
        } else {
          debugPrint('Verify: CameraView missing — cannot record clip');
        }
      }

      if (path == null || path.isEmpty) {
        setPhase(
          FaceVerificationState.unavailable(
            'Could not record verification video. BMI is an estimate only.',
          ),
        );
        unawaited(
          ScanTelemetryService.log(
            stage: 'face_verify',
            outcome: 'clip_failed',
            details: {'valid_frames': _rotationValidFrameCount},
          ),
        );
        return;
      }

      _latestVideoPath = path;
      setPhase(
        FaceVerificationState(
          phase: FaceVerificationPhase.pending,
          message: 'Uploading scan for face verification…',
          videoPath: path,
        ),
      );

      final estimate = _inlineResult ??
          _buildSubmissionEstimate() ??
          _buildFallbackEstimate() ??
          _lastResortEstimate();
      if (estimate == null) {
        setPhase(
          FaceVerificationState.unavailable(
            'Pose estimate missing for upload. BMI is an estimate only.',
          ),
        );
        return;
      }

      final qualityBreakdown = _rotationQualityBreakdown();
      debugPrint(
        'Verify: uploading BMI '
        'h=${estimate.heightCm.toStringAsFixed(1)} '
        'w=${estimate.weightKg.toStringAsFixed(1)} '
        'bmi=${estimate.bmi.toStringAsFixed(1)}',
      );
      final response = await UserApiService()
          .requestBmiUploadUrl(
            videoFile: File(path),
            heightDetectedCm: estimate.heightCm,
            weightEstimatedKg: estimate.weightKg,
            estimatedBmi: estimate.bmi,
            processingMetadata: _buildUploadMetadata(
              estimate: estimate,
              qualityBreakdown: qualityBreakdown,
            ),
          )
          .timeout(const Duration(seconds: 45));

      debugPrint(
        'Verify: upload result ok=${response.ok} '
        'msg=${response.message}',
      );
      if (response.ok) {
        setPhase(
          FaceVerificationState.verified(
            serverMeasurement: _asStringMap(response.data),
            videoPath: path,
          ),
        );
        unawaited(
          ScanTelemetryService.log(
            stage: 'face_verify',
            outcome: 'verified',
            details: {'valid_frames': _rotationValidFrameCount},
          ),
        );
      } else {
        setPhase(
          FaceVerificationState.mismatch(
            response.message.isNotEmpty
                ? response.message
                : 'Face did not match your ID profile photo.',
            serverMeasurement: _asStringMap(response.data),
            videoPath: path,
          ),
        );
        unawaited(
          ScanTelemetryService.log(
            stage: 'face_verify',
            outcome: 'mismatch',
            details: {'message': response.message},
          ),
        );
      }
    } catch (e) {
      debugPrint('Android background face verify failed: $e');
      setPhase(
        FaceVerificationState.unavailable(
          'Face verification could not complete. BMI is an estimate only.',
        ),
      );
      unawaited(
        ScanTelemetryService.log(
          stage: 'face_verify',
          outcome: 'error',
          details: {'error': e.toString()},
        ),
      );
    } finally {
      unawaited(_disableWakeLock());
    }
  }

  Map<String, dynamic> _buildUploadMetadata({
    required _LocalEstimate estimate,
    required _QualityBreakdown qualityBreakdown,
  }) {
    return <String, dynamic>{
      'cm_per_pixel': estimate.cmPerPixel,
      'median_height_px': estimate.heightPx,
      'median_shoulder_width_px': estimate.shoulderWidthPx,
      'max_body_area_px': estimate.maxBodyAreaPx,
      'depth_px': estimate.depthPx,
      'max_width_px': _maxWidthPx,
      'min_width_px': _minWidthPx.isFinite ? _minWidthPx : null,
      'frame_count': _frameCount,
      'valid_rotation_frame_count': _rotationValidFrameCount,
      'missing_shoulder_frame_count': _rotationMissingShoulderFrameCount,
      'missing_ankle_frame_count': _rotationMissingAnkleFrameCount,
      'quality_coverage_score': qualityBreakdown.coverageScore,
      'quality_stability_score': qualityBreakdown.stabilityScore,
      'quality_completeness_score': qualityBreakdown.completenessScore,
      'quality_final_score': qualityBreakdown.finalScore,
      'front_width_sample_count': _rotationFrontWidthSamplesM.length,
      'side_depth_sample_count': _rotationSideDepthSamplesM.length,
      'phase': currentPhase.name,
      'height_m': estimate.heightCm / 100,
      'width_m': estimate.widthM,
      'depth_m': estimate.depthM,
    };
  }

  Future<void> _showVerificationFailedDialog({
    required String title,
    required String message,
    bool resetToReady = true,
  }) async {
    if (!mounted) return;
    setState(() {
      _isStoppingAfterCompletion = false;
      _isScanRecording = false;
      if (resetToReady) {
        currentPhase = ScanPhase.readyToRotate;
        _text = 'Ready! Tap • Record to start 360° scan.';
      }
    });

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Text(message, style: const TextStyle(height: 1.4)),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _exitCapture();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
              },
              child: const Text('Retry'),
            ),
          ],
        );
      },
    );
  }

  void _stopRotationDurationGuard() {
    _rotationDurationGuard?.cancel();
    _rotationStartedAt = null;
  }

  void _startRotationFailsafeTimer() {
    _rotationFailsafeTimer?.cancel();
    _rotationFailsafeTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || currentPhase != ScanPhase.rotation) return;
      if (!_isRotationComplete) {
        setState(() {
          _isRotationComplete = true;
        });
      }
    });
  }

  void _stopRotationFailsafeTimer() {
    _rotationFailsafeTimer?.cancel();
  }

  void _startFrameProgressGuard() {
    _frameProgressGuard?.cancel();
    _streamRecoveryAttempts = 0;
    _lastGuardObservedFrameCount = _frameCount;
    _lastGuardObservedCallbackCount = _cameraCallbackCount;
    _autoStoppedByStreamIssue = false;
    _frameProgressGuard = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (!mounted || currentPhase != ScanPhase.rotation) {
        timer.cancel();
        return;
      }

      final startedAt = _rotationStartedAt;
      if (startedAt == null) return;
      final elapsed = DateTime.now().difference(startedAt).inSeconds;

      // Give camera + ML Kit time to stabilize after scan starts.
      if (elapsed < _streamStartupGraceSeconds) {
        return;
      }

      final callbacksAdvanced =
          _cameraCallbackCount > _lastGuardObservedCallbackCount;
      final framesAdvanced = _frameCount > _lastGuardObservedFrameCount;

      if (callbacksAdvanced || framesAdvanced) {
        _lastGuardObservedCallbackCount = _cameraCallbackCount;
        _lastGuardObservedFrameCount = _frameCount;
        _streamRecoveryAttempts = 0;
        // Camera is alive — clear any earlier false-positive stream flag.
        if (_autoStoppedByStreamIssue && _frameCount > 0) {
          _autoStoppedByStreamIssue = false;
        }
        if (_isRecoveringStream && mounted) {
          setState(() {
            _isRecoveringStream = false;
          });
        }
        return;
      }

      // No camera callbacks and no processed frames → try recovery.
      if (Platform.isAndroid &&
          currentPhase == ScanPhase.rotation &&
          _isScanRecording) {
        return;
      }
      _streamRecoveryAttempts++;
      if (!_isRecoveringStream && mounted) {
        setState(() {
          _isRecoveringStream = true;
        });
      }

      final forceReinit = _streamRecoveryAttempts >= 3;
      await _recoverCameraPipeline(forceReinit: forceReinit);

      if (_streamRecoveryAttempts >= _maxStreamRecoveryAttempts) {
        // Only hard-fail if we still have no usable pose data.
        if (_frameCount == 0 && _rotationValidFrameCount == 0) {
          timer.cancel();
          _autoStoppedByStreamIssue = true;
          await ScanTelemetryService.log(
            stage: 'camera_stream',
            outcome: 'failed_no_frames',
            details: {
              'callbacks': _cameraCallbackCount,
              'processed': _frameCount,
              'elapsed': elapsed,
            },
          );
        }
        if (_isRecoveringStream && mounted) {
          setState(() {
            _isRecoveringStream = false;
          });
        }
      }
    });
  }

  Future<void> _recoverCameraPipeline({required bool forceReinit}) async {
    // Never touch the camera mid-scan on Android — recovery was killing the
    // pose stream around frame 30 on Galaxy M35 (SM-M356B).
    if (Platform.isAndroid &&
        currentPhase == ScanPhase.rotation &&
        _isScanRecording) {
      return;
    }
    if (_cameraViewKey.currentState?.isAndroidScanRecording ?? false) {
      return;
    }
    await _enableWakeLock();
    try {
      if (forceReinit) {
        await _cameraViewKey.currentState?.reinitializeCamera();
      } else {
        await _cameraViewKey.currentState?.ensurePreviewActiveDuringRecording();
        await _cameraViewKey.currentState?.restartImageStream();
        await _cameraViewKey.currentState?.ensureImageStreamRunning();
      }
    } catch (e) {
      debugPrint('Camera recovery failed: $e');
    }
  }

  void _stopFrameProgressGuard() {
    _frameProgressGuard?.cancel();
    _isRecoveringStream = false;
  }

  void _resetPoseDetector({required String reason}) {
    if (_isPoseDetectorResetting) return;
    final now = DateTime.now();
    final resetCooldown = currentPhase == ScanPhase.rotation
        ? const Duration(milliseconds: 1500)
        : const Duration(seconds: 3);
    if (_lastPoseDetectorResetAt != null &&
        now.difference(_lastPoseDetectorResetAt!) < resetCooldown) {
      return;
    }

    _isPoseDetectorResetting = true;
    _lastPoseDetectorResetAt = now;

    debugPrint('PoseDetector reset: $reason');

    // Drop any in-flight ML Kit work — concurrent processImage() calls wedge
    // Galaxy M35 around frame ~31.
    _processingGeneration++;
    _processingInFlight = false;

    try {
      _poseDetector.close();
    } catch (_) {}

    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: _poseDetectionModeForCurrentPhase(),
      ),
    );

    // Allow the pipeline to resume. If a previous processImage() call was
    // wedged, the new detector instance should unblock further frames.
    _isBusy = false;
    _busySince = null;

    _isPoseDetectorResetting = false;
  }

  void _unstickAndroidScanPipeline({
    required String reason,
    bool restartCameraStream = false,
  }) {
    debugPrint('Android scan unstick: $reason '
        '(processed=$_frameCount valid=$_rotationValidFrameCount '
        'callbacks=$_cameraCallbackCount restartStream=$restartCameraStream)');
    _resetPoseDetector(reason: reason);
    // Only restart CameraX when callbacks fully stopped — mid-scan restarts
    // during ML stalls made Galaxy M35 freeze worse.
    if (restartCameraStream) {
      unawaited(_cameraViewKey.currentState?.nudgeImageStreamDuringPoseScan());
    }
    if (_pendingInputImage != null) {
      unawaited(_drainPendingImages());
    }
  }

  void _startAndroidScanHealthMonitor() {
    _androidScanHealthMonitor?.cancel();
    _lastHealthObservedFrameCount = _frameCount;
    _lastHealthObservedCallbackCount = _cameraCallbackCount;
    _lastHealthObservedValidCount = _rotationValidFrameCount;
    _androidScanHealthMonitor = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) {
      if (!mounted ||
          currentPhase != ScanPhase.rotation ||
          _isStoppingAfterCompletion) {
        timer.cancel();
        return;
      }

      final callbacksSinceLast =
          _cameraCallbackCount - _lastHealthObservedCallbackCount;
      final framesSinceLast = _frameCount - _lastHealthObservedFrameCount;
      final validSinceLast =
          _rotationValidFrameCount - _lastHealthObservedValidCount;

      // Valid-frame stall OR never-started (stuck at 0/target with frozen overlay).
      if (validSinceLast == 0 &&
          _rotationStartedAt != null &&
          DateTime.now().difference(_lastValidProgressAt ?? _rotationStartedAt!) >=
              const Duration(seconds: 3)) {
        final sinceUnstick = _lastValidStallUnstickAt == null
            ? const Duration(days: 1)
            : DateTime.now().difference(_lastValidStallUnstickAt!);
        if (sinceUnstick < const Duration(seconds: 4)) {
          return;
        }
        _validStallUnstickCount++;
        _lastValidStallUnstickAt = DateTime.now();
        final elapsed = DateTime.now().difference(_rotationStartedAt!).inSeconds;
        final frontN = _rotationFrontWidthSamplesM.length;
        final sideN = _rotationSideDepthSamplesM.length;
        // Never force-complete from health monitor — only revive the pipeline.
        // Completing here after a camera freeze caused "Preparing BMI" with
        // almost no frames (other-dev diagnosis / video 14.22.07).
        debugPrint(
          'Scan health: valid frames stuck at $_rotationValidFrameCount '
          'F$frontN/S$sideN for >=3s (unstick #$_validStallUnstickCount, '
          'elapsed=${elapsed}s processed=$_frameCount) — unstick, keep scanning.',
        );
        _unstickAndroidScanPipeline(
          reason: _rotationValidFrameCount == 0
              ? 'scan_health_zero_valid'
              : 'scan_health_valid_stall',
          restartCameraStream: callbacksSinceLast == 0 || _frameCount == 0,
        );
        _lastHealthObservedFrameCount = _frameCount;
        _lastHealthObservedCallbackCount = _cameraCallbackCount;
        _lastHealthObservedValidCount = _rotationValidFrameCount;
        return;
      }

      if (framesSinceLast > 0 || validSinceLast > 0) {
        _lastHealthObservedFrameCount = _frameCount;
        _lastHealthObservedCallbackCount = _cameraCallbackCount;
        _lastHealthObservedValidCount = _rotationValidFrameCount;
        return;
      }

      if (callbacksSinceLast >= 4) {
        // Camera is alive but ML Kit pipeline stalled — unstick without touching camera.
        debugPrint(
          'Scan health: $callbacksSinceLast camera ticks, 0 processed frames — '
          'unblocking ML pipeline (processed=$_frameCount valid=$_rotationValidFrameCount).',
        );
        _resetPoseDetector(reason: 'scan_health_ml_stall');
        _lastHealthObservedCallbackCount = _cameraCallbackCount;
        if (_pendingInputImage != null) {
          unawaited(_drainPendingImages());
        }
        return;
      }

      if (callbacksSinceLast == 0) {
        _unstickAndroidScanPipeline(
          reason: 'scan_health_no_callbacks',
          restartCameraStream: true,
        );
        _lastHealthObservedCallbackCount = _cameraCallbackCount;
        _lastHealthObservedFrameCount = _frameCount;
        _lastHealthObservedValidCount = _rotationValidFrameCount;
      }
    });
  }

  void _stopAndroidScanHealthMonitor() {
    _androidScanHealthMonitor?.cancel();
  }

  void _startRotationProgressWatchdog() {
    _rotationProgressWatchdog?.cancel();
    _lastValidProgressAt = DateTime.now();
    _lastObservedValidForProgress = _rotationValidFrameCount;
    _rotationProgressWatchdog = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (!mounted ||
          currentPhase != ScanPhase.rotation ||
          _isStoppingAfterCompletion) {
        timer.cancel();
        return;
      }

      if (_rotationValidFrameCount > _lastObservedValidForProgress) {
        _lastObservedValidForProgress = _rotationValidFrameCount;
        _lastValidProgressAt = DateTime.now();
        return;
      }

      final stalledFor = _lastValidProgressAt == null
          ? Duration.zero
          : DateTime.now().difference(_lastValidProgressAt!);
      final startedAt = _rotationStartedAt;
      final elapsed = startedAt == null
          ? 0
          : DateTime.now().difference(startedAt).inSeconds;

      final minUsable = Platform.isAndroid
          ? ANDROID_MIN_USABLE_VALID_FRAMES
          : IOS_MIN_USABLE_VALID_FRAMES;
      final frontN = _rotationFrontWidthSamplesM.length;
      final sideN = _rotationSideDepthSamplesM.length;
      final hasLockedFront =
          lockedShoulderWidthPx != null && lockedShoulderWidthPx! > 0;
      final hasWidth =
          _rotationFrontWidthSamplesM.isNotEmpty ||
          _maxWidth > 0 ||
          _rotationWidthSamplesM.isNotEmpty;
      final hasSide = sideN >= 2 ||
          (_minWidth.isFinite && _minWidth > 0);
      // Do NOT treat standstill lockedFront as enough width — that ended turns
      // at F0/S3 · 9/24 before a full circle (video 18.02.20).
      // Soft-complete only after a long turn with real front+side samples.
      if (stalledFor >= const Duration(seconds: 8) &&
          elapsed >= 22 &&
          _rotationValidFrameCount >= minUsable &&
          frontN >= 3 &&
          sideN >= 2 &&
          (hasWidth || hasSide)) {
        debugPrint(
          'Progress watchdog: valid stuck at $_rotationValidFrameCount '
          'front=$frontN side=$sideN '
          'for ${stalledFor.inSeconds}s — completing partial scan.',
        );
        timer.cancel();
        _prepareMetricsFromPartialScan();
        await _completeRotationRecording(
          stoppedByDurationCap: true,
          reason: 'progress_watchdog',
        );
        return;
      }

      // Late path: near the duration cap — finish with best available.
      // Never complete at 0 valid frames.
      final lateElapsed = Platform.isAndroid ? 40 : 18;
      if (stalledFor >= const Duration(seconds: 8) &&
          elapsed >= lateElapsed &&
          _rotationValidFrameCount >= minUsable &&
          (frontN >= 2 || hasLockedFront) &&
          (hasWidth || hasSide || hasLockedFront)) {
        debugPrint(
          'Progress watchdog: late soft-complete valid=$_rotationValidFrameCount '
          'front=$frontN side=$sideN elapsed=${elapsed}s',
        );
        timer.cancel();
        _prepareMetricsFromPartialScan();
        await _completeRotationRecording(
          stoppedByDurationCap: true,
          reason: 'progress_watchdog_late',
        );
      }
    });
  }

  void _stopRotationProgressWatchdog() {
    _rotationProgressWatchdog?.cancel();
  }

  void _startUploadClipProgressTicker() {
    _uploadClipProgressTicker?.cancel();
    _uploadClipProgressTicker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        if (!mounted || !_isStoppingAfterCompletion) {
          _uploadClipProgressTicker?.cancel();
          return;
        }
        setState(() {});
      },
    );
  }

  void _stopUploadClipProgressTicker() {
    _uploadClipProgressTicker?.cancel();
    _uploadClipProgressTicker = null;
  }

  void _maybeUpdateScanUi({bool forcePaint = false}) {
    if (!mounted) return;
    if (currentPhase != ScanPhase.rotation) {
      setState(() {});
      return;
    }
    final now = DateTime.now();
    final validDelta = _rotationValidFrameCount - _lastPaintSetStateValid;
    // Paint updates must stay frequent during the turn so the skeleton
    // follows the person — do not wait for valid-frame progress alone.
    final paintDue = forcePaint ||
        _lastPaintSetStateAt == null ||
        now.difference(_lastPaintSetStateAt!) >=
            const Duration(milliseconds: 80);
    if (validDelta >= 1 || paintDue) {
      _lastPaintSetStateValid = _rotationValidFrameCount;
      _lastPaintSetStateAt = now;
      setState(() {});
    }
  }

  Future<void> _showStreamIssueDialog() async {
    if (!mounted) return;
    final shouldRetake = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Camera stream interrupted'),
        content: const SingleChildScrollView(
          child: Text(
            'We could not capture enough live body frames during your 360° scan.\n\n'
            'This usually happens when:\n'
            '• The phone screen sleeps or locks mid-scan\n'
            '• Another app interrupts the camera\n'
            '• The camera stream stalls on Android\n\n'
            'What to do next:\n'
            '• Keep the phone unlocked (this app keeps the screen awake)\n'
            '• Do not switch apps or answer calls during the scan\n'
            '• Stand in good lighting with full body visible\n'
            '• Rotate slowly until the scan completes\n\n'
            'Tap Retake now to start a fresh scan.',
            style: TextStyle(height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retake now'),
          ),
        ],
      ),
    );
    if (!mounted || shouldRetake != true) return;
    _retakeCapture();
  }

  Future<bool?> _showFaceMismatchDialog(String message) {
    final scheme = Theme.of(context).colorScheme;
    final backendMessage = message.trim();
    final normalizedMessage = backendMessage.isEmpty
        ? 'We could not verify that the profile face matches the captured video.'
        : '${backendMessage[0].toUpperCase()}${backendMessage.substring(1)}';
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Face verification mismatch'),
          content: Text(
            '$normalizedMessage\n\n'
            'Identity verification compares this scan video with your profile photo.\n\n'
            'For a successful match:\n'
            '• Face the camera clearly at the start or end of your turn\n'
            '• Keep your face uncovered with good lighting\n'
            '• Use the same person who uploaded the government ID\n\n'
            'You can retake the scan, cancel, or continue with indicative BMI only.',
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop(null);
                await _exitCapture();
              },
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                _retakeCapture();
              },
              child: Text('Retake', style: TextStyle(color: scheme.primary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }

  void _retakeCapture() {
    _cameraViewKey.currentState?.endPoseOnlyScan();
    unawaited(_cameraViewKey.currentState?.cancelActiveRecording() ?? Future.value());
    unawaited(_enableWakeLock());
    setState(() {
      _latestVideoPath = null;
      _frameCount = 0;
      _cameraCallbackCount = 0;
      _lastGuardObservedCallbackCount = 0;
      _staticFrameCount = 0;
      _rotationValidFrameCount = 0;
      _rotationMissingShoulderFrameCount = 0;
      _rotationMissingAnkleFrameCount = 0;
      _autoStoppedByDurationCap = false;
      _qualityTooLowAtAutoStop = false;
      _autoStoppedByStreamIssue = false;
      _isRecoveringStream = false;
      _isStoppingAfterCompletion = false;
      _uploadClipStartedAt = null;
      _streamRecoveryAttempts = 0;
      _lastGuardObservedFrameCount = 0;
      _maxBodyAreaPx = 0;
      _smoothedHeightPx = 0;
      _smoothedWidthPx = 0;
      _maxWidthPx = 0;
      _minWidthPx = double.infinity;
      _smoothedHeight = 0;
      _smoothedWidth = 0;
      _smoothedDepth = 0;
      _maxWidth = 0;
      _minWidth = double.infinity;
      _isRotationComplete = false;
      _stableFrameCount = 0;
      lockedHeightPx = null;
      lockedShoulderWidthPx = null;
      heightSamplesPx.clear();
      shoulderWidthSamplesPx.clear();
      _rotationHeightSamplesPx.clear();
      _rotationShoulderSamplesPx.clear();
      _clearRotationMetricSamples();
      _clearSilhouetteSamples();
      currentPhase = ScanPhase.calibration;
      _text = "Stand inside the guide box";
    });
    _stopFrameProgressGuard();
    _stopRotationDurationGuard();
    _stopRotationFailsafeTimer();
  }

  void _clearRotationMetricSamples() {
    _rotationEstimatedHeightSamplesM.clear();
    _rotationWidthSamplesM.clear();
    _rotationFrontWidthSamplesM.clear();
    _rotationSideDepthSamplesM.clear();
    _rotationFrontHipWidthSamplesM.clear();
  }

  void _clearSilhouetteSamples() {
    _silhouetteFrontWidthSamplesM.clear();
    _silhouetteSideDepthSamplesM.clear();
    _silhouetteWaistSamplesM.clear();
    _lastSegmentedFrameCount = -999;
  }

  /// Show BMI immediately (overlay). Used on Android and iOS so upload never
  /// blocks the results UI (that hung "Preparing / Saving" on both).
  void _showInlineBmiResults(_LocalEstimate? estimate) {
    if (_showInlineResults || !mounted) return;
    _LocalEstimate? resolved = estimate;
    try {
      _prepareMetricsFromPartialScan();
      if ((!_minWidth.isFinite || _minWidth <= 0) && _maxWidth > 0) {
        _minWidth = _maxWidth * BODY_DEPTH_RATIO;
      }
      _isRotationComplete = true;
      resolved ??=
          _buildSubmissionEstimate() ??
          _buildFallbackEstimate() ??
          _lastResortEstimate();
    } catch (e, st) {
      debugPrint('showInlineBmiResults estimate failed: $e\n$st');
    }
    _showInlineResults = true;
    _navigatingToResults = true;
    _inlineResult = resolved;
    _inlineFaceVerify ??= ValueNotifier<FaceVerificationState>(
      FaceVerificationState.pending,
    );
    _completionFailsafe?.cancel();
    _isStoppingAfterCompletion = false;
    _canProcess = false;
    _isScanRecording = false;
    currentPhase = ScanPhase.completed;
    debugPrint(
      'showInlineBmiResults height=${resolved?.heightCm?.toStringAsFixed(1)} '
      'widthM=${resolved?.widthM?.toStringAsFixed(3)} '
      'depthM=${resolved?.depthM?.toStringAsFixed(3)} '
      'weight=${resolved?.weightKg?.toStringAsFixed(1)} '
      'bmi=${resolved?.bmi?.toStringAsFixed(1)} valid=$_rotationValidFrameCount '
      'front=${_rotationFrontWidthSamplesM.length} '
      'hip=${_rotationFrontHipWidthSamplesM.length} '
      'side=${_rotationSideDepthSamplesM.length} '
      'arHeight=${_calibratedHeightCm?.toStringAsFixed(1)} '
      'platform=${Platform.operatingSystem}',
    );
    setState(() {});
    if (!_androidVerifyStarted) {
      _androidVerifyStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final notifier = _inlineFaceVerify;
        if (notifier == null) return;
        unawaited(_backgroundFaceVerification(notifier));
      });
    }
  }

  Widget _buildAndroidResultScreen() {
    final estimate = _inlineResult;
    final heightCm = estimate?.heightCm;
    final weightKg = estimate?.weightKg;
    final bmi = estimate?.bmi;
    final resolvedHeightPx = _resolvedHeightPx();
    final resolvedShoulderWidthPx = _resolvedShoulderWidthPx();
    return ResultScreen(
      key: ValueKey('android_inline_bmi_${_latestVideoPath ?? ''}'),
      videoPath: _latestVideoPath ?? '',
      medianHeightPx: resolvedHeightPx,
      medianShoulderWidthPx: resolvedShoulderWidthPx,
      maxBodyAreaPx: _resolvedMaxBodyAreaPx(
        resolvedHeightPx,
        resolvedShoulderWidthPx,
      ),
      cmPerPixel: (cmPerPixel != null && cmPerPixel! > 0)
          ? cmPerPixel!
          : (_guideHeightPx > 0 ? guideRealHeightCm / _guideHeightPx : 0.12),
      showFaceMismatchWarning: false,
      faceMismatchMessage: null,
      onRetakeRequested: () {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      serverMeasurement: null,
      estimatedHeightCm: () {
        final ar = _calibratedHeightCm;
        if (ar != null && ar.isFinite && ar > 100) {
          return (ar * HEIGHT_RESULT_CALIBRATION);
        }
        if (heightCm != null && heightCm.isFinite && heightCm > 0) {
          return heightCm;
        }
        return null;
      }(),
      estimatedWeightKg:
          (weightKg != null && weightKg.isFinite && weightKg > 0)
          ? weightKg
          : null,
      estimatedBmi: (bmi != null && bmi.isFinite && bmi > 0) ? bmi : null,
      faceVerification: _inlineFaceVerify,
    );
  }

  bool _openResultScreen({
    required bool showFaceMismatchWarning,
    required String? faceMismatchMessage,
    Map<String, dynamic>? serverMeasurement,
    ValueNotifier<FaceVerificationState>? faceVerification,
  }) {
    if (!mounted) return false;
    final estimate = _buildLocalEstimate() ??
        _buildSubmissionEstimate() ??
        _buildFallbackEstimate();
    // Allow empty video when CameraX clip failed — still show BMI.
    final videoPath = _latestVideoPath ?? '';
    if (videoPath.isEmpty && estimate == null) {
      debugPrint(
        'openResultScreen aborted: no estimate '
        '(valid=$_rotationValidFrameCount processed=$_frameCount '
        'cmPerPx=${_effectiveCmPerPixel()})',
      );
      return false;
    }
    unawaited(_disableWakeLock());
    final resolvedHeightPx = _resolvedHeightPx();
    final resolvedShoulderWidthPx = _resolvedShoulderWidthPx();
    final resolvedMaxBodyAreaPx = _resolvedMaxBodyAreaPx(
      resolvedHeightPx,
      resolvedShoulderWidthPx,
    );
    // Guard NaN/inf so ResultScreen never crashes on bad estimate.
    final heightCm = estimate?.heightCm;
    final weightKg = estimate?.weightKg;
    final bmi = estimate?.bmi;
    final arHeight = _calibratedHeightCm;
    final safeHeight = (arHeight != null && arHeight.isFinite && arHeight > 100)
        ? (arHeight * HEIGHT_RESULT_CALIBRATION)
        : ((heightCm != null && heightCm.isFinite && heightCm > 0)
              ? heightCm
              : null);
    final safeWeight =
        (weightKg != null && weightKg.isFinite && weightKg > 0) ? weightKg : null;
    final safeBmi = (bmi != null && bmi.isFinite && bmi > 0) ? bmi : null;
    debugPrint(
      'openResultScreen push height=${safeHeight?.toStringAsFixed(1)} '
      'weight=${safeWeight?.toStringAsFixed(1)} bmi=${safeBmi?.toStringAsFixed(1)}',
    );
    try {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            videoPath: videoPath,
            medianHeightPx: resolvedHeightPx,
            medianShoulderWidthPx: resolvedShoulderWidthPx,
            maxBodyAreaPx: resolvedMaxBodyAreaPx,
            cmPerPixel: cmPerPixel ?? guideRealHeightCm / _guideHeightPx,
            showFaceMismatchWarning: showFaceMismatchWarning,
            faceMismatchMessage: faceMismatchMessage,
            onRetakeRequested: _retakeCapture,
            serverMeasurement: serverMeasurement,
            estimatedHeightCm: safeHeight,
            estimatedWeightKg: safeWeight,
            estimatedBmi: safeBmi,
            faceVerification: faceVerification,
          ),
        ),
      );
      _completionFailsafe?.cancel();
      _isStoppingAfterCompletion = false;
      return true;
    } catch (e, st) {
      debugPrint('openResultScreen push failed: $e\n$st');
      return false;
    }
  }

  _LocalEstimate? _buildLocalEstimate() {
    final useCmPerPixel = _effectiveCmPerPixel();
    final heightPx = _resolvedHeightPx();
    final shoulderWidthPx = _resolvedShoulderWidthPx();
    final maxBodyAreaPx = _resolvedMaxBodyAreaPx(heightPx, shoulderWidthPx);
    final hasMinFrames =
        _rotationValidFrameCount >=
            (Platform.isAndroid ? ANDROID_MIN_USABLE_VALID_FRAMES : 8) ||
        (_frameCount >= 12 && _rotationValidFrameCount >= 5);
    final hasWidthSignal =
        _maxWidth > 0 ||
        _rotationWidthSamplesM.isNotEmpty ||
        _rotationFrontWidthSamplesM.isNotEmpty ||
        lockedShoulderWidthPx != null;
    // Prefer real side depth for BMI; allow duration-cap fallback with invent.
    final hasSideSignal = _rotationSideDepthSamplesM.isNotEmpty ||
        (_minWidth.isFinite && _minWidth > 0) ||
        _isRotationComplete;
    if (!hasMinFrames ||
        !hasWidthSignal ||
        !hasSideSignal ||
        useCmPerPixel <= 0 ||
        heightPx <= 0 ||
        shoulderWidthPx <= 0) {
      return null;
    }

    // Allow completion after duration/user stop even if front/side lock was weak.
    if (!_isRotationComplete && hasWidthSignal && hasMinFrames) {
      _isRotationComplete = true;
    }

    final areaPx = maxBodyAreaPx > 0
        ? maxBodyAreaPx
        : (heightPx * shoulderWidthPx);
    if (areaPx <= 0) return null;

    final realHeightM = _resolvedHeightM();
    final realWidthM = _resolvedWidthM();
    final realDepthM = _resolvedDepthM(realWidthM);
    final weightKg = _estimateWeightKg(
      heightM: realHeightM,
      widthM: realWidthM,
      depthM: realDepthM,
    );
    final bmi = BodyMetrics.bmi(weightKg: weightKg, heightM: realHeightM);
    final heightCm = realHeightM * 100;
    final depthPx = _resolvedDepthPx(shoulderWidthPx);
    if (!heightCm.isFinite || !weightKg.isFinite || !bmi.isFinite) return null;

    return _LocalEstimate(
      cmPerPixel: useCmPerPixel,
      heightPx: heightPx,
      shoulderWidthPx: shoulderWidthPx,
      maxBodyAreaPx: areaPx,
      depthPx: depthPx,
      heightCm: heightCm,
      widthM: realWidthM,
      depthM: realDepthM,
      weightKg: weightKg,
      bmi: bmi,
    );
  }

  double _rotationQualityRatio() {
    if (_frameCount <= 0) return 0.0;
    return (_rotationValidFrameCount / _frameCount).clamp(0.0, 1.0);
  }

  double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  double _relativeDispersion(List<double> values) {
    if (values.length < _minRotationStableSamples) return 1.0;
    final med = _median(values);
    if (med <= 0) return 1.0;
    final deviations = values.map((v) => (v - med).abs()).toList();
    final mad = _median(deviations);
    return (mad / med).clamp(0.0, 1.0);
  }

  double _metricRelativeDispersion(List<double> values) {
    if (values.length < _minMetricStableSamples) return 1.0;
    final med = _median(values);
    if (med <= 0) return 1.0;
    final deviations = values.map((v) => (v - med).abs()).toList();
    final mad = _median(deviations);
    return (mad / med).clamp(0.0, 1.0);
  }

  double _robustMetricMean(
    List<double> values, {
    double fallback = 0,
    int minSamples = _minMetricStableSamples,
  }) {
    if (values.length < minSamples) return fallback;
    final trimmed = trimmedMean(values);
    if (!trimmed.isFinite || trimmed <= 0) return fallback;
    return trimmed;
  }

  /// Lower percentile resists misclassified oblique frames that widen "side" depth.
  double _lowerPercentileMetric(
    List<double> values, {
    required double fallback,
    int minSamples = 4,
    double percentile = 0.2,
  }) {
    if (values.length < minSamples) return fallback;
    final sorted = List<double>.from(values)..sort();
    final idx =
        (sorted.length * percentile).floor().clamp(0, sorted.length - 1);
    final value = sorted[idx];
    if (!value.isFinite || value <= 0) return fallback;
    return value;
  }

  double _upperPercentileMetric(
    List<double> values, {
    required double fallback,
    int minSamples = 3,
    double percentile = 0.75,
  }) {
    if (values.length < minSamples) return fallback;
    final sorted = List<double>.from(values)..sort();
    final idx =
        (sorted.length * percentile).floor().clamp(0, sorted.length - 1);
    final value = sorted[idx];
    if (!value.isFinite || value <= 0) return fallback;
    return value;
  }

  double _resolvedHeightM() {
    final arHeightCm = _calibratedHeightCm;
    if (arHeightCm != null && arHeightCm.isFinite && arHeightCm > 100) {
      return ((arHeightCm * HEIGHT_RESULT_CALIBRATION) / 100.0).clamp(
        BodyMetrics.minHeightM,
        BodyMetrics.maxHeightM,
      );
    }

    final locked = _lockedHeightMeters();
    if (locked != null && locked > 0) return locked;

    if (_rotationHeightSamplesPx.isNotEmpty) {
      return BodyMetrics.heightMetersFromScreenPx(
        heightPx: trimmedMean(_rotationHeightSamplesPx),
        cmPerPx: _effectiveCmPerPixel(),
      );
    }

    if (_maxWidth > 0) {
      return _heightFromBodyWidth(_maxWidth);
    }

    return _robustMetricMean(
      _rotationEstimatedHeightSamplesM,
      fallback: _smoothedHeight,
    ).clamp(BodyMetrics.minHeightM, BodyMetrics.maxHeightM);
  }

  double _resolvedWidthM() {
    double? lockedWidthM;
    if (lockedShoulderWidthPx != null && lockedShoulderWidthPx! > 0) {
      lockedWidthM = (lockedShoulderWidthPx! * _lateralCmPerPixel()) / 100;
    }

    final silhouetteFrontWidth = _robustMetricMean(
      _silhouetteFrontWidthSamplesM,
      fallback: 0,
      minSamples: _minSilhouetteSamples,
    );
    // True-front frames only — mean of 3/4-turn "front" was too narrow.
    final frontShoulder = _upperPercentileMetric(
      _rotationFrontWidthSamplesM,
      fallback: _robustMetricMean(
        _rotationFrontWidthSamplesM,
        fallback: 0,
        minSamples: 1,
      ),
      minSamples: 2,
      percentile: 0.8,
    );
    final hipWidth = _upperPercentileMetric(
      _rotationFrontHipWidthSamplesM,
      fallback: 0,
      minSamples: 2,
      percentile: 0.75,
    );
    final rawShoulder = silhouetteFrontWidth > 0
        ? silhouetteFrontWidth
        : frontShoulder > 0
        ? frontShoulder
        : _robustMetricMean(_rotationWidthSamplesM, fallback: _maxWidth);
    // Scale shoulders only. Hip span is already an outer-body signal.
    var rotationWidth = silhouetteFrontWidth > 0
        ? rawShoulder
        : rawShoulder * SHOULDER_TO_TORSO_WIDTH;
    if (hipWidth > rotationWidth) {
      rotationWidth = (rotationWidth * 0.5) + (hipWidth * 0.5);
    }

    var width = lockedWidthM != null && lockedWidthM > 0
        ? rotationWidth > 0
              ? max(
                  lockedWidthM * SHOULDER_TO_TORSO_WIDTH,
                  (lockedWidthM * SHOULDER_TO_TORSO_WIDTH * 0.35) +
                      (rotationWidth * 0.65),
                )
              : lockedWidthM * SHOULDER_TO_TORSO_WIDTH
        : rotationWidth;

    final heightM = _resolvedHeightM();
    if (heightM > 0 && width > 0) {
      final typicalChest = (heightM * 0.22).clamp(
        BodyMetrics.minWidthM,
        BodyMetrics.maxWidthM,
      );
      if (width < typicalChest * 0.86) {
        width = (width * 0.68) + (typicalChest * 0.32);
      }
    }
    return width.clamp(BodyMetrics.minWidthM, BodyMetrics.maxWidthM);
  }

  double _resolvedDepthM(double widthM) {
    final silhouetteSideDepth = _lowerPercentileMetric(
      _silhouetteSideDepthSamplesM,
      fallback: 0,
      minSamples: _minSilhouetteSamples,
      percentile: 0.25,
    );
    final sideDepth = _robustMetricMean(
      _rotationSideDepthSamplesM,
      fallback: _median(_rotationSideDepthSamplesM),
      minSamples: 2,
    );
    final waistWidth = _robustMetricMean(
      _silhouetteWaistSamplesM,
      fallback: 0,
      minSamples: _minSilhouetteSamples,
    );
    var depth = silhouetteSideDepth > 0
        ? silhouetteSideDepth
        : sideDepth > 0
        ? sideDepth
        : (_minWidth.isFinite && _minWidth > 0
              ? _minWidth
              : widthM * BODY_DEPTH_RATIO);
    if (waistWidth > 0 && depth > 0) {
      depth = (depth * 0.75) + (waistWidth * 0.25);
    }
    if (widthM > 0) {
      final typical = widthM * BODY_DEPTH_RATIO;
      if (depth < typical * 0.76) {
        depth = (depth * 0.42) + (typical * 0.58);
      }
      if (depth / widthM > 0.64) {
        depth = typical;
      }
      depth = depth.clamp(BodyMetrics.minDepthM, typical * 1.12);
    }
    return depth.clamp(BodyMetrics.minDepthM, BodyMetrics.maxDepthM);
  }

  double _rotationStabilityScore() {
    final hDisp = _relativeDispersion(_rotationHeightSamplesPx);
    final wDisp = _relativeDispersion(_rotationShoulderSamplesPx);
    final metricDisp = _metricRelativeDispersion(
      _rotationEstimatedHeightSamplesM,
    );
    final avgDisp = (hDisp + wDisp + metricDisp) / 3;
    final normalized = (avgDisp / _maxAllowedRelativeDispersion).clamp(
      0.0,
      1.0,
    );
    return (1.0 - normalized).clamp(0.0, 1.0);
  }

  _QualityBreakdown _rotationQualityBreakdown() {
    final coverageScore = _rotationQualityRatio();
    final missingTotal =
        _rotationMissingShoulderFrameCount + _rotationMissingAnkleFrameCount;
    final completenessScore = _frameCount <= 0
        ? 0.0
        : (1.0 - (missingTotal / _frameCount).clamp(0.0, 1.0)).clamp(0.0, 1.0);
    final stabilityScore = _rotationStabilityScore();
    // Weighted blend: coverage most important, then stability, then completeness.
    final finalScore =
        (0.50 * coverageScore) +
        (0.30 * stabilityScore) +
        (0.20 * completenessScore);
    return _QualityBreakdown(
      coverageScore: coverageScore,
      stabilityScore: stabilityScore,
      completenessScore: completenessScore,
      finalScore: finalScore.clamp(0.0, 1.0),
    );
  }

  double _rotationQualityScore() {
    return _rotationQualityBreakdown().finalScore;
  }

  int _rotationValidFrameTarget() {
    return Platform.isAndroid
        ? ANDROID_REQUIRED_VALID_FRAMES
        : IOS_REQUIRED_VALID_FRAMES;
  }

  int _minScanSecondsForDevice() {
    return Platform.isAndroid ? ANDROID_MIN_SCAN_SECONDS : IOS_MIN_SCAN_SECONDS;
  }

  int _rotationElapsedSeconds() {
    final startedAt = _rotationStartedAt;
    if (startedAt == null) return 0;
    return DateTime.now().difference(startedAt).inSeconds;
  }

  bool _shouldCompleteRotationScan() {
    final needed = _rotationValidFrameTarget();
    final frontN = _rotationFrontWidthSamplesM.length;
    final sideN = _rotationSideDepthSamplesM.length;
    final elapsed = _rotationElapsedSeconds();
    // Log sparingly — this is called every processed frame.
    if (_rotationValidFrameCount == 0 ||
        _rotationValidFrameCount % 5 == 0 ||
        _rotationValidFrameCount >= needed - 2) {
      debugPrint(
        'shouldComplete? valid=$_rotationValidFrameCount/$needed '
        'front=$frontN side=$sideN elapsed=${elapsed}s',
      );
    }

    final hasBothViews =
        frontN >= _effectiveMinFrontSamples &&
        sideN >= _effectiveMinSideSamples;
    final minSeconds = _minScanSecondsForDevice();
    final minUsable = Platform.isAndroid
        ? ANDROID_MIN_USABLE_VALID_FRAMES
        : IOS_MIN_USABLE_VALID_FRAMES;

    // Shared soft-complete: never finish before a real 360 window.
    if (elapsed < minSeconds) return false;
    if (hasBothViews && _rotationValidFrameCount >= needed) return true;
    if (hasBothViews &&
        elapsed >= minSeconds + 4 &&
        _rotationValidFrameCount >= (needed * 0.75).round()) {
      return true;
    }
    // After a full turn window, don't wait forever on F/S.
    if (elapsed >= minSeconds + 8 &&
        _rotationValidFrameCount >= minUsable) {
      return true;
    }
    return false;
  }

  /// Last-resort exit if completion path wedges on "Preparing your BMI…".
  Future<void> _forceFinishOrRetryFromPreparing() async {
    if (!mounted || _showInlineResults) return;
    _prepareMetricsFromPartialScan();
    if ((!_minWidth.isFinite || _minWidth <= 0) && _maxWidth > 0) {
      _minWidth = _maxWidth * BODY_DEPTH_RATIO;
    }
    _showInlineBmiResults(
      _buildLocalEstimate() ??
          _buildSubmissionEstimate() ??
          _buildFallbackEstimate() ??
          _lastResortEstimate(),
    );
  }

  int _rotationMaxSecondsForDevice() {
    if (Platform.isAndroid) return ROTATION_MAX_SECONDS_ANDROID;
    final shortestSideDp = MediaQuery.sizeOf(context).shortestSide;
    final isHighTier = shortestSideDp >= HIGH_TIER_MIN_SCREEN_WIDTH_DP;
    return isHighTier
        ? ROTATION_MAX_SECONDS_HIGH_TIER
        : ROTATION_MAX_SECONDS_LOW_TIER;
  }

  String? _manualCalibrationBlockReason() {
    if (_latestVideoPath == null || _latestVideoPath!.isEmpty) {
      return 'Record a scan first, then tap Manual Calibration.';
    }
    if (currentPhase != ScanPhase.completed) {
      return 'Finish recording first, then submit calibration.';
    }
    if (_autoStoppedByStreamIssue) {
      return 'Frame capture was interrupted. Please retake the scan.';
    }
    if (_autoStoppedByDurationCap && _qualityTooLowAtAutoStop) {
      return 'Scan stopped at ${_rotationMaxSecondsForDevice()}s with low landmark quality. Please retake.';
    }
    if (_frameCount < _rotationValidFrameTarget()) {
      return 'Capture a full 360deg scan before submitting.';
    }
    if (_rotationQualityScore() < _minRotationQualityScoreToSubmit) {
      return 'Scan quality is below standard. Retake with better lighting and full body visibility.';
    }
    if (_rotationValidFrameCount < _minValidRotationFrames) {
      return 'Not enough usable full-body frames. Keep shoulders and ankles visible and retake.';
    }
    final validRatio = _frameCount > 0
        ? _rotationValidFrameCount / _frameCount
        : 0.0;
    if (validRatio < _minValidRotationFrameRatio) {
      return 'Too many frames missed landmarks. Retake with better lighting and full body in frame.';
    }
    if (_rotationEstimatedHeightSamplesM.length < _minMetricStableSamples) {
      return 'Not enough stable body measurements. Rotate slowly with full body visible.';
    }
    if (_rotationFrontWidthSamplesM.length < _minFrontWidthSamples) {
      return 'Face the camera briefly during the scan so body width can be estimated.';
    }
    if (_rotationSideDepthSamplesM.length < _minSideDepthSamples) {
      return 'Turn sideways briefly during the scan so body depth can be estimated.';
    }
    if (_metricRelativeDispersion(_rotationEstimatedHeightSamplesM) >
        _maxAllowedMetricDispersion) {
      return 'Body proportions were unstable. Retake with steady camera distance and fitted clothing.';
    }
    if (_metricRelativeDispersion(_rotationWidthSamplesM) >
        _maxAllowedMetricDispersion) {
      return 'Width tracking was unstable. Keep shoulders visible and rotate more slowly.';
    }
    if (_resolvedHeightPx() <= 0) {
      return 'Height landmarks are incomplete. Keep head and feet fully visible.';
    }
    if (_resolvedShoulderWidthPx() <= 0) {
      return 'Shoulder landmarks are incomplete. Face camera once before rotating.';
    }
    if (_resolvedMaxBodyAreaPx(
          _resolvedHeightPx(),
          _resolvedShoulderWidthPx(),
        ) <=
        0) {
      return 'Body area could not be estimated. Retake scan with stable camera and full body visible.';
    }
    return null;
  }

  double _resolvedHeightPx() {
    return lockedHeightPx ??
        (_rotationHeightSamplesPx.isNotEmpty
            ? trimmedMean(_rotationHeightSamplesPx)
            : 0);
  }

  double _resolvedShoulderWidthPx() {
    return lockedShoulderWidthPx ??
        (_rotationShoulderSamplesPx.isNotEmpty
            ? trimmedMean(_rotationShoulderSamplesPx)
            : 0);
  }

  double _resolvedMaxBodyAreaPx(double heightPx, double shoulderWidthPx) {
    return _maxBodyAreaPx > 0 ? _maxBodyAreaPx : heightPx * shoulderWidthPx;
  }

  double _resolvedDepthPx(double shoulderWidthPx) {
    if (_minWidthPx.isFinite && _minWidthPx > 0) return _minWidthPx;
    return shoulderWidthPx * BODY_DEPTH_RATIO;
  }

  // Starts a watchdog timer to ensure frames are being received during rotation phase.
  void _startFrameReceptionWatchdog() {
    _frameReceptionWatchdog?.cancel();
    _frameReceptionWatchdog = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (currentPhase != ScanPhase.rotation || _isStoppingAfterCompletion) {
        timer.cancel();
        return;
      }
      if (DateTime.now().difference(_lastFrameTime) > _frameReceptionTimeout) {
        if (Platform.isAndroid &&
            currentPhase == ScanPhase.rotation &&
            _isScanRecording) {
          return;
        }
        debugPrint(
          'Frame reception watchdog: no camera frames for '
          '${_frameReceptionTimeout.inSeconds}s — recovering pipeline.',
        );
        unawaited(_recoverCameraPipeline(forceReinit: false));
        _lastFrameTime = DateTime.now();
      }
    });
  }

  bool get _isUploadingScan => _isSubmittingManualCalibration;

  String _simpleTopTitle(ScanPhase phase) {
    if (_isStoppingAfterCompletion) {
      if (_text.contains('Preparing') || _text.contains('BMI')) {
        return 'Almost done';
      }
      if (_text.contains('Uploading') || _text.contains('Verifying')) {
        return 'Almost done';
      }
      return 'Saving your scan';
    }
    switch (phase) {
      case ScanPhase.calibration:
        return 'Step 1 · Fit in the guide';
      case ScanPhase.staticMeasurement:
        return 'Step 2 · Hold still';
      case ScanPhase.readyToRotate:
        return 'Step 3 · Ready to scan';
      case ScanPhase.rotation:
        return 'Step 4 · Turn slowly';
      case ScanPhase.completed:
        return 'Almost done';
    }
  }

  bool get _hideScanChrome =>
      _isUploadingScan ||
      _isStoppingAfterCompletion ||
      (_isScanRecording && currentPhase == ScanPhase.rotation);

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    _screenHeightCached = screenH;
    _screenWidthCached = screenW;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final topSafe = MediaQuery.of(context).padding.top;

    // Guide box occupies 80% of screen height, centered vertically
    _guideHeightPx = screenH * 0.80;
    _guideTopY = (screenH - _guideHeightPx) / 2;
    _guideBottomY = _guideTopY + _guideHeightPx;
    final guideWidthPx = screenW * 0.75;

    if (currentPhase == ScanPhase.calibration) {
      cmPerPixel = guideRealHeightCm / _guideHeightPx;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraView(
            key: _cameraViewKey,
            customPainter:
                _isUploadingScan ? null : _customPainter,
            onImage: _processImage,
            initialDirection: _cameraLensDirection,
            isCaptureEnabled:
                _canStartRecording() &&
                !_isUploadingScan &&
                !_isStoppingAfterCompletion,
            hideCaptureControls: _hideScanChrome,
            hideUtilityChrome: _hideScanChrome,
            onRecordPressed: _onRecordPressed,
            onRecordingStateChanged: (isRecording, path) {
              if (!isRecording &&
                  path != null &&
                  path.isNotEmpty &&
                  mounted) {
                setState(() => _latestVideoPath = path);
              }
            },
          ),

          // Guide box — only for body-fit steps
          if (!_isUploadingScan &&
              (currentPhase == ScanPhase.calibration ||
                  currentPhase == ScanPhase.staticMeasurement ||
                  currentPhase == ScanPhase.readyToRotate))
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GuideBoxPainter(
                    guideTopY: _guideTopY,
                    guideBottomY: _guideBottomY,
                    guideWidthPx: guideWidthPx,
                    screenWidth: screenW,
                    isAligned: currentPhase != ScanPhase.calibration,
                  ),
                ),
              ),
            ),

          // Close
          Positioned(
            top: topSafe + 12,
            left: 12,
            child: Material(
              color: Colors.black.withValues(alpha: 0.52),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                iconSize: 22,
                tooltip: 'Close',
                onPressed: () => _exitCapture(),
              ),
            ),
          ),

          if (_isUploadingScan)
            _verificationOverlay()
          else ...[
            // Top: one simple status line
            Positioned(
              top: topSafe + 16,
              left: 64,
              right: 72,
              child: _GlassPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.56),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.20),
                  ),
                ),
                child: Text(
                  _simpleTopTitle(currentPhase),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.96),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            // Stop button during 360 scan
            if (_isScanRecording && currentPhase == ScanPhase.rotation)
              Positioned(
                bottom: bottomSafe + 36,
                right: 16,
                child: Material(
                  color: Colors.redAccent,
                  elevation: 8,
                  shadowColor: Colors.black.withValues(alpha: 0.45),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      unawaited(_handleUserStopRecording());
                    },
                    child: const SizedBox(
                      width: 64,
                      height: 64,
                      child: Icon(
                        Icons.stop_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                ),
              ),

            // Bottom: one instruction + simple progress
            Positioned(
              bottom: bottomSafe +
                  (_hideScanChrome && !_isStoppingAfterCompletion ? 36 : 110),
              left: 16,
              right: _hideScanChrome && !_isStoppingAfterCompletion ? 92 : 16,
              child: _GlassPanel(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.20),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _simplePrimaryInstruction(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _simpleSecondaryInstruction(),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 6,
                        value: _phaseProgress(currentPhase),
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _phaseAccent(currentPhase),
                        ),
                      ),
                    ),
                    if (_isRecoveringStream) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Reconnecting camera… please wait',
                        style: TextStyle(
                          color: const Color(0xFF76C8FF),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_showInlineResults)
            Positioned.fill(child: _buildAndroidResultScreen()),
        ],
      ),
    );
  }

  String _simplePrimaryInstruction() {
    if (_isRecoveringStream) return 'One moment';
    if (_isStoppingAfterCompletion) {
      if (_text.contains('Preparing') || _text.contains('BMI')) {
        return 'Preparing your BMI…';
      }
      if (_text.contains('Saving') || _text.contains('hold still')) {
        return 'Saving scan video…';
      }
      if (_text.contains('Uploading') || _text.contains('Verifying')) {
        return 'Verifying your scan…';
      }
      return 'Finishing scan…';
    }
    switch (currentPhase) {
      case ScanPhase.calibration:
        if (_text.contains('closer')) return 'Step a little closer';
        if (_text.contains('further')) return 'Step a little further back';
        return 'Stand inside the outline';
      case ScanPhase.staticMeasurement:
        return 'Hold still';
      case ScanPhase.readyToRotate:
        return 'Tap the record button';
      case ScanPhase.rotation:
        if (_isScanRecording) {
          final minSeconds = _minScanSecondsForDevice();
          final elapsed = _rotationElapsedSeconds();
          final shown = elapsed.clamp(0, minSeconds);
          return 'Turn slowly · full circle · ${shown}s/${minSeconds}s';
        }
        return 'Slowly turn in a full circle';
      case ScanPhase.completed:
        if (_text.contains('Uploading')) return 'Verifying your scan…';
        return 'Scan complete';
    }
  }

  String _simpleSecondaryInstruction() {
    if (_isRecoveringStream) {
      return 'Keep the phone steady while we reconnect.';
    }
    if (_isStoppingAfterCompletion) {
      final started = _uploadClipStartedAt;
      if (started != null) {
        final elapsed =
            DateTime.now().difference(started).inSeconds.clamp(0, _uploadClipSeconds);
        return 'Hold still · recording verification clip $elapsed/$_uploadClipSeconds s';
      }
      return 'Almost there — opening your BMI results…';
    }
    switch (currentPhase) {
      case ScanPhase.calibration:
        return 'Make sure your head and feet are fully visible.';
      case ScanPhase.staticMeasurement:
        return 'Stay still so we can lock your height.';
      case ScanPhase.readyToRotate:
        return 'We record your full turn, then verify it on the server.';
      case ScanPhase.rotation:
        if (_isScanRecording) {
          if (Platform.isAndroid) {
            final elapsed = _rotationElapsedSeconds();
            if (elapsed < ANDROID_MIN_SCAN_SECONDS) {
              return 'Keep turning slowly for a full circle — do not stop early.';
            }
            final f = _rotationFrontWidthSamplesM.length;
            final s = _rotationSideDepthSamplesM.length;
            if (f < _effectiveMinFrontSamples) {
              return 'Face the camera so we can measure width for weight.';
            }
            if (s < _effectiveMinSideSamples) {
              return 'Turn sideways so we can measure depth.';
            }
            return 'Keep turning slowly until the scan finishes.';
          }
          final f = _rotationFrontWidthSamplesM.length;
          final s = _rotationSideDepthSamplesM.length;
          final needed = _rotationValidFrameTarget();
          if (f < _effectiveMinFrontSamples) {
            return 'Face the camera so we can measure width for weight.';
          }
          if (s < _effectiveMinSideSamples) {
            return 'Turn sideways so we can measure depth.';
          }
          if (_rotationValidFrameCount < needed) {
            return 'Keep turning slowly for a full circle — do not stop early.';
          }
          return 'Keep turning slowly until the scan finishes.';
        }
        return 'One slow full turn — keep facing changes until it finishes.';
      case ScanPhase.completed:
        return 'Uploading your scan video for identity check.';
    }
  }

  Widget _verificationOverlay() {
    const titles = <String>[
      'Uploading…',
      'Checking identity…',
      'Preparing results…',
    ];
    const subtitles = <String>[
      'Sending your scan securely.',
      'Matching your face to your profile.',
      'Almost ready.',
    ];
    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.68),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BmiLoader(showLabel: false),
                const SizedBox(height: 16),
                Text(
                  titles[_verificationStepIndex],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.96),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitles[_verificationStepIndex],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _phaseAccent(ScanPhase phase) {
    switch (phase) {
      case ScanPhase.calibration:
        return _brandOrange;
      case ScanPhase.staticMeasurement:
        return const Color(0xFF2EA9FF);
      case ScanPhase.readyToRotate:
        return const Color(0xFF31B46E);
      case ScanPhase.rotation:
        return _brandBlue;
      case ScanPhase.completed:
        return const Color(0xFF31B46E);
    }
  }

  double _phaseProgress(ScanPhase phase) {
    if (_isStoppingAfterCompletion) {
      final started = _uploadClipStartedAt;
      if (started != null && _uploadClipSeconds > 0) {
        final elapsed =
            DateTime.now().difference(started).inMilliseconds / 1000.0;
        return (elapsed / _uploadClipSeconds).clamp(0.05, 0.95);
      }
      return 0.85;
    }
    switch (phase) {
      case ScanPhase.calibration:
        return 0.15;
      case ScanPhase.staticMeasurement:
        return (_staticFrameCount / 90).clamp(0.15, 0.58);
      case ScanPhase.readyToRotate:
        return 0.62;
      case ScanPhase.rotation:
        if (Platform.isAndroid) {
          final elapsed = _rotationElapsedSeconds();
          return (elapsed / ANDROID_MIN_SCAN_SECONDS).clamp(0.0, 0.98);
        }
        return (_rotationValidFrameCount / _rotationValidFrameTarget())
            .clamp(0.0, 1.0);
      case ScanPhase.completed:
        return 1.0;
    }
  }

  Future<void> _processImage(InputImage inputImage) async {
    if (!_canProcess || _isStoppingAfterCompletion) return;

    _cameraCallbackCount++;
    _lastFrameTime = DateTime.now();
    _pendingInputImage = inputImage;

    _logFrameDiagnostics('callback');

    if (_processingInFlight) {
      final busySince = _busySince;
      if (busySince != null &&
          DateTime.now().difference(busySince) > _poseProcessTimeout) {
        debugPrint(
          'Pose stall: processing >${_poseProcessTimeout.inMilliseconds}ms '
          '— resetting detector.',
        );
        _logFrameDiagnostics('busy_reset');
        _unstickAndroidScanPipeline(reason: 'processing_stall');
      } else if (Platform.isAndroid &&
          currentPhase == ScanPhase.rotation &&
          _cameraCallbackCount % 10 == 0) {
        debugPrint(
          'FrameDiag pose: callback_busy callbacks=$_cameraCallbackCount '
          'processed=$_frameCount valid=$_rotationValidFrameCount '
          'pending=${_pendingInputImage != null} '
          'busyForMs=${busySince == null ? 0 : DateTime.now().difference(busySince).inMilliseconds}',
        );
      }
      return;
    }

    await _drainPendingImages();
  }

  Future<void> _drainPendingImages() async {
    if (_processingInFlight) return;
    while (_pendingInputImage != null &&
        _canProcess &&
        !_isStoppingAfterCompletion) {
      final image = _pendingInputImage!;
      _pendingInputImage = null;
      final generation = ++_processingGeneration;
      _processingInFlight = true;
      _isBusy = true;
      _busySince = DateTime.now();
      try {
        await _processOneImage(image, generation);
      } finally {
        _processingInFlight = false;
        _isBusy = false;
        _busySince = null;
      }
    }
  }

  Future<void> _processOneImage(
    InputImage inputImage,
    int generation,
  ) async {
    if (currentPhase == ScanPhase.rotation && !_isStoppingAfterCompletion) {
      if (_shouldCompleteRotationScan()) {
        debugPrint('ProcessOneImage finished scan (shouldComplete)');
        unawaited(
          _completeRotationRecording(
            stoppedByDurationCap: false,
            reason: 'should_complete',
          ),
        );
        return;
      }

      final startedAt = _rotationStartedAt;
      final elapsedSeconds = startedAt == null
          ? 0
          : DateTime.now().difference(startedAt).inSeconds;
      if (elapsedSeconds >= _rotationMaxSecondsForDevice()) {
        debugPrint(
          'ProcessOneImage finished scan (duration) '
          'elapsed=${elapsedSeconds}s valid=$_rotationValidFrameCount',
        );
        unawaited(
          _completeRotationRecording(
            stoppedByDurationCap: true,
            reason: 'process_one_duration',
          ),
        );
        return;
      }
    }

    try {
      if (_isStoppingAfterCompletion || generation != _processingGeneration) {
        return;
      }

      _totalFrames++;

      List<Pose> poses;
      try {
        poses = await _poseDetector.processImage(inputImage).timeout(
          _poseProcessTimeout,
          onTimeout: () {
            debugPrint(
              'Pose processImage timeout (${_poseProcessTimeout.inMilliseconds}ms)',
            );
            _resetPoseDetector(reason: 'process_image_timeout');
            return <Pose>[];
          },
        );
      } catch (e) {
        debugPrint('Pose processImage failed: $e');
        _resetPoseDetector(reason: 'process_image_error');
        return;
      }
      if (generation != _processingGeneration) return;

      if (currentPhase == ScanPhase.rotation && !_isStoppingAfterCompletion) {
        _frameCount++;
        _logFrameDiagnostics('processed');
      }

      if (inputImage.metadata?.size != null &&
          inputImage.metadata?.rotation != null) {
        if (currentPhase == ScanPhase.rotation) {
          if (poses.isNotEmpty) {
            _calculateMeasurements(
              poses.first,
              inputImage.metadata!.size,
              inputImage.metadata!.rotation,
            );
            // Pose-only during 360 on both platforms so weight/BMI match
            // the Android field-tuned model (silhouette diverged iOS kg).
          }

          if (!_isStoppingAfterCompletion && _shouldCompleteRotationScan()) {
            debugPrint('ProcessOneImage finished scan (shouldComplete after measure)');
            unawaited(
              _completeRotationRecording(
                stoppedByDurationCap: false,
                reason: 'should_complete_after_measure',
              ),
            );
            return;
          }
        } else {
          if (poses.isNotEmpty) {
            _calculateMeasurements(
              poses.first,
              inputImage.metadata!.size,
              inputImage.metadata!.rotation,
            );
          } else {
            if (_personInFrame) setState(() => _personInFrame = false);
            if (currentPhase != ScanPhase.completed &&
                !_text.startsWith("Scan Complete")) {
              setState(() => _text = "Stand inside the guide box");
            }
          }
        }

        final painter = PosePainter(
          poses,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
          isStable: currentPhase != ScanPhase.calibration,
          detectedCubeBoxes: const [],
        );
        if (!mounted) return;
        if (poses.isNotEmpty) {
          _lastGoodPosePainter = painter;
          _lastGoodPosePainterAt = DateTime.now();
          _customPainter = painter;
        } else if (currentPhase == ScanPhase.rotation &&
            _lastGoodPosePainter != null &&
            _lastGoodPosePainterAt != null &&
            DateTime.now().difference(_lastGoodPosePainterAt!) <
                const Duration(milliseconds: 400)) {
          // Brief grace only — longer reuse freezes the overlay at 0/target.
          _customPainter = _lastGoodPosePainter;
        } else {
          _lastGoodPosePainter = null;
          _lastGoodPosePainterAt = null;
          _customPainter = painter;
        }
        _logFrameDiagnostics('paint');
        _maybeUpdateScanUi(forcePaint: poses.isNotEmpty);
      }
    } catch (e) {
      debugPrint('Pose error: $e');
      _resetPoseDetector(reason: 'process_one_image_error');
    } finally {
      if (_pendingInputImage != null &&
          _canProcess &&
          !_isStoppingAfterCompletion &&
          !_processingInFlight) {
        unawaited(_drainPendingImages());
      }
    }
  }

  Future<void> _maybeProcessSilhouette(
    InputImage inputImage,
    Pose pose,
    Size imageSize,
  ) async {
    if (_isSegmenting ||
        _isStoppingAfterCompletion ||
        currentPhase != ScanPhase.rotation ||
        _frameCount <= _qualityWarmupFrames ||
        _frameCount - _lastSegmentedFrameCount < _segmentationFrameInterval) {
      return;
    }

    _isSegmenting = true;
    _lastSegmentedFrameCount = _frameCount;
    try {
      final mask = await _selfieSegmenter.processImage(inputImage);
      if (mask == null) return;
      _collectSilhouetteMeasurements(mask, pose, imageSize);
    } catch (e) {
      debugPrint('Segmentation error: $e');
    } finally {
      _isSegmenting = false;
    }
  }

  void _collectSilhouetteMeasurements(
    SegmentationMask mask,
    Pose pose,
    Size imageSize,
  ) {
    final nose = pose.landmarks[PoseLandmarkType.nose];
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
    if (nose == null ||
        leftShoulder == null ||
        rightShoulder == null ||
        leftHip == null ||
        rightHip == null ||
        leftAnkle == null ||
        rightAnkle == null ||
        imageSize.width <= 0 ||
        imageSize.height <= 0) {
      return;
    }

    final shoulderY = (leftShoulder.y + rightShoulder.y) / 2;
    final hipY = (leftHip.y + rightHip.y) / 2;
    final ankleY = (leftAnkle.y + rightAnkle.y) / 2;
    final headOffset = (leftShoulder.y - hipY).abs() * 0.7;
    final headY = leftShoulder.y - headOffset;
    final poseHeightPx = (ankleY - headY).abs();
    final bodyHeightPx = poseHeightPx * HEIGHT_CORRECTION_FACTOR;
    if (bodyHeightPx <= 0) return;

    final waistY = shoulderY + ((hipY - shoulderY) * 0.58);
    final shoulderWidthPx = _maskWidthAtImageY(mask, shoulderY, imageSize);
    final waistWidthPx = _maskWidthAtImageY(mask, waistY, imageSize);
    final hipWidthPx = _maskWidthAtImageY(mask, hipY, imageSize);
    if (waistWidthPx <= 0 && shoulderWidthPx <= 0 && hipWidthPx <= 0) {
      return;
    }

    final heightM = _lockedHeightMeters() ??
        (_smoothedHeight > 0 ? _smoothedHeight : _fallbackHeightMeters);
    final metersPerImagePx = heightM / bodyHeightPx;
    final shoulderWidthM = shoulderWidthPx * metersPerImagePx;
    final waistWidthM = waistWidthPx * metersPerImagePx;
    final hipWidthM = hipWidthPx * metersPerImagePx;
    final bodyWidthM = max(shoulderWidthM, max(waistWidthM, hipWidthM));
    if (!bodyWidthM.isFinite || bodyWidthM <= 0) return;

    final shoulderLandmarkWidth =
        (leftShoulder.x - rightShoulder.x).abs();
    final shoulderToHeight =
        bodyHeightPx > 0 ? (shoulderLandmarkWidth / bodyHeightPx) : 0.0;
    final isSideView = shoulderToHeight < 0.16;
    if (isSideView) {
      _silhouetteSideDepthSamplesM.add(bodyWidthM.clamp(0.15, 0.6));
    } else if (shoulderToHeight > 0.22) {
      _silhouetteFrontWidthSamplesM.add(bodyWidthM.clamp(0.2, 0.8));
      if (waistWidthM.isFinite && waistWidthM > 0) {
        _silhouetteWaistSamplesM.add(waistWidthM.clamp(0.15, 0.7));
      }
    }
  }

  double _maskWidthAtImageY(
    SegmentationMask mask,
    double imageY,
    Size imageSize,
  ) {
    if (mask.width <= 0 ||
        mask.height <= 0 ||
        mask.confidences.length < mask.width * mask.height ||
        imageSize.height <= 0) {
      return 0;
    }

    final centerY = ((imageY / imageSize.height) * mask.height).round().clamp(
      0,
      mask.height - 1,
    );
    final bandRadius = max(1, (mask.height * 0.01).round());
    int? left;
    int? right;

    for (var y = centerY - bandRadius; y <= centerY + bandRadius; y++) {
      if (y < 0 || y >= mask.height) continue;
      final rowOffset = y * mask.width;
      for (var x = 0; x < mask.width; x++) {
        final confidence = mask.confidences[rowOffset + x];
        if (confidence >= _maskForegroundThreshold) {
          left = left == null ? x : min(left, x);
          right = right == null ? x : max(right, x);
        }
      }
    }

    if (left == null || right == null || right <= left) return 0;
    final maskWidthPx = (right - left).toDouble();
    return maskWidthPx * (imageSize.width / mask.width);
  }

  void _calculateMeasurements(
    Pose pose,
    Size imageSize,
    InputImageRotation rotation,
  ) {
    try {
      _calculateMeasurementsImpl(pose, imageSize, rotation);
    } catch (e, st) {
      debugPrint('calculateMeasurements failed: $e\n$st');
    }
  }

  void _calculateMeasurementsImpl(
    Pose pose,
    Size imageSize,
    InputImageRotation rotation,
  ) {
    // ── PHASE 4: Rotation (Collect Volume Data) ───────────────────────
    if (currentPhase == ScanPhase.rotation) {
      final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
      final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
      final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
      final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
      final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
      final rightHip = pose.landmarks[PoseLandmarkType.rightHip];

      if (leftShoulder == null || rightShoulder == null) {
        _rotationMissingShoulderFrameCount++;
        return;
      }
      // Count any frame with both shoulders so 320x240 ankle-misses
      // cannot leave valid at 2 after 400 processed frames.
      _rotationValidFrameCount++;

      // Side views often drop ankles — still count the frame if hips exist.
      final leftAnkleSafe = leftAnkle ?? rightAnkle;
      final rightAnkleSafe = rightAnkle ?? leftAnkle;
      final hipMidY = (leftHip != null && rightHip != null)
          ? (leftHip.y + rightHip.y) / 2
          : null;

      late final double ankleMidY;
      if (leftAnkleSafe != null && rightAnkleSafe != null) {
        ankleMidY = (leftAnkleSafe.y + rightAnkleSafe.y) / 2;
      } else if (hipMidY != null) {
        ankleMidY = hipMidY + (hipMidY - leftShoulder.y).abs() * 1.15;
      } else {
        _rotationMissingAnkleFrameCount++;
        return;
      }

      final headOffset =
          (leftShoulder.y - (leftHip?.y ?? leftShoulder.y)).abs() * 0.78;
      final headY = leftShoulder.y - headOffset;
      final pixelHeight = (ankleMidY - headY).abs();
      final shoulderDiff = (leftShoulder.x - rightShoulder.x).abs();
      if (pixelHeight <= 0) return;

      final screenH = _verticalImageDeltaToScreenPx(
        pixelHeight,
        imageSize,
        rotation,
      );
      final screenWShoulder = _horizontalImageDeltaToScreenPx(
        shoulderDiff,
        imageSize,
        rotation,
      );
      final cmPerPx = _lateralCmPerPixel();
      final height = _poseHeightMeters(screenH);
      final width = ((screenWShoulder * cmPerPx) / 100).clamp(
        BodyMetrics.minWidthM,
        BodyMetrics.maxWidthM,
      );

      // True front vs side for volume. Oblique frames are ignored for
      // width/depth so 3/4-turn views don't shrink weight.
      final shoulderToHeight =
          pixelHeight > 0 ? (shoulderDiff / pixelHeight) : 0.0;
      final isSideView = shoulderToHeight < 0.15;
      final isFrontView = shoulderToHeight > 0.20;
      if (_rotationValidFrameCount >= _qualityWarmupFrames ||
          _frameCount > _qualityWarmupFrames) {
        _rotationEstimatedHeightSamplesM.add(height);
        _rotationWidthSamplesM.add(width);
        if (isFrontView) {
          _rotationFrontWidthSamplesM.add(width);
          if (leftHip != null && rightHip != null) {
            final hipDiff = (leftHip.x - rightHip.x).abs();
            final screenHip = _horizontalImageDeltaToScreenPx(
              hipDiff,
              imageSize,
              rotation,
            );
            final hipM = ((screenHip * cmPerPx) / 100).clamp(
              BodyMetrics.minWidthM,
              BodyMetrics.maxWidthM,
            );
            _rotationFrontHipWidthSamplesM.add(hipM);
          }
        } else if (isSideView) {
          _rotationSideDepthSamplesM.add(width);
        }
      }

      final hasMetricHeight =
          _rotationEstimatedHeightSamplesM.length >= _minMetricStableSamples;
      final hasFrontWidth =
          _rotationFrontWidthSamplesM.length >= _effectiveMinFrontSamples;
      final hasSideDepth =
          _rotationSideDepthSamplesM.length >= _effectiveMinSideSamples;
      final robustHeight = hasMetricHeight ? _resolvedHeightM() : height;
      final robustWidth = hasFrontWidth ? _resolvedWidthM() : width;
      final robustDepth = hasSideDepth ? _resolvedDepthM(robustWidth) : width;

      _smoothedHeight = _smooth(_smoothedHeight, robustHeight);
      _smoothedWidth = _smooth(_smoothedWidth, robustWidth);
      _smoothedDepth = _smooth(_smoothedDepth, robustDepth);
      if (isFrontView && !isSideView) {
        if (width > _maxWidth) _maxWidth = width;
      } else if (isSideView) {
        if (width < _minWidth) _minWidth = width;
      }
      final hasProperRotation =
          _maxWidth > 0 && _minWidth.isFinite && _minWidth < (_maxWidth * 0.85);
      if ((!_minWidth.isFinite || _minWidth == 0) &&
          _maxWidth > 0 &&
          hasSideDepth) {
        // Only invent depth from width after we actually saw a side view.
        _minWidth = _maxWidth * BODY_DEPTH_RATIO;
      }
      _stableFrameCount++;
      _isRotationComplete = hasProperRotation;

      // Keep legacy px-based samples for overlays/compatibility.
      _smoothedHeightPx = _smooth(_smoothedHeightPx, screenH);
      _smoothedWidthPx = _smooth(_smoothedWidthPx, screenWShoulder);
      _rotationHeightSamplesPx.add(_smoothedHeightPx);
      _rotationShoulderSamplesPx.add(_smoothedWidthPx);
      _logFrameDiagnostics(
        isFrontView
            ? 'valid_front'
            : isSideView
            ? 'valid_side'
            : 'valid_oblique',
      );
      if (isFrontView && !isSideView) {
        if (_smoothedWidthPx > _maxWidthPx) _maxWidthPx = _smoothedWidthPx;
      } else if (isSideView) {
        if (_smoothedWidthPx < _minWidthPx) _minWidthPx = _smoothedWidthPx;
      }
      final currentAreaPx = _smoothedHeightPx * _smoothedWidthPx;
      if (currentAreaPx > _maxBodyAreaPx) {
        _maxBodyAreaPx = currentAreaPx;
      }
      return; // Skip other phase logic
    }

    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];

    if (leftShoulder == null || rightShoulder == null) {
      if (_personInFrame) setState(() => _personInFrame = false);
      return;
    }
    if (!_personInFrame) setState(() => _personInFrame = true);

    // ── Compute person's pixel height from pose ───────────────────────
    final headOffset =
        (leftShoulder.y - (leftHip?.y ?? leftShoulder.y)).abs() * 0.7;

    if (leftAnkle == null || rightAnkle == null) {
      if (currentPhase == ScanPhase.calibration ||
          currentPhase == ScanPhase.staticMeasurement) {
        setState(() => _text = "Show full body (ankles must be visible)");
      }
      return;
    }

    final ankleMidY = (leftAnkle.y + rightAnkle.y) / 2;
    final headY = leftShoulder.y - headOffset;
    final poseHeightPx = (ankleMidY - headY).abs();

    final screenPoseHeightPx = _verticalImageDeltaToScreenPx(
      poseHeightPx,
      imageSize,
      rotation,
    );
    final screenShoulderWidthPx = _horizontalImageDeltaToScreenPx(
      (leftShoulder.x - rightShoulder.x).abs(),
      imageSize,
      rotation,
    );

    final fillRatio = screenPoseHeightPx / _guideHeightPx;
    final isAligned = fillRatio >= 0.80 && fillRatio <= 1.25;

    // ── PHASE 1: Calibration ──────────────────────────────────────────
    if (currentPhase == ScanPhase.calibration) {
      if (isAligned) {
        setState(() {
          currentPhase = ScanPhase.staticMeasurement;
          _staticFrameCount = 0;
          heightSamplesPx.clear();
          shoulderWidthSamplesPx.clear();
        });
      } else {
        if (fillRatio < 0.80) {
          setState(() => _text = "📏 Move closer to the camera");
        } else if (fillRatio > 1.25) {
          setState(() => _text = "📏 Move further from the camera");
        }
      }
    }
    // ── PHASE 2: Static Measurement (Lock Height/Width) ───────────────
    else if (currentPhase == ScanPhase.staticMeasurement) {
      if (!isAligned) {
        setState(() {
          currentPhase = ScanPhase.calibration;
          _text = "⚠️ Realignment needed";
        });
        return;
      }

      _staticFrameCount++;

      // Discard first 30 frames as warm-up for pose to stabilize
      if (_staticFrameCount > 30) {
        heightSamplesPx.add(screenPoseHeightPx);
        shoulderWidthSamplesPx.add(screenShoulderWidthPx);
      }

      setState(() {
        _text =
            "⚡ Standing still... [${(_staticFrameCount / 90 * 100).toInt()}%]";
      });

      if (_staticFrameCount >= 90) {
        lockedHeightPx = trimmedMean(heightSamplesPx);
        lockedShoulderWidthPx = trimmedMean(shoulderWidthSamplesPx);
        if (_calibratedHeightCm != null &&
            lockedHeightPx != null &&
            lockedHeightPx! > 0) {
          cmPerPixel =
              (_calibratedHeightCm! / HEIGHT_CORRECTION_FACTOR) / lockedHeightPx!;
        } else {
          cmPerPixel = guideRealHeightCm / _guideHeightPx;
        }
        setState(() {
          currentPhase = ScanPhase.readyToRotate;
          _text = "✅ Ready! Tap • Record to start 360° scan.";
        });
      }
    }
    // ── PHASE 3: Ready to Rotate ──────────────────────────────────────
    else if (currentPhase == ScanPhase.readyToRotate) {
      // Maintain instruction if person is still in frame
      if (_text != "✅ Ready! Tap • Record to start 360° scan.") {
        setState(() => _text = "✅ Ready! Tap • Record to start 360° scan.");
      }
    }
  }

  void _logFrameDiagnostics(String stage) {
    if (!Platform.isAndroid || currentPhase != ScanPhase.rotation) return;

    final callbackDelta = _cameraCallbackCount - _lastPoseDiagCallbackCount;
    final processedDelta = _frameCount - _lastPoseDiagFrameCount;
    final validDelta = _rotationValidFrameCount - _lastPoseDiagValidCount;
    final paintedDelta = _frameCount - _lastPoseDiagPaintedCount;

    final shouldLog = switch (stage) {
      'busy_reset' => true,
      'paint' => paintedDelta >= 10 || _frameCount <= 3,
      'processed' => processedDelta >= 10 || _frameCount <= 3,
      'valid_front' || 'valid_side' || 'valid_oblique' =>
        validDelta >= 10 || _rotationValidFrameCount <= 3,
      'callback' => callbackDelta >= 15 || _cameraCallbackCount <= 3,
      _ => false,
    };

    if (!shouldLog) return;

    if (stage == 'callback') {
      _lastPoseDiagCallbackCount = _cameraCallbackCount;
    } else if (stage == 'processed') {
      _lastPoseDiagFrameCount = _frameCount;
    } else if (stage == 'paint') {
      _lastPoseDiagPaintedCount = _frameCount;
    } else if (stage.startsWith('valid_')) {
      _lastPoseDiagValidCount = _rotationValidFrameCount;
    }

    debugPrint(
      'FrameDiag pose: stage=$stage '
      'callbacks=$_cameraCallbackCount '
      'processed=$_frameCount '
      'valid=$_rotationValidFrameCount '
      'busy=$_isBusy '
      'pending=${_pendingInputImage != null}',
    );
  }
}

// ── Guide box painter ──────────────────────────────────────────────────────

class _GuideBoxPainter extends CustomPainter {
  final double guideTopY;
  final double guideBottomY;
  final double guideWidthPx;
  final double screenWidth;
  final bool isAligned;

  _GuideBoxPainter({
    required this.guideTopY,
    required this.guideBottomY,
    required this.guideWidthPx,
    required this.screenWidth,
    required this.isAligned,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = screenWidth / 2;
    final boxRect = Rect.fromLTRB(
      cx - guideWidthPx / 2,
      guideTopY,
      cx + guideWidthPx / 2,
      guideBottomY,
    );

    // Dashed border paint
    final borderPaint = Paint()
      ..color = isAligned ? const Color(0xFF31B46E) : Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = isAligned ? 3.0 : 2.0;

    // Draw corner brackets instead of full rectangle for premium look
    final cornerLen = guideWidthPx * 0.15;
    _drawCornerBracket(canvas, boxRect.topLeft, cornerLen, 1, 1, borderPaint);
    _drawCornerBracket(canvas, boxRect.topRight, cornerLen, -1, 1, borderPaint);
    _drawCornerBracket(
      canvas,
      boxRect.bottomLeft,
      cornerLen,
      1,
      -1,
      borderPaint,
    );
    _drawCornerBracket(
      canvas,
      boxRect.bottomRight,
      cornerLen,
      -1,
      -1,
      borderPaint,
    );

    // Center guide line (head position)
    final headY = guideTopY + (guideBottomY - guideTopY) * 0.05;
    _drawDashedLine(
      canvas,
      Offset(cx - 20, headY),
      Offset(cx + 20, headY),
      borderPaint..color = isAligned ? const Color(0xFF31B46E) : Colors.white38,
    );
  }

  void _drawCornerBracket(
    Canvas canvas,
    Offset corner,
    double len,
    double dx,
    double dy,
    Paint paint,
  ) {
    canvas.drawLine(corner, corner + Offset(len * dx, 0), paint);
    canvas.drawLine(corner, corner + Offset(0, len * dy), paint);
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    canvas.drawLine(p1, p2, paint);
  }

  @override
  bool shouldRepaint(_GuideBoxPainter old) => old.isAligned != isAligned;
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    required this.padding,
    required this.decoration,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BoxDecoration decoration;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: decoration.copyWith(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _LocalEstimate {
  const _LocalEstimate({
    required this.cmPerPixel,
    required this.heightPx,
    required this.shoulderWidthPx,
    required this.maxBodyAreaPx,
    required this.depthPx,
    required this.heightCm,
    required this.widthM,
    required this.depthM,
    required this.weightKg,
    required this.bmi,
  });

  final double cmPerPixel;
  final double heightPx;
  final double shoulderWidthPx;
  final double maxBodyAreaPx;
  final double depthPx;
  final double heightCm;
  final double widthM;
  final double depthM;
  final double weightKg;
  final double bmi;
}

class _QualityBreakdown {
  const _QualityBreakdown({
    required this.coverageScore,
    required this.stabilityScore,
    required this.completenessScore,
    required this.finalScore,
  });

  final double coverageScore;
  final double stabilityScore;
  final double completenessScore;
  final double finalScore;
}
