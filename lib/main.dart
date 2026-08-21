import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';

import 'auth/auth_flow.dart';
import 'measurement/measurement_prep_screen.dart';
import 'onboarding/authenticated_root.dart';
import 'services/auth_api_service.dart';
import 'services/auth_session_notifier.dart';
import 'services/push_token_service.dart';
import 'services/session_storage_service.dart';
import 'theme/app_theme.dart';
import 'widgets/bmi_loader.dart';
import 'widgets/network_status_overlay.dart';

const double CUBE_REAL_HEIGHT_CM = 30.0;
const int REQUIRED_FRAMES = 150;
/// Android mid-range devices use frame-skipping during rotation scan, so fewer
/// valid pose frames are collected in the same wall-clock window as iOS.
const int ANDROID_REQUIRED_VALID_FRAMES = 48;
/// Soft-complete / usable-scan floor when the turn stalls mid-scan.
/// Keep this high enough that a half-turn cannot finish early.
const int ANDROID_MIN_USABLE_VALID_FRAMES = 20;
/// Shared with iOS soft-complete (half-turn must not finish early).
const int IOS_MIN_USABLE_VALID_FRAMES = 24;
/// Slow 360° takes ~12s. Frame target 48 hits in ~3s at 15 pose fps.
const int ANDROID_MIN_SCAN_SECONDS = 12;
/// iOS ML Kit is faster; still require a real full-circle window.
const int IOS_MIN_SCAN_SECONDS = 12;
/// iOS happy-path valid-frame target (was 150 → always hit duration cap).
const int IOS_REQUIRED_VALID_FRAMES = 60;
const double MAX_HEIGHT_VARIANCE = 0.03;
const double MAX_CUBE_VARIANCE = 0.02;
const double HUMAN_DENSITY = 0.00101;
/// Chest depth / chest width. Side-view shoulder span is a depth proxy.
const double BODY_DEPTH_RATIO = 0.57;
/// Rectangular pose box → body volume.
const double BODY_SHAPE_FACTOR = 0.72;
/// Pose shoulder landmarks sit inside the chest envelope.
const double SHOULDER_TO_TORSO_WIDTH = 1.12;
/// Pose-only scans (no silhouette): small field-tuned nudge (~+6%).
const double POSE_WEIGHT_CALIBRATION = 1.06;
/// Saved AR height: minor crown/toe compensation on final BMI (~+2%).
const double HEIGHT_RESULT_CALIBRATION = 1.02;
// Pose landmarks miss crown of head & toe tip → multiply computed height by this
const double HEIGHT_CORRECTION_FACTOR = 1.10;

/// Product tolerance: pose-based height and weight vs ground truth may differ.
/// Typical expectation **±2%**; **up to ±5%** is accepted for average BMI reporting.
const double MEASUREMENT_UNCERTAINTY_MIN_PCT = 0.02;
const double MEASUREMENT_UNCERTAINTY_MAX_PCT = 0.05;

/// Scan recording caps (seconds) used to bound video size.
/// Android needs a longer window because pose frames are throttled (~1/2–1/3).
const int ROTATION_MAX_SECONDS_LOW_TIER = 20;
const int ROTATION_MAX_SECONDS_HIGH_TIER = 22;
const int ROTATION_MAX_SECONDS_ANDROID = 28;

/// Camera vertical FOV bounds used when reading native intrinsics.
const double DEFAULT_CAMERA_VFOV_DEGREES = 60.0;
const double MIN_CAMERA_VFOV_DEGREES = 45.0;
const double MAX_CAMERA_VFOV_DEGREES = 75.0;

/// Simple screen-width heuristic to choose low/high scan duration tier.
const double HIGH_TIER_MIN_SCREEN_WIDTH_DP = 390.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureOrientationLock();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

