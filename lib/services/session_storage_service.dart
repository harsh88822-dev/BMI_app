import 'package:shared_preferences/shared_preferences.dart';

class SessionStorageService {
  static const String _tokenKey = 'auth_token';
  static const String _governmentIdUploadedKey = 'government_id_uploaded';

  Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey)?.trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_governmentIdUploadedKey);
  }

  Future<void> saveGovernmentIdUploaded(bool uploaded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_governmentIdUploadedKey, uploaded);
  }

  Future<bool> getGovernmentIdUploaded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_governmentIdUploadedKey) ?? false;
  }
}
