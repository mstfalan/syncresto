import 'dart:convert';

/// 6 Eyl 2026 — 401/403 SINIFLANDIRICI (Fable denetimi, Green Chef yazıcı şikayeti).
///
/// KÖK NEDEN: garson yanlış PIN girince sunucu `401 {error:'Gecersiz PIN'}` döner; eski kod
/// HER 401/403'ü "API key geçersiz/lisans pasif" sayıp `clearAllCache()` çağırıyordu →
/// `clearAllTenantData` print_queue + local_tickets + sync_queue + cached_* SİLİYORDU.
/// pos_logs 7 gün: Green Chef 52×, Aysel's 17× — 69 olayın 69'u yanlış PIN. Kuyrukta bekleyen
/// mutfak fişi o anda yok oluyordu ("hiç fiş çıkmadı").
///
/// KURAL: cache YALNIZ sunucu AÇIKÇA "API key geçersiz" (apiKeyInvalid) veya "lisans/hesap
/// pasif" (licenseInactive) dediğinde silinir. Yanlış PIN, bilinmeyen/HTML gövde (proxy,
/// Cloudflare challenge), alan eksikliği → cache KORUNUR (unknown).
///
/// Sunucu gövdeleri (6 Eyl 2026 canlı kod):
///  - panel api/pos.js:1646            401 {error:'Gecersiz PIN'}                       → wrongPin
///  - api tenantResolver.js            401 {error:'API key required', code:'MISSING_API_KEY'}
///                                     401 {error:'Invalid API key format', code:'INVALID_API_KEY_FORMAT'}
///                                     401 {error:'Invalid or expired API key', code:'INVALID_API_KEY'}
///                                     403 {error:'Restaurant account is deactivated', code:'RESTAURANT_INACTIVE'}
///  - api routes/pos/index.js          401 {error:'API key required'|'Invalid API key format'|'Invalid API key'}
///                                     403 {error:'POS license not active'}
///  - panel license-check.js           401 {error:'unauthorized'} (→ unknown, KORU) · 403 {error:'license_required', message:...}
///  - panel panel-auth.js              401 {error:'unauthorized'|'token_expired'} = panel oturumu/iç kimlik → unknown, KORU
/// Saf Dart — Flutter bağımlılığı YOK (birim testi: test/auth_failure_classifier_test.dart).
enum AuthFailureKind { wrongPin, apiKeyInvalid, licenseInactive, unknown }

class AuthFailureClassifier {
  static const Set<String> _apiKeyCodes = {
    'MISSING_API_KEY',
    'INVALID_API_KEY_FORMAT',
    'INVALID_API_KEY',
  };
  static const Set<String> _licenseCodes = {'RESTAURANT_INACTIVE'};

  static final RegExp _pinWord = RegExp(r'\bpin\b', caseSensitive: false);

  /// [statusCode] HTTP kodu, [body] Dio `response.data` (Map / String / null / başka).
  static AuthFailureKind classify(int? statusCode, dynamic body) {
    if (statusCode != 401 && statusCode != 403) return AuthFailureKind.unknown;

    String error = '';
    String code = '';
    final map = _asMap(body);
    if (map != null) {
      error = (map['error'] ?? map['message'] ?? '').toString();
      code = (map['code'] ?? '').toString();
    }

    final e = error.toLowerCase().trim();
    final c = code.toUpperCase().trim();

    // 1) Yanlış PIN — kullanıcı hatası, cihaz/lisans ile ilgisi YOK.
    if (_pinWord.hasMatch(error)) return AuthFailureKind.wrongPin;

    // 2) Açık kodlar (api tenantResolver).
    if (_licenseCodes.contains(c)) return AuthFailureKind.licenseInactive;
    if (_apiKeyCodes.contains(c)) return AuthFailureKind.apiKeyInvalid;

    // 3) Metin eşleşmeleri (kodsuz gövdeler).
    // Fable K-3 (6 Eyl): 'pasif'/'devre' gibi genel sözcükler YOK — ileride "Garson pasif" benzeri bir
    // 403 eklenirse cache silinmesin. Yalnız lisans/hesap-devre-dışı anlamı kesin olan metinler.
    if (e.contains('license') ||
        e.contains('lisans') ||
        e.contains('deactivated')) {
      return AuthFailureKind.licenseInactive;
    }
    // Fable K-3 (6 Eyl): 'unauthorized' ve 'token_expired' panel-auth.js'in panel oturumu / iç kimlik
    // yanıtlarıdır (POS key'i DEĞİL; api→panel iç kimlik bozulursa tüm cihazlar cache kaybederdi) → unknown.
    if (e.contains('api key') ||
        e.contains('apikey') ||
        e.contains('invalid or expired') ||
        e.contains('gecersiz key') ||
        e.contains('geçersiz key')) {
      return AuthFailureKind.apiKeyInvalid;
    }

    // 4) Tanınmayan gövde (HTML, boş, farklı proxy hatası) → KORU.
    return AuthFailureKind.unknown;
  }

  /// Sadece açık API-key / lisans reddinde cache silinir.
  static bool shouldWipeCache(AuthFailureKind kind) =>
      kind == AuthFailureKind.apiKeyInvalid || kind == AuthFailureKind.licenseInactive;

  /// Kullanıcıya gösterilecek kısa mesaj.
  static String userMessage(AuthFailureKind kind, int? statusCode, dynamic body) {
    switch (kind) {
      case AuthFailureKind.wrongPin:
        return 'Geçersiz PIN';
      case AuthFailureKind.apiKeyInvalid:
        return _serverError(body) ?? 'API key geçersiz veya pasif. Lütfen yöneticiyle iletişime geçin.';
      case AuthFailureKind.licenseInactive:
        return _serverError(body) ?? 'Lisans pasif. Lütfen SyncResto yöneticinize başvurun.';
      case AuthFailureKind.unknown:
        return 'Sunucu girişi reddetti (HTTP ${statusCode ?? '?'}). Lütfen tekrar deneyin.';
    }
  }

  /// Log/teşhis için gövdenin güvenli kısa özeti (HTML olsa da 120 karakter).
  static String bodySnippet(dynamic body) {
    if (body == null) return '';
    final s = body is String ? body : (body is Map ? jsonEncode(body) : body.toString());
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  static String? _serverError(dynamic body) {
    final map = _asMap(body);
    final v = map?['error'];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  static Map? _asMap(dynamic body) {
    if (body is Map) return body;
    if (body is String) {
      final t = body.trim();
      if (t.startsWith('{') && t.length < 4000) {
        try {
          final decoded = jsonDecode(t);
          if (decoded is Map) return decoded;
        } catch (_) {}
      }
    }
    return null;
  }
}
