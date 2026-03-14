import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  // Default SyncResto colors
  static const Color _defaultPrimary = Color(0xFF2563EB);
  static const Color _defaultSecondary = Color(0xFF1D4ED8);

  Color _primaryColor = _defaultPrimary;
  Color _secondaryColor = _defaultSecondary;
  String _brandName = 'SyncResto POS';
  String? _brandLogoUrl;

  // Getters
  Color get primaryColor => _primaryColor;
  Color get secondaryColor => _secondaryColor;
  String get brandName => _brandName;
  String? get brandLogoUrl => _brandLogoUrl;

  // Gradient for backgrounds (sadece primary color'ın tonları)
  LinearGradient get backgroundGradient {
    final hsl = HSLColor.fromColor(_primaryColor);
    final darkerShade = hsl.withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [_primaryColor, darkerShade],
    );
  }

  // Parse hex color string to Color
  static Color parseColor(String? hexColor, Color defaultColor) {
    if (hexColor == null || hexColor.isEmpty) return defaultColor;

    try {
      // Remove # if present
      String hex = hexColor.replaceAll('#', '');

      // Handle 3-char hex
      if (hex.length == 3) {
        hex = hex.split('').map((c) => '$c$c').join();
      }

      // Add FF for alpha if 6-char hex
      if (hex.length == 6) {
        hex = 'FF$hex';
      }

      return Color(int.parse(hex, radix: 16));
    } catch (e) {
      return defaultColor;
    }
  }

  // Generate secondary color from primary (darker shade)
  static Color generateSecondary(Color primary) {
    final hsl = HSLColor.fromColor(primary);
    return hsl.withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0)).toColor();
  }

  // Update theme from settings API response
  void updateFromSettings(Map<String, dynamic> settings) {
    final primaryHex = settings['primary_color'] as String?;
    final secondaryHex = settings['secondary_color'] as String?;
    final name = settings['brand_name'] as String?;
    final logo = settings['brand_logo'] as String?;

    if (primaryHex != null) {
      _primaryColor = parseColor(primaryHex, _defaultPrimary);

      // If no secondary provided, generate from primary
      if (secondaryHex != null && secondaryHex.isNotEmpty) {
        _secondaryColor = parseColor(secondaryHex, _defaultSecondary);
      } else {
        _secondaryColor = generateSecondary(_primaryColor);
      }
    }

    if (name != null && name.isNotEmpty) {
      _brandName = name;
    }

    if (logo != null && logo.isNotEmpty) {
      _brandLogoUrl = logo;
    }

    // Save to local storage
    _saveToPrefs();

    notifyListeners();
  }

  // Load cached theme from SharedPreferences
  Future<void> loadCachedTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final primaryHex = prefs.getString('theme_primary_color');
      final secondaryHex = prefs.getString('theme_secondary_color');
      final name = prefs.getString('theme_brand_name');
      final logo = prefs.getString('theme_brand_logo');

      if (primaryHex != null) {
        _primaryColor = parseColor(primaryHex, _defaultPrimary);
      }
      if (secondaryHex != null) {
        _secondaryColor = parseColor(secondaryHex, _defaultSecondary);
      }
      if (name != null && name.isNotEmpty) {
        _brandName = name;
      }
      if (logo != null && logo.isNotEmpty) {
        _brandLogoUrl = logo;
      }

      notifyListeners();
    } catch (e) {
      // Ignore errors, use defaults
    }
  }

  // Save theme to SharedPreferences
  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
          'theme_primary_color', '#${_primaryColor.value.toRadixString(16).substring(2)}');
      await prefs.setString(
          'theme_secondary_color', '#${_secondaryColor.value.toRadixString(16).substring(2)}');
      await prefs.setString('theme_brand_name', _brandName);
      if (_brandLogoUrl != null) {
        await prefs.setString('theme_brand_logo', _brandLogoUrl!);
      }
    } catch (e) {
      // Ignore save errors
    }
  }

  // Reset to defaults
  void resetToDefaults() {
    _primaryColor = _defaultPrimary;
    _secondaryColor = _defaultSecondary;
    _brandName = 'SyncResto POS';
    _brandLogoUrl = null;
    notifyListeners();
  }
}
