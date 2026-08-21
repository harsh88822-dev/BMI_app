import 'package:shared_preferences/shared_preferences.dart';

class HeightCalibrationService {
  static const String _calibratedHeightKey = 'user_calibrated_height_cm';
  static const String _calibratedAtKey = 'user_height_calibrated_at';

  static Future<void> saveCalibratedHeight(double heightCm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_calibratedHeightKey, heightCm);
    await prefs.setString(_calibratedAtKey, DateTime.now().toIso8601String());
  }

  static Future<double?> getCalibratedHeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_calibratedHeightKey);
  }

  static Future<bool> hasCalibratedHeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_calibratedHeightKey);
  }

  static Future<void> clearCalibratedHeight() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_calibratedHeightKey);
    await prefs.remove(_calibratedAtKey);
  }
}
