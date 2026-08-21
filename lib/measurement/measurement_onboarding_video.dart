import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays the bundled onboarding video (replace asset when you have a new file).
class MeasurementOnboardingVideo extends StatefulWidget {
  const MeasurementOnboardingVideo({super.key, required this.height});

  static const String assetPath = 'assets/videos/measurement_onboarding.mp4';

  final double height;

  @override
  State<MeasurementOnboardingVideo> createState() =>
      MeasurementOnboardingVideoState();
}

class MeasurementOnboardingVideoState extends State<MeasurementOnboardingVideo> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _showReplay = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _controller?.dispose();
    _controller = null;
    _ready = false;
    _showReplay = false;
    _error = null;
    if (mounted) setState(() {});

    final controller = VideoPlayerController.asset(
      MeasurementOnboardingVideo.assetPath,
    );
    try {
      await controller.initialize();
      await controller.setLooping(false);
      await controller.setVolume(1.0);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _ready = true;
      _error = null;
      setState(() {});
      controller.addListener(_onVideoTick);
      await controller.play();
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _error = 'Could not load video';
        _ready = false;
      });
    }
  }

  void _onVideoTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    final done =
        c.value.duration > Duration.zero &&
        c.value.position >=
            c.value.duration - const Duration(milliseconds: 250);
    if (done != _showReplay) {
      setState(() => _showReplay = done);
    }
  }

  Future<void> _replay() async {
    final c = _controller;
    if (c == null || !_ready) return;
    setState(() => _showReplay = false);
    await c.seekTo(Duration.zero);
    await c.play();
  }

  Future<void> stopPlayback() async {
    final c = _controller;
    if (c == null || !_ready) return;
    try {
      await c.setVolume(0);
      await c.pause();
    } catch (_) {}
  }

  @override
  void deactivate() {
    // Screen covered by dialog or next route — cut audio immediately.
    unawaited(stopPlayback());
    super.deactivate();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        c.setVolume(0);
        c.pause();
      } catch (_) {}
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: TextStyle(color: scheme.error)),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (!_ready || _controller == null) {
      return SizedBox(
        height: widget.height,
        child: Center(child: CircularProgressIndicator(color: scheme.primary)),
      );
    }

    final c = _controller!;
    final size = c.value.size;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            height: widget.height,
            width: double.infinity,
            child: ColoredBox(
              color: Colors.black,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: VideoPlayer(c),
                ),
              ),
            ),
          ),
          if (_showReplay)
            Material(
              color: Colors.black38,
              child: InkWell(
                onTap: _replay,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.replay_rounded, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          'Replay',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
