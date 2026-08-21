import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushTokenService {
  Future<String?> getFirebaseToken() async {
    try {
      // On iOS, notification permission + APNs registration are required
      // before an FCM token can be issued.
      if (Platform.isIOS) {
        final settings = await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        if (settings.authorizationStatus == AuthorizationStatus.denied) {
          debugPrint('PushTokenService: notification permission denied');
          return null;
        }

        // Wait briefly for APNs token after AppDelegate registers.
        String? apnsToken;
        for (var i = 0; i < 10; i++) {
          apnsToken = await FirebaseMessaging.instance.getAPNSToken();
          if (apnsToken != null && apnsToken.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (apnsToken == null || apnsToken.isEmpty) {
          debugPrint('PushTokenService: APNs token not ready yet');
        }
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.trim().isEmpty) return null;
      return token.trim();
    } catch (e) {
      debugPrint('PushTokenService: token fetch failed: $e');
      return null;
    }
  }

  String get platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }
}
