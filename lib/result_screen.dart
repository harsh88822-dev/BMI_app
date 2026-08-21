import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

import 'main.dart';
import 'measurement/face_verification_state.dart';
import 'theme/app_theme.dart';
import 'widgets/bmi_loader.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({
    super.key,
    required this.videoPath,
    required this.medianHeightPx,
    required this.medianShoulderWidthPx,
    required this.maxBodyAreaPx,
    required this.cmPerPixel,
    this.showFaceMismatchWarning = false,
    this.faceMismatchMessage,
    this.onRetakeRequested,
    this.serverMeasurement,
    this.estimatedHeightCm,
    this.estimatedWeightKg,
    this.estimatedBmi,
    this.faceVerification,
  });

  final String videoPath;
  final double medianHeightPx;
  final double medianShoulderWidthPx;
  final double maxBodyAreaPx;
  final double cmPerPixel;
  final bool showFaceMismatchWarning;
  final String? faceMismatchMessage;
  final VoidCallback? onRetakeRequested;
  final Map<String, dynamic>? serverMeasurement;
  final double? estimatedHeightCm;
  final double? estimatedWeightKg;
  final double? estimatedBmi;

  /// When set (Android deferred verify), updates face banner after BMI shows.
  final ValueNotifier<FaceVerificationState>? faceVerification;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;

  double? _calibratedHeightCm;
  double? _calibratedWeightKg;
  double? _calibratedVolumeLiters;
  double? _bmi;
  double? _bmiLow;
  double? _bmiHigh;
  String _statusMessage = 'Preparing your results…';
  bool _hasValidEstimate = false;
  Map<String, dynamic>? _liveServerMeasurement;
  String? _liveVideoPath;
  bool _liveShowMismatch = false;
  String? _liveMismatchMessage;

  @override
  void initState() {
    super.initState();
    _liveShowMismatch = widget.showFaceMismatchWarning;
    _liveMismatchMessage = widget.faceMismatchMessage;
    _liveServerMeasurement = widget.serverMeasurement;
    _liveVideoPath = widget.videoPath;
    widget.faceVerification?.addListener(_onFaceVerificationChanged);
    // Compute BMI before first frame — never wait on video init, or this
    // screen stays on "Preparing your results…".
    _calculateAuto(notify: false);
    _initVideoPreview();
  }

  void _onFaceVerificationChanged() {
    final state = widget.faceVerification?.value;
    if (state == null || !mounted) return;
    final newVideo = state.videoPath;
    final shouldReloadVideo = newVideo != null &&
        newVideo.isNotEmpty &&
        newVideo != _liveVideoPath;
    setState(() {
      switch (state.phase) {
        case FaceVerificationPhase.pending:
          _statusMessage = state.message ??
              'Verifying face against your ID profile photo…';
          break;
        case FaceVerificationPhase.verified:
          _liveShowMismatch = false;
          _liveMismatchMessage = null;
          if (state.serverMeasurement != null) {
            _liveServerMeasurement = state.serverMeasurement;
          }
          _statusMessage =
              state.message ?? 'Face verified. Here is your BMI estimate';
          break;
        case FaceVerificationPhase.mismatch:
          _liveShowMismatch = true;
          _liveMismatchMessage = state.message;
          if (state.serverMeasurement != null) {
            _liveServerMeasurement = state.serverMeasurement;
          }
          _statusMessage = 'Face not verified. Showing indicative BMI only';
          break;
        case FaceVerificationPhase.unavailable:
          _liveShowMismatch = false;
          _liveMismatchMessage = state.message;
          _statusMessage = state.message ??
              'Face verification unavailable. BMI is an estimate only.';
          break;
        case FaceVerificationPhase.idle:
          break;
      }
      if (shouldReloadVideo) {
        _liveVideoPath = newVideo;
      }
    });
    if (shouldReloadVideo) {
      _reloadVideoPreview(newVideo);
    }
    if (state.phase == FaceVerificationPhase.verified ||
        state.phase == FaceVerificationPhase.mismatch) {
      _calculateAuto();
    }
  }

  double _portraitSafeAspect(double ratio) {
    if (!ratio.isFinite || ratio <= 0) return 9 / 16;
    // Recorded 360 is portrait; a landscape ratio crops to legs-only.
    if (ratio > 1) return 1 / ratio;
    return ratio;
  }

  void _initVideoPreview() {
    final path = _liveVideoPath ?? '';
    if (path.isEmpty) return;
    final controller = VideoPlayerController.file(File(path));
    _videoController = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: controller,
          autoPlay: true,
          looping: true,
          aspectRatio: _portraitSafeAspect(controller.value.aspectRatio),
        );
      });
    });
  }

  void _reloadVideoPreview(String path) {
    try {
      _chewieController?.dispose();
      _videoController?.dispose();
    } catch (_) {}
    final controller = VideoPlayerController.file(File(path));
    _videoController = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: controller,
          autoPlay: false,
          looping: true,
          aspectRatio: _portraitSafeAspect(controller.value.aspectRatio),
        );
      });
    });
  }

  @override
  void dispose() {
    widget.faceVerification?.removeListener(_onFaceVerificationChanged);
    widget.faceVerification?.dispose();
    _videoController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  void _calculateAuto({bool notify = true}) {
    void apply(VoidCallback updates) {
      updates();
      if (notify && mounted) setState(() {});
    }

    final serverBmi = _toDouble(_serverValue('estimated_bmi'));
    final serverHeightCm = _toDouble(_serverValue('height_detected'));
    final serverWeightKg = _toDouble(
      _serverValue('weight_estimated') ?? _serverValue('weigt_estimated'),
    );
    final hasValidServerEstimate =
        serverBmi != null &&
        serverHeightCm != null &&
        serverWeightKg != null &&
        serverBmi.isFinite &&
        serverHeightCm.isFinite &&
        serverWeightKg.isFinite &&
        serverHeightCm > 0 &&
        serverWeightKg > 0 &&
        serverBmi > 0;
    if (hasValidServerEstimate) {
      final displayBmi = double.parse(serverBmi.toStringAsFixed(1));
      final displayWeight = double.parse(serverWeightKg.toStringAsFixed(1));
      final p = MEASUREMENT_UNCERTAINTY_MAX_PCT;
      apply(() {
        _hasValidEstimate = true;
        _calibratedHeightCm = serverHeightCm;
        _calibratedWeightKg = displayWeight;
        _calibratedVolumeLiters = null;
        _bmi = displayBmi;
        _bmiLow = displayBmi * (1 - p);
        _bmiHigh = displayBmi * (1 + p);
        _statusMessage = _liveShowMismatch
            ? 'Face not verified. Showing indicative BMI only'
            : 'Face verified. Here is your BMI estimate';
      });
      return;
    }

    final localHeightCm = widget.estimatedHeightCm;
    final localWeightKg = widget.estimatedWeightKg;
    final localBmi = widget.estimatedBmi;
    final hasValidLocalEstimate =
        localHeightCm != null &&
        localWeightKg != null &&
        localBmi != null &&
        localHeightCm.isFinite &&
        localWeightKg.isFinite &&
        localBmi.isFinite &&
        localHeightCm > 0 &&
        localWeightKg > 0 &&
        localBmi > 0;
    if (hasValidLocalEstimate) {
      final displayBmi = double.parse(localBmi.toStringAsFixed(1));
      final displayWeight = double.parse(localWeightKg.toStringAsFixed(1));
      final p = MEASUREMENT_UNCERTAINTY_MAX_PCT;
      apply(() {
        _hasValidEstimate = true;
        _calibratedHeightCm = localHeightCm;
        _calibratedWeightKg = displayWeight;
        _calibratedVolumeLiters = null;
        _bmi = displayBmi;
        _bmiLow = displayBmi * (1 - p);
        _bmiHigh = displayBmi * (1 + p);
        final verifying = widget.faceVerification?.value.phase ==
            FaceVerificationPhase.pending;
        if (verifying) {
          _statusMessage =
              'Verifying face against your ID profile photo…';
        } else if (_liveShowMismatch) {
          _statusMessage = 'Face not verified. Showing indicative BMI only';
        } else if (_statusMessage.contains('Face verified') ||
            _statusMessage.contains('unavailable')) {
          // keep
        } else {
          _statusMessage = 'Here is your BMI estimate from the captured scan';
        }
      });
      return;
    }

    apply(() {
      _hasValidEstimate = false;
      _bmi = null;
      _bmiLow = null;
      _bmiHigh = null;
      _calibratedHeightCm = null;
      _calibratedWeightKg = null;
      _calibratedVolumeLiters = null;
      _statusMessage =
          'We could not estimate your metrics from this recording. '
          'Stand fully inside the guide, complete the capture, and try again.';
    });
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  dynamic _serverValue(String key) {
    final measurement = _liveServerMeasurement ?? widget.serverMeasurement;
    if (measurement == null) return null;
    final direct = measurement[key];
    if (direct != null) return direct;
    for (final nestedKey in const ['measurement', 'result', 'bmi', 'record']) {
      final nested = measurement[nestedKey];
      if (nested is Map && nested[key] != null) return nested[key];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Your results'), centerTitle: false),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth >= 600 ? 520.0 : double.infinity;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _videoSection(context),
                    const SizedBox(height: 22),
                    _accuracyBanner(context),
                    if (_liveShowMismatch) ...[
                      const SizedBox(height: 12),
                      _faceMismatchBanner(context),
                    ] else if (widget.faceVerification?.value.phase ==
                            FaceVerificationPhase.pending ||
                        (_statusMessage.contains('Verifying face'))) ...[
                      const SizedBox(height: 12),
                      _facePendingBanner(context),
                    ] else if (widget.faceVerification?.value.phase ==
                        FaceVerificationPhase.unavailable) ...[
                      const SizedBox(height: 12),
                      _faceUnavailableBanner(context),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_hasValidEstimate &&
                        _bmi != null &&
                        _calibratedHeightCm != null &&
                        _calibratedWeightKg != null) ...[
                      _bmiHeroCard(context),
                      const SizedBox(height: 14),
                      _metricsCard(context),
                      const SizedBox(height: 16),
                      Text(
                        'Based on full-body pose geometry, front/side scan coverage, and a standard body-density model. '
                        'Clinical height and weight can differ by about '
                        '±${(MEASUREMENT_UNCERTAINTY_MIN_PCT * 100).toInt()}–${(MEASUREMENT_UNCERTAINTY_MAX_PCT * 100).toInt()}%—suitable as a guide, not a diagnosis.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ] else
                      _emptyStateCard(context),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _videoSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.ink.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(
          aspectRatio: _videoController != null &&
                  _videoController!.value.isInitialized
              ? _portraitSafeAspect(_videoController!.value.aspectRatio)
              : 9 / 16,
          child: _chewieController != null &&
                  _chewieController!
                      .videoPlayerController
                      .value
                      .isInitialized
              ? Chewie(controller: _chewieController!)
              : ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Center(
                    child: (_liveVideoPath ?? '').isEmpty
                        ? Text(
                            widget.faceVerification?.value.phase ==
                                    FaceVerificationPhase.pending
                                ? 'Recording verification video…'
                                : 'Verification video unavailable',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : const BmiLoader(
                            showLabel: true,
                            label: 'Loading preview…',
                          ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _accuracyBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: scheme.primary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'These numbers are indicative—not 100% accurate. '
                'Expect roughly ±${(MEASUREMENT_UNCERTAINTY_MIN_PCT * 100).toInt()}–${(MEASUREMENT_UNCERTAINTY_MAX_PCT * 100).toInt()}% '
                'vs a scale or tape measure. Useful for tracking trends, not clinical diagnosis. '
                'This is an approximate estimation based on visual data and is not for medical use.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bmiHeroCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bmi = _bmi!;
    final bmiText = bmi.toStringAsFixed(1);
    final cat = getBMICategory(bmi);
    final catColor = _bmiColor(context, bmi);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.09),
            AppTheme.champagne.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(
          children: [
            Text(
              _liveShowMismatch
                  ? 'Estimated BMI (Unverified Face)'
                  : 'Estimated BMI',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                letterSpacing: 1.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              bmiText,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
                height: 1.05,
              ),
            ),
            if (_bmiLow != null &&
                _bmiHigh != null &&
                _bmiLow!.isFinite &&
                _bmiHigh!.isFinite)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Approx. range ±${(MEASUREMENT_UNCERTAINTY_MAX_PCT * 100).toInt()}%: '
                  '${_bmiLow!.toStringAsFixed(1)} – ${_bmiHigh!.toStringAsFixed(1)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: catColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: catColor.withValues(alpha: 0.35)),
              ),
              child: Text(
                cat,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: catColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _facePendingBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Verifying face against your ID profile photo…',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _faceUnavailableBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = widget.faceVerification?.value.message ??
        _liveMismatchMessage ??
        'Face verification could not run. BMI is an estimate only.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.4,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _faceMismatchBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = (_liveMismatchMessage?.trim().isNotEmpty ?? false)
        ? _liveMismatchMessage!
        : (widget.faceMismatchMessage?.trim().isNotEmpty ?? false)
            ? widget.faceMismatchMessage!
            : 'Your profile face did not match this video. These BMI numbers are '
                'not the actual profile person and should be treated as unverified.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.error.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: scheme.error,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Face mismatch detected',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.onRetakeRequested != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () {
                    widget.onRetakeRequested!.call();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('Retake scan'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricsCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = _calibratedHeightCm!;
    final w = _calibratedWeightKg!;
    final weightText = w.toStringAsFixed(1);
    final heightText = h.toStringAsFixed(0);
    final bmi = _bmi!;
    final bmiText = bmi.toStringAsFixed(1);
    final vol = _calibratedVolumeLiters;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.ink.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Estimated BMI',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              bmiText,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Category: ${getBMICategory(bmi)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Height: $heightText cm',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              'Weight: $weightText kg',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(
              'Breakdown',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            _metricRow(
              context,
              icon: Icons.height_rounded,
              label: 'Height',
              child: _bandedValue(context, double.parse(heightText), 'cm'),
            ),
            const Divider(height: 28),
            _metricRow(
              context,
              icon: Icons.monitor_weight_outlined,
              label: 'Weight',
              child: _bandedValue(context, double.parse(weightText), 'kg'),
            ),
            if (vol != null) ...[
              const Divider(height: 28),
              _metricRow(
                context,
                icon: Icons.view_in_ar_outlined,
                label: 'Volume (model)',
                child: Text(
                  '${vol.toStringAsFixed(1)} L',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: scheme.primary, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              child,
            ],
          ),
        ),
      ],
    );
  }

  Widget _bandedValue(BuildContext context, double value, String unit) {
    final scheme = Theme.of(context).colorScheme;
    final p = MEASUREMENT_UNCERTAINTY_MAX_PCT;
    final low = value * (1 - p);
    final high = value * (1 + p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${value.toStringAsFixed(1)} $unit',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '±${(p * 100).toInt()}% band: ${low.toStringAsFixed(1)}–${high.toStringAsFixed(1)} $unit',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _emptyStateCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.center_focus_weak_rounded,
              size: 40,
              color: scheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              'No estimate to show yet',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Complete a scan with your full body visible in the guide frame for height, weight, and BMI estimates.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _bmiColor(BuildContext context, double bmi) {
    final scheme = Theme.of(context).colorScheme;
    if (bmi < 18.5) return scheme.primary;
    if (bmi < 24.9) return const Color(0xFF2A6B4A);
    if (bmi < 29.9) return AppTheme.champagne;
    return scheme.error;
  }

  String getBMICategory(double bmi) {
    if (bmi < 18.5) return 'Underweight';
    if (bmi < 24.9) return 'Normal';
    if (bmi < 29.9) return 'Overweight';
    return 'Obese';
  }
}