Future<void> _configureOrientationLock() async {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return;
  final view = views.first;

  final shortestSide = view.physicalSize.shortestSide / view.devicePixelRatio;
  final isTablet = shortestSide >= 600;

  if (isTablet) {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    return;
  }

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SessionStorageService _sessionStorageService = SessionStorageService();
  final AuthApiService _authApiService = AuthApiService();
  final PushTokenService _pushTokenService = PushTokenService();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<void>? _unauthorizedSubscription;

  bool _isInitializing = true;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _unauthorizedSubscription = AuthSessionNotifier.instance.onUnauthorized
        .listen((_) {
          if (!mounted) return;
          setState(() {
            _isAuthenticated = false;
            _isInitializing = false;
          });
          _scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: const Text('Session expired. Please sign in again.'),
              backgroundColor: AppTheme.ink,
            ),
          );
        });
    _restoreSession();
  }

  @override
  void dispose() {
    _unauthorizedSubscription?.cancel();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final token = await _sessionStorageService.getToken();
    if (token != null && token.isNotEmpty) {
      try {
        await _registerFirebaseToken();
      } catch (e) {
        debugPrint('Firebase token register skipped: $e');
      }
    }
    final stillValid = await _sessionStorageService.getToken();
    if (!mounted) return;
    setState(() {
      _isAuthenticated = stillValid != null && stillValid.isNotEmpty;
      _isInitializing = false;
    });
  }

  Future<void> _onAuthenticated(String token) async {
    await _sessionStorageService.saveToken(token);
    final stored = await _sessionStorageService.getToken();
    debugPrint(
      'Auth token saved=${stored != null && stored.isNotEmpty} '
      'len=${stored?.length ?? 0}',
    );
    try {
      await _registerFirebaseToken();
    } catch (e) {
      debugPrint('Firebase token register skipped: $e');
    }
    if (!mounted) return;
    setState(() {
      _isAuthenticated = stored != null && stored.isNotEmpty;
    });
  }

  Future<void> _onLogout() async {
    await _sessionStorageService.clearToken();
    if (!mounted) return;
    setState(() {
      _isAuthenticated = false;
    });
  }

  Future<void> _registerFirebaseToken() async {
    final firebaseToken = await _pushTokenService.getFirebaseToken();
    if (firebaseToken == null || firebaseToken.isEmpty) return;
    await _authApiService.registerFirebaseToken(
      firebaseToken: firebaseToken,
      platform: _pushTokenService.platform,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'Clockwork BMI',
      theme: AppTheme.light(),
      home: NetworkStatusOverlay(
        child: _isInitializing
            ? const Scaffold(
                body: Center(
                  child: BmiLoader(
                    showLabel: true,
                    label: 'Loading Clockwork BMI...',
                  ),
                ),
              )
            : _isAuthenticated
            ? AuthenticatedRoot(onLogout: _onLogout)
            : AuthFlow(onAuthenticated: _onAuthenticated),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, required this.onLogout});

  final String title;
  final Future<void> Function() onLogout;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: () async {
              await widget.onLogout();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isTablet ? 32 : 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isTablet ? 700 : 460),
            child: Card(
              elevation: 0,
              color: const Color(0xFFF7F9FC),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: EdgeInsets.all(isTablet ? 28 : 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      'Welcome to BMI 360 Camera',
                      style: TextStyle(
                        fontSize: isTablet ? 30 : 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: isTablet ? 24 : 20),
                    Text(
                      'Please stand in a clear area.\nEnsure your full body is visible.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: isTablet ? 18 : 14),
                    ),
                    SizedBox(height: isTablet ? 40 : 32),
                    SizedBox(
                      width: isTablet ? 320 : double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          Map<Permission, PermissionStatus> statuses = await [
                            Permission.camera,
                            Permission.photos, // Needed for Gal
                          ].request();

                          if (statuses[Permission.camera]!.isGranted) {
                            if (context.mounted) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const MeasurementPrepScreen(),
                                ),
                              );
                            }
                          }
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: isTablet ? 14 : 12,
                          ),
                          child: Text(
                            'Start Measurement',
                            style: TextStyle(fontSize: isTablet ? 20 : 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
