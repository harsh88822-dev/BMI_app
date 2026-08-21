import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:gal/gal.dart';
import 'camera/camera_frame_snapshot.dart';
import 'camera/nv21_preview_converter.dart';
import 'capture_controls.dart';

class CameraView extends StatefulWidget {
  final Function(InputImage inputImage) onImage;
  final Function(InputImage inputImage)? onObjectDetectionImage;
  final CustomPainter? customPainter;
  final CameraLensDirection initialDirection;
  final Function(bool isRecording, String? path)? onRecordingStateChanged;
  final VoidCallback? onRecordingStarting;
  final Function(String info)? onDebugInfo;
  final bool isCaptureEnabled;
  final bool hideCaptureControls;
  /// Hides zoom, flip, and REC chrome for focused steps (e.g. identity video).
  final bool hideUtilityChrome;
  final VoidCallback? onRecordPressed;

  const CameraView({
    super.key,
    required this.onImage,
    required this.initialDirection,
    this.onObjectDetectionImage,
    this.customPainter,
    this.onRecordingStateChanged,
    this.onRecordingStarting,
    this.onDebugInfo,
    this.isCaptureEnabled = true,
    this.hideCaptureControls = false,
    this.hideUtilityChrome = false,
    this.onRecordPressed,
  });

  @override
  State<CameraView> createState() => CameraViewState();
}

class CameraViewState extends State<CameraView> {
  CameraController? _controller;
  int _cameraIndex = -1;
  double zoomLevel = 0.0, minZoomLevel = 0.0, maxZoomLevel = 0.0;
  bool _changingCameraLens = false;
  bool _isRecording = false;
  bool _isRecordingStarting = false;
  bool _useStreamPreview = false;
  bool _scanUsesImageStream = false;
  ui.Image? _streamPreviewImage;
  int _streamPreviewFrameSkip = 0;
  bool _streamPreviewUpdatePending = false;
  Timer? recordingTimer;
  int elapsedSeconds = 0;
  static const Color _brandBlue = Color(0xFF1243A8);
  int _lastFrameLogImageCount = 0;
  /// Process 1 of every N camera ticks on Android rotation scan.
  /// Fixed stride — process every other camera tick on Android.
  /// (Every frame was too heavy; every 3rd was too sparse for a full turn.)
  static const int _androidPoseScanFrameStride = 2;
  int _androidPoseScanStrideCounter = 0;
  bool _androidPoseFrameJobInFlight = false;

  bool get isRecordingActive =>
      _isRecording || (_controller?.value.isRecordingVideo ?? false);

  /// True while Android records video + pose via onAvailable (preview paused).
  bool get isAndroidScanRecording =>
      Platform.isAndroid && _isRecording && _useStreamPreview;

  @override
  void initState() {
    super.initState();
    _startLiveFeed();
  }

  @override
  void dispose() {
    _stopPoseOnlyStreamHeartbeat();
    _clearStreamPreview();
    _stopLiveFeed();
    super.dispose();
  }

  void _clearStreamPreview() {
    _streamPreviewImage?.dispose();
    _streamPreviewImage = null;
    _useStreamPreview = false;
    _scanUsesImageStream = false;
    _streamPreviewFrameSkip = 0;
    _streamPreviewUpdatePending = false;
  }

  bool _poseOnlyScanActive = false;
  DateTime? _androidPoseFrameJobStartedAt;
  /// Last camera tick that reached pose delivery during pose-only scan.
  int _lastPoseOnlyDeliveredTick = 0;
  DateTime? _lastPoseOnlyFrameAt;
  Timer? _poseOnlyStreamHeartbeat;
  bool _poseOnlyStreamRestartInFlight = false;

  bool get isPoseOnlyScanActive => _poseOnlyScanActive;

  /// Clear pose-only mode (call on abort/retake as well as after scan).
  void endPoseOnlyScan() {
    _endPoseOnlyScan();
  }

