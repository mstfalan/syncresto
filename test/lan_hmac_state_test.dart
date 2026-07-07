// LAN-senkron O3 (Fable) — lider state cevabı HMAC simetrisi testi. 7 Tem 2026.
// Senaryo: client nonce gönderir, lider HMAC(apiKey, nonce) proof'u ile cevap verir.
// Client _constantTimeEquals(leaderProof, _hmac(nonce)) ile doğrular.
// Kanıtlanan: (1) aynı bayi key -> proof eşleşir (masa yansır), (2) farklı bayi key
// veya sahte/eksik proof -> reddedilir (sahte cihaz masa ENJEKTE EDEMEZ).

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

// lan_sync_service._hmac birebir kopyası (izole test).
String hmac(String apiKey, String nonce) {
  return Hmac(sha256, utf8.encode(apiKey)).convert(utf8.encode(nonce)).toString();
}

// lan_sync_service._constantTimeEquals birebir kopyası.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

// _fetchLeaderTables'ın client-tarafı doğrulama mantığı: cevap kabul edilir mi?
bool clientAcceptsState(String clientApiKey, String nonce, Map<String, dynamic> reply) {
  if (reply['type'] != 'state' || reply['tables'] is! List) return false;
  final leaderProof = reply['proof']?.toString() ?? '';
  return constantTimeEquals(leaderProof, hmac(clientApiKey, nonce));
}

// Liderin state_request'e cevabı (aynı key ise proof üretir).
Map<String, dynamic> leaderStateReply(String leaderApiKey, String nonce, List tables) {
  return {'type': 'state', 'tables': tables, 'proof': hmac(leaderApiKey, nonce)};
}

void main() {
  const nonce = 'abc123nonce456def789ghij';
  final fakeTables = [
    {'ticket_number': 'FAKE-1', 'table_id': 5, 'status': 'open', 'total': 999.0}
  ];

  group('O3 — Lider state cevabı HMAC doğrulaması', () {
    test('Aynı bayi (aynı key) -> proof eşleşir, masa YANSIR', () {
      const key = 'SR_bdfea51f_8fc954e9914c6ffa2a920d6f';
      final reply = leaderStateReply(key, nonce, fakeTables);
      expect(clientAcceptsState(key, nonce, reply), isTrue);
    });

    test('Farklı bayi (farklı key) -> proof eşleşmez, masa REDDEDİLİR', () {
      const leaderKey = 'SR_aaaaaaaa_leaderkey000000000000000';
      const clientKey = 'SR_bbbbbbbb_clientkey000000000000000';
      final reply = leaderStateReply(leaderKey, nonce, fakeTables);
      expect(clientAcceptsState(clientKey, nonce, reply), isFalse);
    });

    test('Sahte cihaz (proof YOK) -> REDDEDİLİR (enjeksiyon önlenir)', () {
      const key = 'SR_bdfea51f_8fc954e9914c6ffa2a920d6f';
      final reply = {'type': 'state', 'tables': fakeTables}; // proof yok
      expect(clientAcceptsState(key, nonce, reply), isFalse);
    });

    test('Sahte cihaz (rastgele proof) -> REDDEDİLİR', () {
      const key = 'SR_bdfea51f_8fc954e9914c6ffa2a920d6f';
      final reply = {'type': 'state', 'tables': fakeTables, 'proof': 'deadbeefdeadbeef'};
      expect(clientAcceptsState(key, nonce, reply), isFalse);
    });

    test('Doğru key ama YANLIŞ nonce (replay) -> REDDEDİLİR', () {
      const key = 'SR_bdfea51f_8fc954e9914c6ffa2a920d6f';
      // Lider eski bir nonce'a proof üretmiş, client farklı nonce bekliyor.
      final reply = leaderStateReply(key, 'ESKI-NONCE-farkli-deger', fakeTables);
      expect(clientAcceptsState(key, nonce, reply), isFalse);
    });
  });

  group('constantTimeEquals — temel doğruluk', () {
    test('eşit stringler -> true', () {
      expect(constantTimeEquals('abcdef', 'abcdef'), isTrue);
    });
    test('farklı uzunluk -> false', () {
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
    });
    test('aynı uzunluk farklı içerik -> false', () {
      expect(constantTimeEquals('abcdef', 'abcdeg'), isFalse);
    });
  });
}
