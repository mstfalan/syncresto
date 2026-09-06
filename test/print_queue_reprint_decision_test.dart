import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/print_queue_reprint_decision.dart';

// 6 Eyl 2026 — kuyruk×popup yarisi karar mantigi (Green Chef cift fis).
void main() {
  group('PrintQueueReprintDecision.decide', () {
    test('completed -> TEKRAR BASMA', () {
      expect(PrintQueueReprintDecision.decide('completed'), ManualReprintAction.skipAlreadyPrinted);
    });
    test('printing -> bekle', () {
      expect(PrintQueueReprintDecision.decide('printing'), ManualReprintAction.waitInProgress);
    });
    test('pending -> claim ile bas', () {
      expect(PrintQueueReprintDecision.decide('pending'), ManualReprintAction.printWithClaim);
    });
    test('failed (retry tukenmis) -> claim siz bas (arka plan dokunmaz)', () {
      expect(PrintQueueReprintDecision.decide('failed'), ManualReprintAction.printWithoutClaim);
    });
    test('null / bilinmeyen -> eski davranis: bas', () {
      expect(PrintQueueReprintDecision.decide(null), ManualReprintAction.printWithoutClaim);
      expect(PrintQueueReprintDecision.decide('garip'), ManualReprintAction.printWithoutClaim);
    });
  });

  group('PrintQueueReprintDecision.isStaleClaim', () {
    final now = DateTime(2026, 9, 6, 20, 0, 0);
    test('2 dk sinir', () {
      expect(PrintQueueReprintDecision.staleClaimAfter, const Duration(minutes: 2));
      expect(PrintQueueReprintDecision.isStaleClaim(now.subtract(const Duration(seconds: 30)), now), isFalse);
      expect(PrintQueueReprintDecision.isStaleClaim(now.subtract(const Duration(minutes: 2, seconds: 1)), now), isTrue);
    });
    test('last_attempt_at yoksa stale sayilir (kilitlenme yok)', () {
      expect(PrintQueueReprintDecision.isStaleClaim(null, now), isTrue);
    });
  });
}
