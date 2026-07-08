import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String hmac(String key, String nonce) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(nonce)).toString();

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

Map<String, dynamic> leaderHandleLease(String leaderKey, String leaderId, String electedLeader,
    Map<String, dynamic> msg, Map<String, dynamic> Function(int, String, bool) grantFn) {
  final nonce = msg['nonce']?.toString() ?? '';
  final got = msg['proof']?.toString() ?? '';
  if (nonce.isEmpty || !constantTimeEquals(got, hmac(leaderKey, nonce))) {
    return {'_dropped': true};
  }
  final tableId = msg['table_id'];
  final claimant = msg['claimant']?.toString();
  if (tableId is! int || claimant == null || claimant.isEmpty) {
    return {'type': 'lease_result', 'ok': false, 'reason': 'bad_request', 'proof': hmac(leaderKey, nonce)};
  }
  if (electedLeader != leaderId) {
    return {'type': 'lease_result', 'ok': false, 'reason': 'not_leader', 'leader': electedLeader, 'proof': hmac(leaderKey, nonce)};
  }
  final type = msg['type'];
  if (type == 'lease_release') {
    return {'type': 'lease_result', 'ok': true, 'released': true, 'proof': hmac(leaderKey, nonce)};
  }
  final res = grantFn(tableId, claimant, type == 'lease_renew');
  final granted = res['granted'] == true;
  return {
    'type': 'lease_result', 'ok': granted, 'owner': res['owner'], 'reason': res['reason'],
    'takeover': res['takeover'] == true, 'lease_ms': granted ? 45000 : 0, 'proof': hmac(leaderKey, nonce),
  };
}

bool clientAcceptsResult(String myKey, String nonce, Map<String, dynamic> reply) {
  if (reply['type'] != 'lease_result') return false;
  final proof = reply['proof']?.toString() ?? '';
  if (!constantTimeEquals(proof, hmac(myKey, nonce))) return false;
  return reply['ok'] == true;
}

void main() {
  const key = 'SR_test_key';
  const leaderId = 'device-leader';

  group('lease protokol — HMAC + not_leader', () {
    test('yanlis bayi (farkli key) claim -> lider DROP eder', () {
      final nonce = 'n1';
      final msg = {'type': 'lease_claim', 'nonce': nonce, 'proof': hmac('BASKA_KEY', nonce), 'table_id': 5, 'claimant': 'B'};
      final r = leaderHandleLease(key, leaderId, leaderId, msg, (t, c, rn) => {'granted': true, 'owner': c});
      expect(r['_dropped'], true);
    });
    test('proof eksik -> DROP', () {
      final msg = {'type': 'lease_claim', 'nonce': 'n1', 'table_id': 5, 'claimant': 'B'};
      final r = leaderHandleLease(key, leaderId, leaderId, msg, (t, c, rn) => {'granted': true});
      expect(r['_dropped'], true);
    });
    test('lider degilim -> not_leader (dogru lider bildirir)', () {
      final nonce = 'n1';
      final msg = {'type': 'lease_claim', 'nonce': nonce, 'proof': hmac(key, nonce), 'table_id': 5, 'claimant': 'B'};
      final r = leaderHandleLease(key, 'device-x', leaderId, msg, (t, c, rn) => {'granted': true});
      expect(r['ok'], false);
      expect(r['reason'], 'not_leader');
      expect(r['leader'], leaderId);
    });
    test('gecerli claim + lider -> grant + client kabul eder', () {
      final nonce = 'n1';
      final msg = {'type': 'lease_claim', 'nonce': nonce, 'proof': hmac(key, nonce), 'table_id': 5, 'claimant': 'B'};
      final r = leaderHandleLease(key, leaderId, leaderId, msg, (t, c, rn) => {'granted': true, 'owner': c});
      expect(r['ok'], true);
      expect(clientAcceptsResult(key, nonce, r), true);
    });
    test('deny (baska owner) -> client kabul ETMEZ', () {
      final nonce = 'n1';
      final msg = {'type': 'lease_claim', 'nonce': nonce, 'proof': hmac(key, nonce), 'table_id': 5, 'claimant': 'B'};
      final r = leaderHandleLease(key, leaderId, leaderId, msg, (t, c, rn) => {'granted': false, 'owner': 'A', 'reason': 'held'});
      expect(r['ok'], false);
      expect(clientAcceptsResult(key, nonce, r), false);
    });
    test('sahte lider cevabi (yanlis proof) -> client REDDEDER', () {
      final nonce = 'n1';
      final fake = {'type': 'lease_result', 'ok': true, 'proof': 'deadbeef'};
      expect(clientAcceptsResult(key, nonce, fake), false);
    });
    test('bad_request (table_id yok) -> deny', () {
      final nonce = 'n1';
      final msg = {'type': 'lease_claim', 'nonce': nonce, 'proof': hmac(key, nonce), 'claimant': 'B'};
      final r = leaderHandleLease(key, leaderId, leaderId, msg, (t, c, rn) => {'granted': true});
      expect(r['ok'], false);
      expect(r['reason'], 'bad_request');
    });
  });
}
