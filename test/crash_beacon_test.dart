import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/crash_beacon.dart';
import 'package:syncresto_pos/widgets/pos_error_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CrashBeacon.resetForTest();
    CrashBeacon.transport = null;
  });

  test('buildPayload: alan sınırları, SR_ maskesi TÜM alanlarda, kuyruk son 40', () {
    final tail = List<String>.generate(60, (i) => 'satir $i anahtar SR_abcdefghijkl');
    final p = CrashBeacon.buildPayload(
      stage: 'x' * 100,
      message: 'anahtar SR_abcdefghijklmnop hata ${'m' * 2000}',
      stack: 's' * 5000,
      deviceId: 'd1',
      appVersion: '1.7.5+67',
      platform: 'windows',
      host: 'KASA-1 SR_abcdefghijkl',
      tail: tail,
    );
    expect((p['stage'] as String).length, 60);
    expect((p['message'] as String).length <= 1000, isTrue);
    expect((p['message'] as String).contains('SR_abcdefghijklmnop'), isFalse);
    expect((p['stack'] as String).length, 4000);
    expect((p['console_tail'] as List).length, 40);
    expect((p['console_tail'] as List).last.toString().contains('SR_'), isFalse);
    expect((p['host'] as String).contains('SR_'), isFalse);
    // local_time: naive TR (sunucu 'timestamp without time zone' bekliyor, Z/offset KABUL ETMEZ)
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$').hasMatch(p['local_time'] as String), isTrue);
  });

  test('guvenliApiUrl: TEK host (api.syncresto.com); kurcalanmış yedek anahtarı başka sunucuya taşıyamaz', () {
    for (final girdi in <String?>[
      null,
      '',
      'https://panel.syncresto.com/api/',      // alt alan adı devralınabilir → kabul YOK
      'https://kotu.example.com',
      'http://api.syncresto.com',              // https şart
      'https://api.syncresto.com.kotu.net',    // sonek tuzağı
      'https://api.syncresto.com@kotu.net',    // userinfo tuzağı
      'https://api.syncresto.com.',            // sondaki nokta
      '://bozuk',
    ]) {
      expect(CrashBeacon.guvenliApiUrl(girdi), CrashBeacon.defaultApiUrl, reason: 'girdi: $girdi');
    }
    expect(CrashBeacon.guvenliApiUrl('https://api.syncresto.com/'), 'https://api.syncresto.com');
    expect(CrashBeacon.guvenliApiUrl('https://kotu.net@api.syncresto.com/x'), 'https://api.syncresto.com');
  });

  test('send: aynı hata bir kez denenir, başarılı bütçe 3, aşama mesaja eklenir', () async {
    var calls = 0;
    String? lastStage;
    CrashBeacon.transport = (payload, apiKey, apiUrl) async {
      calls++;
      lastStage = payload['stage'] as String;
      expect(apiUrl, CrashBeacon.defaultApiUrl);
    };
    CrashBeacon.setStage('storage-init');
    await CrashBeacon.send(stage: 'zone', error: 'e1');
    await CrashBeacon.send(stage: 'zone', error: 'e1');
    await CrashBeacon.send(stage: 'zone', error: 'e2');
    await CrashBeacon.send(stage: 'zone', error: 'e3');
    await CrashBeacon.send(stage: 'zone', error: 'e4');
    expect(calls, 3);
    expect(CrashBeacon.sentOk, 3);
    expect(lastStage, 'zone:storage-init');
  });

  test('ağ yokken bütçe HARCANMAZ ve gönderim sonsuz denenmez', () async {
    var calls = 0;
    CrashBeacon.transport = (payload, apiKey, apiUrl) async {
      calls++;
      throw Exception('ag yok');
    };
    for (var i = 0; i < 10; i++) {
      await CrashBeacon.send(stage: 'zone', error: 'hata $i');
    }
    expect(CrashBeacon.sentOk, 0, reason: 'basarisiz gonderim butceyi harcamamali');
    expect(calls, CrashBeacon.maxAttempts, reason: 'deneme ust siniri uygulanmali');
  });

  test('ağ yokken rapor KUYRUĞA yazılır, açılışta kuyruk gönderilir, sayaçlar AYRI', () async {
    final dir = Directory.systemTemp.createTempSync('beacon');
    addTearDown(() => dir.deleteSync(recursive: true));
    CrashBeacon.spoolPathOverride = '${dir.path}/crash_pending.json';

    CrashBeacon.transport = (payload, apiKey, apiUrl) async => throw Exception('ag yok');
    await CrashBeacon.send(stage: 'zone', error: 'elektrik kesintisi hatasi');
    final f = File(CrashBeacon.spoolPathOverride!);
    expect(f.existsSync(), isTrue, reason: 'gonderilemeyen rapor kuyruga yazilmali');
    expect((jsonDecode(f.readAsStringSync()) as List).length, 1);
    expect(CrashBeacon.sentOk, 0);

    // Sonraki açılış: ağ geri geldi
    CrashBeacon.resetForTest();
    CrashBeacon.spoolPathOverride = '${dir.path}/crash_pending.json';
    var teslim = 0;
    CrashBeacon.transport = (payload, apiKey, apiUrl) async {
      teslim++;
      expect(payload['event_id'], isNotNull);
    };
    await CrashBeacon.flushSpool();
    expect(teslim, 1);
    expect(f.existsSync(), isFalse, reason: 'gonderilen kuyruk silinmeli');
    // Kuyruk denemesi taze cokmenin butcesini YEMEZ
    await CrashBeacon.send(stage: 'zone', error: 'taze cokme');
    expect(teslim, 2);
    expect(CrashBeacon.sentOk, 1);
  });

  test('kuyruk dosyası bozuksa rapor engellenmez', () async {
    final dir = Directory.systemTemp.createTempSync('beacon2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/crash_pending.json')..writeAsStringSync('}{bozuk');
    CrashBeacon.spoolPathOverride = f.path;
    CrashBeacon.transport = (payload, apiKey, apiUrl) async {};
    await CrashBeacon.flushSpool();
    expect(f.existsSync(), isFalse, reason: 'bozuk kuyruk temizlenmeli');
  });

  testWidgets('PosErrorScreen ölümcül: kapatma düğmesi VAR, "devam edin" YAZMAZ', (tester) async {
    CrashBeacon.transport = (p, k, u) async {};
    await tester.pumpWidget(PosErrorScreen(
      details: FlutterErrorDetails(exception: StateError('printerService patladi')),
      fatal: true,
    ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Uygulama açılamadı'), findsOneWidget);
    expect(find.text('Kapat'), findsOneWidget);
    expect(find.text('Ayarları onar ve kapat'), findsNothing);
    expect(find.textContaining('başka bir ekrandan'), findsNothing);
  });

  testWidgets('PosErrorScreen: ayar şüphesi YOKKEN yıkıcı düğme göstermez', (tester) async {
    CrashBeacon.transport = (p, k, u) async {};
    await tester.pumpWidget(PosErrorScreen(
      details: FlutterErrorDetails(exception: StateError('bir urun karti cizilemedi')),
    ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Bu bölüm görüntülenemedi'), findsOneWidget);
    expect(find.text('Ayarları onar ve kapat'), findsNothing);
    expect(find.text('Kapat'), findsNothing);
  });

  testWidgets('PosErrorScreen: ayar şüphesinde onarım düğmesi çıkar (MaterialApp olmadan)', (tester) async {
    CrashBeacon.transport = (p, k, u) async {};
    CrashBeacon.prefsSuspect = true;
    await tester.pumpWidget(PosErrorScreen(
      details: FlutterErrorDetails(exception: StateError('LateInitializationError: _prefs')),
    ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Uygulama açılamadı'), findsOneWidget);
    expect(find.text('Ayarları onar ve kapat'), findsOneWidget);
    expect(find.textContaining('_prefs'), findsOneWidget);
  });

  testWidgets('PosErrorScreen: metin sezgisi KALDIRILDI — bayrak yoksa yıkıcı düğme YOK', (tester) async {
    // Denetim bulgusu: hata metninde '_prefs'/'SharedPreferences' geçmesi yeterliydi. Çalışan bir
    // kasada alakasız bir hata SAĞLAM ayar dosyasını sildirebiliyordu (yazıcı ayarı gider, fiş durur).
    CrashBeacon.transport = (p, k, u) async {};
    await tester.pumpWidget(PosErrorScreen(
      details: FlutterErrorDetails(exception: StateError('LateInitializationError: Field _prefs')),
    ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Bu bölüm görüntülenemedi'), findsOneWidget);
    expect(find.text('Ayarları onar ve kapat'), findsNothing);
  });

  testWidgets('PosErrorScreen: dar/kısıtsız slotta sade kutuya düşer (kendisi patlamaz)', (tester) async {
    CrashBeacon.transport = (p, k, u) async {};
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 120,
          height: 80,
          child: PosErrorScreen(details: FlutterErrorDetails(exception: StateError('kart cizilemedi'))),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Görüntülenemedi'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('mask: SR_ anahtarı, JWT ve PIN istemcide de maskelenir', () {
    expect(CrashBeacon.mask('anahtar SR_abcdefghijkl'), isNot(contains('SR_abcdefghijkl')));
    expect(CrashBeacon.mask('Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'), isNot(contains('eyJhbG')));
    expect(CrashBeacon.mask('login?pin=4821'), isNot(contains('4821')));
  });
}
