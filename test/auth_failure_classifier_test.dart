import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/auth_failure_classifier.dart';

// 6 Eyl 2026 — 401/403 siniflandirici. Beklenen govdeler canli sunucu kodundan alindi
// (panel api/pos.js waiters/login, api tenantResolver.js, api routes/pos/index.js, panel license-check.js).
void main() {
  group('AuthFailureClassifier.classify — yanlis PIN cache SILMEZ', () {
    test('401 {error: Gecersiz PIN} -> wrongPin', () {
      expect(AuthFailureClassifier.classify(401, {'error': 'Gecersiz PIN'}), AuthFailureKind.wrongPin);
    });
    test('401 JSON string govde -> wrongPin', () {
      expect(AuthFailureClassifier.classify(401, '{"error":"Gecersiz PIN"}'), AuthFailureKind.wrongPin);
    });
    test('PIN kelimesi buyuk/kucuk harf, kelime siniri', () {
      expect(AuthFailureClassifier.classify(401, {'error': 'Geçersiz pin'}), AuthFailureKind.wrongPin);
      expect(AuthFailureClassifier.classify(401, {'error': 'Yanlış PIN kodu'}), AuthFailureKind.wrongPin);
      // "spinner" gibi icinde 'pin' gecen kelime PIN sayilmaz
      expect(AuthFailureClassifier.classify(401, {'error': 'spinner'}), AuthFailureKind.unknown);
    });
    test('wrongPin cache silmez', () {
      expect(AuthFailureClassifier.shouldWipeCache(AuthFailureKind.wrongPin), isFalse);
    });
  });

  group('AuthFailureClassifier.classify — gercek API key / lisans reddi cache SILER', () {
    test('tenantResolver kodlari', () {
      expect(AuthFailureClassifier.classify(401, {'error': 'API key required', 'code': 'MISSING_API_KEY'}), AuthFailureKind.apiKeyInvalid);
      expect(AuthFailureClassifier.classify(401, {'error': 'Invalid API key format', 'code': 'INVALID_API_KEY_FORMAT'}), AuthFailureKind.apiKeyInvalid);
      expect(AuthFailureClassifier.classify(401, {'error': 'Invalid or expired API key', 'code': 'INVALID_API_KEY'}), AuthFailureKind.apiKeyInvalid);
      expect(AuthFailureClassifier.classify(403, {'error': 'Restaurant account is deactivated', 'code': 'RESTAURANT_INACTIVE'}), AuthFailureKind.licenseInactive);
    });
    test('routes/pos/index.js metinleri (kodsuz)', () {
      expect(AuthFailureClassifier.classify(401, {'error': 'API key required'}), AuthFailureKind.apiKeyInvalid);
      expect(AuthFailureClassifier.classify(401, {'error': 'Invalid API key'}), AuthFailureKind.apiKeyInvalid);
      expect(AuthFailureClassifier.classify(403, {'error': 'POS license not active'}), AuthFailureKind.licenseInactive);
    });
    test('panel license-check 403 license_required -> licenseInactive', () {
      expect(AuthFailureClassifier.classify(403, {'error': 'license_required', 'module': 'pos', 'message': 'Bu modül için lisansınız bulunmuyor'}), AuthFailureKind.licenseInactive);
    });
    test('Lisans metni -> licenseInactive; genel pasif/devre sozcukleri SILMEZ (Fable K-3)', () {
      expect(AuthFailureClassifier.classify(403, {'error': 'Lisans pasif'}), AuthFailureKind.licenseInactive);
      expect(AuthFailureClassifier.classify(403, {'error': 'Key devre dışı'}), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(403, {'error': 'Garson pasif'}), AuthFailureKind.unknown);
    });
    test('panel-auth unauthorized / token_expired = panel oturumu -> unknown (cache KORUNUR)', () {
      expect(AuthFailureClassifier.classify(401, {'error': 'unauthorized'}), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(401, {'error': 'token_expired'}), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.shouldWipeCache(AuthFailureClassifier.classify(401, {'error': 'unauthorized'})), isFalse);
    });
    test('apiKeyInvalid ve licenseInactive cache siler', () {
      expect(AuthFailureClassifier.shouldWipeCache(AuthFailureKind.apiKeyInvalid), isTrue);
      expect(AuthFailureClassifier.shouldWipeCache(AuthFailureKind.licenseInactive), isTrue);
    });
  });

  group('AuthFailureClassifier.classify — bilinmeyen govde cache KORUR', () {
    test('Cloudflare/proxy HTML 403 -> unknown', () {
      const html = '<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>challenge</body></html>';
      expect(AuthFailureClassifier.classify(403, html), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.shouldWipeCache(AuthFailureClassifier.classify(403, html)), isFalse);
    });
    test('bos / null / sayi govde -> unknown', () {
      expect(AuthFailureClassifier.classify(401, null), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(401, ''), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(401, 42), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(401, {}), AuthFailureKind.unknown);
    });
    test('401/403 disindaki kodlar -> unknown (bu dal cagrilmaz ama guvenli)', () {
      expect(AuthFailureClassifier.classify(500, {'error': 'Invalid API key'}), AuthFailureKind.unknown);
      expect(AuthFailureClassifier.classify(null, {'error': 'Invalid API key'}), AuthFailureKind.unknown);
    });
    test('bozuk JSON string -> unknown', () {
      expect(AuthFailureClassifier.classify(401, '{"error": "Invalid API key'), AuthFailureKind.unknown);
    });
  });

  group('userMessage / bodySnippet', () {
    test('wrongPin mesaji kullaniciya net', () {
      expect(AuthFailureClassifier.userMessage(AuthFailureKind.wrongPin, 401, {'error': 'Gecersiz PIN'}), 'Geçersiz PIN');
    });
    test('apiKeyInvalid sunucu mesajini tasir', () {
      expect(AuthFailureClassifier.userMessage(AuthFailureKind.apiKeyInvalid, 401, {'error': 'Invalid API key'}), 'Invalid API key');
    });
    test('unknown HTTP kodunu soyler', () {
      expect(AuthFailureClassifier.userMessage(AuthFailureKind.unknown, 403, '<html>'), contains('403'));
    });
    test('bodySnippet 120 karakterde keser, null bos', () {
      expect(AuthFailureClassifier.bodySnippet(null), '');
      expect(AuthFailureClassifier.bodySnippet('x' * 300).length, 121);
      expect(AuthFailureClassifier.bodySnippet({'error': 'a'}), '{"error":"a"}');
    });
  });
}
