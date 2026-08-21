import 'dart:async';

import 'session_storage_service.dart';

class AuthSessionNotifier {
  AuthSessionNotifier._();

  static final AuthSessionNotifier instance = AuthSessionNotifier._();

  final _unauthorizedController = StreamController<void>.broadcast();
  final SessionStorageService _sessionStorageService = SessionStorageService();

  Stream<void> get onUnauthorized => _unauthorizedController.stream;

  Future<void> invalidateSession() async {
    await _sessionStorageService.clearToken();
    if (!_unauthorizedController.isClosed) {
      _unauthorizedController.add(null);
    }
  }
}
