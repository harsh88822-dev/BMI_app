import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class NetworkStatusOverlay extends StatefulWidget {
  const NetworkStatusOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<NetworkStatusOverlay> createState() => _NetworkStatusOverlayState();
}

class _NetworkStatusOverlayState extends State<NetworkStatusOverlay> {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<dynamic>? _subscription;
  Timer? _offlineDebounceTimer;
  Timer? _onlineHintTimer;
  bool _isOffline = false;
  bool _showOnlineRestored = false;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _subscription = _connectivity.onConnectivityChanged.listen((event) {
      _handleConnectivityChange(event);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _offlineDebounceTimer?.cancel();
    _onlineHintTimer?.cancel();
    super.dispose();
  }

  Future<void> _initConnectivity() async {
    final event = await _connectivity.checkConnectivity();
    _handleConnectivityChange(event, initial: true);
  }

  bool _isOfflineFromEvent(dynamic event) {
    if (event is ConnectivityResult) {
      return event == ConnectivityResult.none;
    }
    if (event is List<ConnectivityResult>) {
      return !event.any((result) => result != ConnectivityResult.none);
    }
    return false;
  }

  void _handleConnectivityChange(dynamic event, {bool initial = false}) {
    final nextOffline = _isOfflineFromEvent(event);
    _offlineDebounceTimer?.cancel();

    if (nextOffline) {
      if (initial) {
        if (!mounted) return;
        setState(() {
          _isOffline = true;
          _showOnlineRestored = false;
        });
        return;
      }
      _offlineDebounceTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() {
          _isOffline = true;
          _showOnlineRestored = false;
        });
      });
      return;
    }

    if (!mounted) return;
    final wasOffline = _isOffline;
    setState(() {
      _isOffline = false;
    });

    if (wasOffline) {
      setState(() {
        _showOnlineRestored = true;
      });
      _onlineHintTimer?.cancel();
      _onlineHintTimer = Timer(const Duration(milliseconds: 1800), () {
        if (!mounted) return;
        setState(() {
          _showOnlineRestored = false;
        });
      });
    } else if (!initial) {
      setState(() {
        _showOnlineRestored = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _isOffline
                    ? _StatusBanner(
                        key: const ValueKey('offline'),
                        backgroundColor: const Color(0xFF4A3836),
                        icon: Icons.wifi_off_rounded,
                        text: 'You are offline',
                        subtitle: 'Reconnect to use all features.',
                      )
                    : _showOnlineRestored
                    ? _StatusBanner(
                        key: const ValueKey('online'),
                        backgroundColor: const Color(0xFF2F4D42),
                        icon: Icons.wifi_rounded,
                        text: 'Connection restored',
                        subtitle: 'You are back online.',
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    super.key,
    required this.backgroundColor,
    required this.icon,
    required this.text,
    required this.subtitle,
  });

  final Color backgroundColor;
  final IconData icon;
  final String text;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.ink.withValues(alpha: 0.16),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.95), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.15,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