  /// Mark pose-only scan without restarting the camera (used when video
  /// recording with onAvailable will deliver frames).
  void markPoseOnlyScan() {
    _poseOnlyScanActive = true;
    _androidPoseScanStrideCounter = 0;
    _androidPoseFrameJobInFlight = false;
    _androidPoseFrameJobStartedAt = null;
    _lastPoseOnlyDeliveredTick = _totalImageCount;
    _lastPoseOnlyFrameAt = DateTime.now();
    _useStreamPreview = true;
    _scanUsesImageStream = true;
  }

  /// Mark pose-only scan and ensure the image stream is alive.
  /// After a previous upload-clip recording, CameraX often leaves the stream dead.
  /// IMPORTANT: always force-restart — `isStreamingImages == true` can be a
  /// zombie stream that no longer delivers frames (skeleton freezes, valid=0).
  Future<void> prepareForPoseOnlyScan() async {
    _poseOnlyScanActive = true;
    _androidPoseScanStrideCounter = 0;
    _androidPoseFrameJobInFlight = false;
    _androidPoseFrameJobStartedAt = null;
    _lastPoseOnlyDeliveredTick = _totalImageCount;
    _lastPoseOnlyFrameAt = DateTime.now();
    _useStreamPreview = false;
    final controller = _controller;
    debugPrint(
      'prepareForPoseOnlyScan: '
      '(streaming=${controller?.value.isStreamingImages}, '
      'recording=${controller?.value.isRecordingVideo})',
    );
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isRecordingVideo) {
      debugPrint('prepareForPoseOnlyScan: skipped — video recording active');
      return;
    }
    await _forceRestartImageStream(reason: 'prepare_pose_only');
    _startPoseOnlyStreamHeartbeat();
  }

  void _endPoseOnlyScan() {
    _stopPoseOnlyStreamHeartbeat();
    _poseOnlyScanActive = false;
    _androidPoseScanStrideCounter = 0;
    _androidPoseFrameJobInFlight = false;
    _androidPoseFrameJobStartedAt = null;
    _poseOnlyStreamRestartInFlight = false;
  }

  void _startPoseOnlyStreamHeartbeat() {
    _poseOnlyStreamHeartbeat?.cancel();
    _poseOnlyStreamHeartbeat = Timer.periodic(const Duration(milliseconds: 1500), (
      _,
    ) {
      if (!_poseOnlyScanActive || !mounted) {
        _stopPoseOnlyStreamHeartbeat();
        return;
      }
      if (_controller?.value.isRecordingVideo ?? false) {
        return;
      }
      final last = _lastPoseOnlyFrameAt;
      if (last == null) return;
      final silence = DateTime.now().difference(last);
      if (silence >= const Duration(milliseconds: 1500)) {
        debugPrint(
          'PoseOnly heartbeat: no frames for ${silence.inMilliseconds}ms '
          '(tick=$_totalImageCount delivered=$_lastPoseOnlyDeliveredTick) '
          '— force restarting image stream',
        );
        unawaited(_forceRestartImageStream(reason: 'pose_only_heartbeat'));
      }
    });
  }

  void _stopPoseOnlyStreamHeartbeat() {
    _poseOnlyStreamHeartbeat?.cancel();
    _poseOnlyStreamHeartbeat = null;
  }

  /// Stop+start image stream. Clears packing lock so mid-scan freezes recover.
  Future<void> _forceRestartImageStream({required String reason}) async {
    if (_poseOnlyStreamRestartInFlight) {
      debugPrint('_forceRestartImageStream skipped (already in flight): $reason');
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isRecordingVideo) return;

    _poseOnlyStreamRestartInFlight = true;
    _androidPoseFrameJobInFlight = false;
    _androidPoseFrameJobStartedAt = null;
    debugPrint('_forceRestartImageStream: $reason '
        '(wasStreaming=${controller.value.isStreamingImages})');
    try {
      if (controller.value.isPreviewPaused) {
        try {
          await controller.resumePreview();
        } catch (_) {}
      }
      if (controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream();
        } catch (e) {
          debugPrint('_forceRestartImageStream stop failed: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await controller.startImageStream(_processCameraImage);
      _lastPoseOnlyFrameAt = DateTime.now();
      debugPrint('_forceRestartImageStream OK: $reason');
    } catch (e) {
      debugPrint('_forceRestartImageStream failed ($reason): $e');
    } finally {
      _poseOnlyStreamRestartInFlight = false;
    }
  }

  /// Restart the image stream without touching preview/recording state.
  /// Used when CameraX stops delivering frames mid Android pose-only scan.
  Future<void> nudgeImageStreamDuringPoseScan() async {
    if (!_poseOnlyScanActive) return;
    await _forceRestartImageStream(reason: 'nudge_pose_only');
  }

  Future<void> _resetImageStreamAfterScan() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.stopImageStream();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 100));
    if (controller.value.isPreviewPaused) {
      try {
        await controller.resumePreview();
      } catch (_) {}
    }
    try {
      await controller.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('_resetImageStreamAfterScan failed: $e');
    }
  }

  Widget _buildCameraFeed() {
    if (_changingCameraLens) {
      return const Center(
        child: Text(
          'Changing camera lens',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    // On Android, CameraPreview freezes once video+pose recording starts.
    // Paint the same NV21 frames we already receive for ML Kit.
    if (Platform.isAndroid &&
        _useStreamPreview &&
        _streamPreviewImage != null &&
        _controller != null) {
      return Nv21PreviewConverter.buildPreview(
        image: _streamPreviewImage!,
        controller: _controller!,
      );
    }

    return CameraPreview(_controller!);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: _brandBlue),
        ),
      );
    }
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(child: _buildCameraFeed()),
          if (widget.customPainter != null)
            CustomPaint(painter: widget.customPainter!),
          SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.34),
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.42),
                          ],
                          stops: const [0.0, 0.18, 0.68, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!widget.hideUtilityChrome)
                  Positioned(
                    bottom: 30,
                    left: 16,
                    right: 98,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.56),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.20),
                        ),
                      ),
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.6,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white.withValues(
                            alpha: 0.32,
                          ),
                          thumbColor: _brandBlue,
                          overlayColor: _brandBlue.withValues(alpha: 0.2),
                        ),
                        child: Slider(
                          value: zoomLevel,
                          min: minZoomLevel,
                          max: maxZoomLevel,
                          onChanged: (newSliderValue) {
                            setState(() {
                              zoomLevel = newSliderValue;
                              _controller!.setZoomLevel(zoomLevel);
                            });
                          },
                          divisions: (maxZoomLevel - 1).toInt() < 1
                              ? null
                              : (maxZoomLevel - 1).toInt(),
                        ),
                      ),
                    ),
                  ),
                if (_isRecording && !widget.hideUtilityChrome)
                  Positioned(
                    top: 18,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        'REC ${elapsedSeconds}s',
                        style: TextStyle(
                          color: elapsedSeconds.isEven
                              ? const Color(0xFFFF4D4F)
                              : const Color(0xFFFF6B6C),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (!widget.hideUtilityChrome)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _switchLiveCamera,
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.20),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Icon(
                          Platform.isIOS
                              ? Icons.flip_camera_ios_outlined
                              : Icons.flip_camera_android_outlined,
                          size: 24,
                          color: _brandBlue,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 40,
                  right: 20,
                  child: widget.hideCaptureControls
                      ? const SizedBox.shrink()
                      : CaptureControls(
                          isRecording: _isRecording,
                          isStarting: _isRecordingStarting,
                          isEnabled: _isRecording ||
                              (widget.isCaptureEnabled &&
                                  !_isRecordingStarting),
                    onRecordVideo: () {
                      if (widget.onRecordPressed != null) {
                        widget.onRecordPressed!();
                        return;
                      }
                      if (_isRecording) {
                        stopVideoRecording();
                      } else if (widget.isCaptureEnabled) {
                        startVideoRecording();
                      }
                    },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future _startLiveFeed() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    CameraDescription camera = cameras.first;
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].lensDirection == widget.initialDirection) {
        _cameraIndex = i;
        camera = cameras[i];
        break;
      }
    }
    if (_cameraIndex == -1) {
      _cameraIndex = 0;
      camera = cameras[0];
    }

    _controller = CameraController(
      camera,
      _resolutionPresetForPlatform(),
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller?.initialize();
      await _controller?.getMinZoomLevel().then((value) {
        zoomLevel = value;
        minZoomLevel = value;
      });
      await _controller?.getMaxZoomLevel().then((value) {
        maxZoomLevel = value;
      });
      if (Platform.isAndroid || Platform.isIOS) {
        await _controller?.lockCaptureOrientation(DeviceOrientation.portraitUp);
      }
      _controller?.startImageStream(_processCameraImage);
      setState(() {});
    } on CameraException catch (e) {
      debugPrint('$e');
    }
  }

  Future _stopLiveFeed() async {
    try {
      if (_controller?.value.isStreamingImages ?? false) {
        await _controller?.stopImageStream();
      }
    } catch (_) {}
    await _controller?.dispose();
    _controller = null;
  }

  Future<void> ensureImageStreamRunning() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isRecordingVideo) return;
    if (!controller.value.isStreamingImages) {
      try {
        await controller.startImageStream(_processCameraImage);
      } catch (e) {
        debugPrint('ensureImageStreamRunning failed: $e');
      }
    }
    if (controller.value.isPreviewPaused) {
      try {
        await controller.resumePreview();
      } catch (e) {
        debugPrint('ensureImageStreamRunning resumePreview failed: $e');
      }
    }
  }

  Future<void> ensurePreviewActiveDuringRecording() async {
    // Never resume native preview during Android scan recording — that
    // unbinds the recording frame stream and freezes pose/skeleton ~30 frames in.
    if (_useStreamPreview) return;
    final controller = _controller;
    if (controller == null || !_isRecording) return;
    if (controller.value.isPreviewPaused) {
      try {
        await controller.resumePreview();
      } catch (e) {
        debugPrint('ensurePreviewActiveDuringRecording failed: $e');
      }
    }
  }

  Future<void> restartImageStream() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isRecordingVideo) {
      // During Android scan recording, frames come from video onAvailable only.
      if (isAndroidScanRecording) {
        return;
      }
      debugPrint(
        'Skipping image stream restart while recording; using recording frames.',
      );
      return;
    }
    try {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }
      await _controller!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('Manual stream restart failed: $e');
    }
  }

  /// Hard reset of the camera pipeline when the image stream dies on Android.
  Future<void> reinitializeCamera() async {
    debugPrint('CameraView: reinitializeCamera()');
    try {
      await cancelActiveRecording();
    } catch (_) {}
    try {
      await _stopLiveFeed();
    } catch (e) {
      debugPrint('reinitializeCamera stop failed: $e');
    }
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    await _startLiveFeed();
  }

  Future _switchLiveCamera() async {
    setState(() => _changingCameraLens = true);
    final cameras = await availableCameras();
    _cameraIndex = (_cameraIndex + 1) % cameras.length;

    await _stopLiveFeed();

    final camera = cameras[_cameraIndex];
    _controller = CameraController(
      camera,
      _resolutionPresetForPlatform(),
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller?.initialize();
      await _controller?.getMinZoomLevel().then((value) {
        zoomLevel = value;
        minZoomLevel = value;
      });
      await _controller?.getMaxZoomLevel().then((value) {
        maxZoomLevel = value;
      });
      if (Platform.isAndroid || Platform.isIOS) {
        await _controller?.lockCaptureOrientation(DeviceOrientation.portraitUp);
      }
      _controller?.startImageStream(_processCameraImage);
      setState(() => _changingCameraLens = false);
    } on CameraException catch (e) {
      debugPrint('$e');
      setState(() => _changingCameraLens = false);
    }
  }

  Future<bool> startVideoRecording({bool keepPoseStream = true}) async {
    final CameraController? cameraController = _controller;
    if (cameraController == null ||
        !cameraController.value.isInitialized ||
        _isRecordingStarting) {
      return false;
    }

    if (cameraController.value.isRecordingVideo) {
      return true;
    }

    setState(() => _isRecordingStarting = true);
    widget.onRecordingStarting?.call();

    try {
      if (keepPoseStream) {
        _useStreamPreview = Platform.isAndroid;
        _scanUsesImageStream = Platform.isAndroid;
        if (cameraController.value.isStreamingImages) {
          await cameraController.stopImageStream();
          await Future.delayed(const Duration(milliseconds: 120));
        }
        if (cameraController.value.isPreviewPaused) {
          try {
            await cameraController.resumePreview();
          } catch (_) {}
        }
        await cameraController.startVideoRecording(
          onAvailable: _processCameraImage,
        );
        try {
          await cameraController.lockCaptureOrientation(
            DeviceOrientation.portraitUp,
          );
        } catch (_) {}
      } else {
        _clearStreamPreview();
        if (cameraController.value.isStreamingImages) {
          await cameraController.stopImageStream();
          await Future.delayed(const Duration(milliseconds: 120));
        }
        if (cameraController.value.isPreviewPaused) {
          try {
            await cameraController.resumePreview();
          } catch (_) {}
        }
        await cameraController.startVideoRecording();
      }

      if (!cameraController.value.isRecordingVideo) {
        throw CameraException(
          'recording_failed',
          'Video recording did not start',
        );
      }

      setState(() {
        _isRecording = true;
        _isRecordingStarting = false;
        elapsedSeconds = 0;
      });

      recordingTimer?.cancel();
      recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_isRecording) return;
        setState(() {
          elapsedSeconds++;
        });
      });

      widget.onRecordingStateChanged?.call(true, null);
      return true;
    } on CameraException catch (e) {
      debugPrint('Start recording failed with CameraException: $e');
      _clearStreamPreview();
      setState(() => _isRecordingStarting = false);
      if (cameraController.value.isPreviewPaused) {
        try {
          await cameraController.resumePreview();
        } catch (_) {}
      }
      if (!cameraController.value.isStreamingImages &&
          !cameraController.value.isRecordingVideo) {
        try {
          await cameraController.startImageStream(_processCameraImage);
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera Error: ${e.description ?? e.code}')),
        );
      }
      return false;
    } catch (e) {
      debugPrint('Start recording failed with unexpected error: $e');
      _clearStreamPreview();
      setState(() => _isRecordingStarting = false);
      if (cameraController.value.isPreviewPaused) {
        try {
          await cameraController.resumePreview();
        } catch (_) {}
      }
      if (!cameraController.value.isStreamingImages &&
          !cameraController.value.isRecordingVideo) {
        try {
          await cameraController.startImageStream(_processCameraImage);
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start recording.')),
        );
      }
      return false;
    }
  }

  /// Record a short upload clip after the pose scan.
  /// Hard-bounded: must return within ~12s even if CameraX misbehaves.
  Future<String?> recordUploadVideoAfterScan({required int seconds}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;

    _endPoseOnlyScan();
    final clipSeconds = seconds.clamp(8, 20);
    // Reset sticky recording flags from any prior timed-out attempt.
    _isRecordingStarting = false;

    Future<void> safeCleanup() async {
      try {
        await cancelActiveRecording()
            .timeout(const Duration(seconds: 3), onTimeout: () {});
      } catch (_) {}
      try {
        await ensureImageStreamRunning()
            .timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isRecordingStarting = false;
        });
      }
    }

    try {
      if (controller.value.isStreamingImages) {
        try {
          await controller
              .stopImageStream()
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          debugPrint('recordUploadVideoAfterScan: stopImageStream: $e');
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (controller.value.isPreviewPaused) {
        try {
          await controller.resumePreview();
        } catch (_) {}
      }

      final started = await startVideoRecording(keepPoseStream: false)
          .timeout(const Duration(seconds: 4), onTimeout: () {
        debugPrint('recordUploadVideoAfterScan: start timed out');
        _isRecordingStarting = false;
        return false;
      });
      if (!started) {
        debugPrint('recordUploadVideoAfterScan: failed to start recording');
        await safeCleanup();
        return null;
      }

      await Future.delayed(Duration(seconds: clipSeconds));

      // suppressCallback skips Gal gallery write (previously hung 40–60s).
      final path = await stopVideoRecording(suppressCallback: true)
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('recordUploadVideoAfterScan: stop timed out');
        return null;
      });

      if (path == null || path.isEmpty) {
        await safeCleanup();
        return null;
      }

      try {
        await ensureImageStreamRunning()
            .timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
      return path;
    } catch (e) {
      debugPrint('recordUploadVideoAfterScan failed: $e');
      await safeCleanup();
      return null;
    }
  }

  Future<void> cancelActiveRecording() async {
    recordingTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _clearStreamPreview();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isRecordingStarting = false;
        });
      }
      return;
    }

    try {
      if (controller.value.isRecordingVideo) {
        await controller
            .stopVideoRecording()
            .timeout(const Duration(seconds: 4));
      }
    } catch (e) {
      debugPrint('cancelActiveRecording stop failed: $e');
    }

    if (controller.value.isPreviewPaused) {
      try {
        await controller.resumePreview();
      } catch (_) {}
    }
    if (_scanUsesImageStream) {
      await _resetImageStreamAfterScan();
    } else {
      await ensureImageStreamRunning();
    }
    _clearStreamPreview();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingStarting = false;
    });
  }

  Future<String?> stopVideoRecording({bool suppressCallback = false}) async {
    final CameraController? cameraController = _controller;
    if (cameraController == null) return null;

    final shouldStop =
        _isRecording || cameraController.value.isRecordingVideo;
    if (!shouldStop) return null;

    recordingTimer?.cancel();
    String? savedPath;

    try {
      XFile? file;
      if (cameraController.value.isRecordingVideo) {
        file = await cameraController.stopVideoRecording();
        savedPath = file.path;
      } else if (_isRecording) {
        debugPrint(
          'Stop requested but camera was not recording video; resetting state.',
        );
      }

      if (cameraController.value.isPreviewPaused) {
        try {
          await cameraController.resumePreview();
        } catch (_) {}
      }

      if (_scanUsesImageStream) {
        await _resetImageStreamAfterScan();
      } else if (!cameraController.value.isRecordingVideo) {
        await ensureImageStreamRunning();
      }

      if (!mounted) return savedPath;
      _clearStreamPreview();
      setState(() {
        _isRecording = false;
        _isRecordingStarting = false;
      });
      if (!suppressCallback) {
        widget.onRecordingStateChanged?.call(false, savedPath);
      }
      if (savedPath != null && !suppressCallback) {
        debugPrint('Video recorded to $savedPath');
        try {
          final hasAccess = await Gal.hasAccess(toAlbum: true);
          if (!hasAccess) {
            await Gal.requestAccess(toAlbum: true);
          }
          await Gal.putVideo(savedPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Video saved to Gallery!')),
            );
          }
        } catch (e) {
          debugPrint('Failed to save to gallery: $e');
        }
      }
      return savedPath;
    } on CameraException catch (e) {
      debugPrint('Stop recording failed: $e');
      if (!mounted) return null;
      final needsStreamReset = _scanUsesImageStream;
      _clearStreamPreview();
      setState(() {
        _isRecording = false;
        _isRecordingStarting = false;
      });
      if (!suppressCallback) {
        widget.onRecordingStateChanged?.call(false, null);
      }
      if (needsStreamReset) {
        await _resetImageStreamAfterScan();
      } else {
        await ensureImageStreamRunning();
      }
      return null;
    } catch (e) {
      debugPrint('Stop recording failed with unexpected error: $e');
      if (!mounted) return null;
      final needsStreamReset = _scanUsesImageStream;
      _clearStreamPreview();
      setState(() {
        _isRecording = false;
        _isRecordingStarting = false;
      });
      if (!suppressCallback) {
        widget.onRecordingStateChanged?.call(false, null);
      }
      if (needsStreamReset) {
        await _resetImageStreamAfterScan();
      } else {
        await ensureImageStreamRunning();
      }
      return null;
    }
  }

  void _processCameraImage(CameraImage image) {
    _totalImageCount++;
    if (_controller == null) return;

    if (Platform.isAndroid && _poseOnlyScanActive) {
      _lastPoseOnlyFrameAt = DateTime.now();
      _androidPoseScanStrideCounter++;
      if (_androidPoseScanStrideCounter % _androidPoseScanFrameStride != 0) {
        return;
      }
      // Packing lock only — never hold this across ML Kit (that froze the
      // skeleton while valid stayed at 0). Stuck pack clears after 800ms.
      if (_androidPoseFrameJobInFlight) {
        final started = _androidPoseFrameJobStartedAt;
        if (started != null &&
            DateTime.now().difference(started) >
                const Duration(milliseconds: 800)) {
          debugPrint(
            'FrameDiag camera: packing job stuck >800ms — forcing clear '
            'tick=$_totalImageCount',
          );
          _androidPoseFrameJobInFlight = false;
          _androidPoseFrameJobStartedAt = null;
        } else {
          return;
        }
      }
      final snapshot = CameraFrameSnapshot.capture(image);
      if (snapshot == null) {
        debugPrint(
          'FrameDiag camera: snapshot_failed tick=$_totalImageCount '
          'planes=${image.planes.length}',
        );
        return;
      }
      final rotation = _rotationForImage(
        _controller!,
        imageWidth: image.width,
        imageHeight: image.height,
      );
      if (rotation == null) return;
      _androidPoseFrameJobInFlight = true;
      _androidPoseFrameJobStartedAt = DateTime.now();
      if (_totalImageCount == 1 ||
          _totalImageCount - _lastFrameLogImageCount >= 15) {
        _lastFrameLogImageCount = _totalImageCount;
        debugPrint(
          'FrameDiag camera: tick=$_totalImageCount '
          'size=${image.width}x${image.height} '
          'planes=${image.planes.length} format=${image.format.raw} '
          'rot=$rotation recording=${_controller?.value.isRecordingVideo}',
        );
      }
      if (_useStreamPreview &&
          !_streamPreviewUpdatePending &&
          image.planes.length == 1) {
        _streamPreviewFrameSkip++;
        if (_streamPreviewFrameSkip >= 3) {
          _streamPreviewFrameSkip = 0;
          _streamPreviewUpdatePending = true;
          unawaited(
            _updateStreamPreview(
              bytes: Uint8List.fromList(image.planes.first.bytes),
              width: image.width,
              height: image.height,
            ),
          );
        }
      }
      unawaited(
        _deliverAndroidPoseFrame(
          snapshot: snapshot,
          rotation: rotation,
          bytesPerRow: image.planes.length == 1
              ? image.planes.first.bytesPerRow
              : image.width,
        ),
      );
      return;
    }

    if (Platform.isAndroid &&
        (_totalImageCount == 1 || _totalImageCount - _lastFrameLogImageCount >= 15)) {
      _lastFrameLogImageCount = _totalImageCount;
      debugPrint(
        'FrameDiag camera: tick=$_totalImageCount '
        'size=${image.width}x${image.height} '
        'planes=${image.planes.length} format=${image.format.raw}',
      );
    }

    // Do not copy/convert preview frames during pose scan — that GC load was
    // stalling Galaxy M35 (SM-M356B) around ~30 frames.
    if (Platform.isAndroid && _useStreamPreview && !_poseOnlyScanActive) {
      _streamPreviewFrameSkip++;
      if (_streamPreviewFrameSkip >= 6 && !_streamPreviewUpdatePending) {
        _streamPreviewFrameSkip = 0;
        final frameCopy = Nv21PreviewConverter.copyFrameBytes(image);
        if (frameCopy != null) {
          _streamPreviewUpdatePending = true;
          unawaited(
            _updateStreamPreview(
              bytes: frameCopy,
              width: image.width,
              height: image.height,
            ),
          );
        }
      }
    }

    final inputImage = _inputImageFromCameraImage(image, _controller!);
    if (inputImage == null) {
      if (Platform.isAndroid && _poseOnlyScanActive) {
        debugPrint(
          'FrameDiag camera: dropped tick=$_totalImageCount '
          'reason=input_image_null planes=${image.planes.length} '
          'format=${image.format.raw}',
        );
      }
      if (widget.onDebugInfo != null && _totalImageCount % 30 == 0) {
        widget.onDebugInfo!('Image Error: Format/Rotation issue');
      }
      return;
    }
    if (widget.onDebugInfo != null && _totalImageCount % 30 == 0) {
      widget.onDebugInfo!('Image OK: ${image.width}x${image.height}');
    }
    widget.onImage(inputImage);
  }

  InputImageRotation? _rotationForImage(
    CameraController controller, {
    int? imageWidth,
    int? imageHeight,
  }) {
    // Portrait video buffers are already upright. Extra sensor compensation
    // made the live skeleton / person appear on their side during Step 4.
    if (Platform.isAndroid &&
        imageWidth != null &&
        imageHeight != null &&
        imageHeight >= imageWidth) {
      return InputImageRotation.rotation0deg;
    }
    final camera = controller.description;
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    var rotationCompensation =
        _orientations[controller.value.deviceOrientation];
    rotationCompensation ??= sensorOrientation;
    if (camera.lensDirection == CameraLensDirection.front) {
      rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
    } else {
      rotationCompensation =
          (sensorOrientation - rotationCompensation + 360) % 360;
    }
    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  Future<void> _deliverAndroidPoseFrame({
    required CameraFrameSnapshot snapshot,
    required InputImageRotation rotation,
    required int bytesPerRow,
  }) async {
    try {
      final copiedBytes = snapshot.singlePlane
          ? snapshot.yBytes
          : await packNv21Async(snapshot);
      // Release packing lock BEFORE ML Kit — otherwise one slow processImage
      // blocks all camera frames and the skeleton freezes.
      _androidPoseFrameJobInFlight = false;
      _androidPoseFrameJobStartedAt = null;

      if (copiedBytes == null || _controller == null) return;

      final inputImage = InputImage.fromBytes(
        bytes: copiedBytes,
        metadata: InputImageMetadata(
          size: Size(snapshot.width.toDouble(), snapshot.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: bytesPerRow,
        ),
      );
      _lastPoseOnlyDeliveredTick = _totalImageCount;
      _lastPoseOnlyFrameAt = DateTime.now();
      widget.onImage(inputImage);
    } catch (e) {
      debugPrint('FrameDiag camera: async_pack_failed $e');
      _androidPoseFrameJobInFlight = false;
      _androidPoseFrameJobStartedAt = null;
    }
  }

  Future<void> _updateStreamPreview({
    required Uint8List bytes,
    required int width,
    required int height,
  }) async {
    try {
      final next = await Nv21PreviewConverter.fromCopiedNv21(
        nv21: bytes,
        width: width,
        height: height,
      );
      if (!mounted || next == null || !_useStreamPreview) {
        next?.dispose();
        return;
      }
      final previous = _streamPreviewImage;
      _streamPreviewImage = next;
      previous?.dispose();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Stream preview update failed: $e');
    } finally {
      _streamPreviewUpdatePending = false;
    }
  }

  int _totalImageCount = 0;

  InputImage? _inputImageFromCameraImage(
    CameraImage image,
    CameraController controller,
  ) {
    final rotation = _rotationForImage(
      controller,
      imageWidth: image.width,
      imageHeight: image.height,
    );
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    if (Platform.isIOS) {
      if (format != InputImageFormat.bgra8888 || image.planes.length != 1) {
        return null;
      }
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    }

    // Non-pose-scan Android path (calibration/static phases).
    final copiedBytes = Nv21PreviewConverter.copyFrameBytes(image);
    if (copiedBytes == null) {
      if (_totalImageCount % 30 == 0) {
        debugPrint(
          'Image Error: could not copy Android frame '
          '(planes=${image.planes.length} format=$format)',
        );
      }
      return null;
    }

    final bytesPerRow = image.planes.length == 1
        ? image.planes.first.bytesPerRow
        : image.width;

    return InputImage.fromBytes(
      bytes: copiedBytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: bytesPerRow,
      ),
    );
  }

  static ResolutionPreset _resolutionPresetForPlatform() {
    // Lower resolution on Android keeps NV21 copies small enough for sustained
    // 150-frame scans without GC stalls on Galaxy M35-class devices.
    return Platform.isAndroid ? ResolutionPreset.low : ResolutionPreset.medium;
  }

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
}
