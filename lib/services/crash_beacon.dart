import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_service.dart';

/// 14 Eyl 2026 — ÇÖKME SİNYALİ (Green Chef gri ekran dersi).
///
/// Normal log servisi X-API-Key ister; ayar dosyası bozulunca anahtar da gider → sunucuya TEK satır düşmez,
/// biz de her seferinde kasaya bağlanmak zorunda kalırız. Bu sınıf açılış/çökme anında
/// `POST /api/pos/crash-report` ucuna KİMLİKSİZ rapor atar: cihaz kimliği, sürüm, aşama, hata, son kırıntılar.
///
/// Denetim bulgularına karşı:
///  • Ağ kapalıyken rapor KAYBOLMAZ: gönderilemeyen rapor `crash_pending.json` dosyasına yazılır, bir sonraki
///    açılışta [flushSpool] ile tekrar denenir (elektrik kesintisinde modem de kapalı olur — asıl senaryo).
///  • Bütçe yalnız BAŞARILI raporda harcanır; deneme sayısı ayrıca sınırlı (sonsuz deneme yok).
///  • Adres sabit: yalnız `api.syncresto.com`. Yedek dosyası kurcalansa bile API anahtarı yabancı
///    sunucuya gitmez.
///  • `SR_…` anahtar maskesi TÜM metin alanlarında (mesaj, yığın izi, kırıntılar, makine adı).
class CrashBeacon {
  static const String defaultApiUrl = 'https://api.syncresto.com';

  /// Başarılı rapor bütçesi (süreç başına) ve toplam deneme sınırı.
  static const int maxSuccess = 3;
  static const int maxAttempts = 6;

  /// Açılış aşaması — hata mesajıyla birlikte gider ("nerede patladı" sorusunun cevabı).
  static String stage = 'start';

  /// Ayar dosyası bozuk/kurtarılmış mı? Onarım düğmesi YALNIZ bu doğruyken gösterilir
  /// (sağlam prefs'i silen yanlış dokunuşu önler — bkz. [PosErrorScreen]).
  static bool prefsSuspect = false;

  static final List<String> _crumbs = <String>[];
  static final Set<String> _attempted = <String>{};
  static int _sentOk = 0;
  static int _attempts = 0;
  static int _spoolAttempts = 0;
  /// Kuyruk dosyasına eşzamanlı oku-yaz kaybı olmasın diye tek sıra (flushSpool ile _kuyrugaYaz yarışırdı).
  static Future<void> _kuyrukSirasi = Future<void>.value();

  /// Test/özel taşıma: (payload, apiKey, apiUrl). null ise Dio ile gönderilir.
  @visibleForTesting
  static Future<void> Function(Map<String, dynamic> payload, String? apiKey, String apiUrl)? transport;

  static void setStage(String s) {
    stage = s;
    note('asama: $s');
  }

  static void note(String s) {
    _crumbs.add('${DateTime.now().toIso8601String().substring(11, 19)} ${_mask(s)}');
    if (_crumbs.length > 40) _crumbs.removeAt(0);
  }

  @visibleForTesting
  static void resetForTest() {
    _attempted.clear();
    _crumbs.clear();
    _sentOk = 0;
    _attempts = 0;
    _spoolAttempts = 0;
    spoolPathOverride = null;
    transport = null;
    prefsSuspect = false;
    stage = 'start';
  }

  @visibleForTesting
  static int get sentOk => _sentOk;

  /// Olay kimliği — kuyruktan tekrar gönderilen rapor sunucuda İKİNCİ KEZ yazılmaz.
  static String _eventId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

  /// Sunucu tarafı da filtreliyor ama İSTEMCİDE de maskeliyoruz: metin bu ekranda da gösteriliyor
  /// ve ağ yoksa diskteki kuyruk dosyasında bekliyor. Kırpmadan ÖNCE uygulanır (sınırda kesilen
  /// bir anahtar aksi halde desene uymayıp açıkta kalıyordu).
  static String mask(String s) => s
      .replaceAll(RegExp(r'SR_[A-Za-z0-9_-]{8,}'), '[FILTERED]')
      .replaceAll(RegExp(r'\beyJ[A-Za-z0-9._-]{20,}'), '[FILTERED]')
      .replaceAll(RegExp(r'''pin["'\s]*[:=]["'\s]*\d{3,}''', caseSensitive: false), '[FILTERED]');
  static String _mask(String s) => mask(s);
  static String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

  @visibleForTesting
  static Map<String, dynamic> buildPayload({
    required String stage,
    required String message,
    String? stack,
    required String deviceId,
    required String appVersion,
    required String platform,
    String? host,
    List<String>? tail,
  }) {
    final t = tail ?? const <String>[];
    final son = t.length > 40 ? t.sublist(t.length - 40) : t;
    return <String, dynamic>{
      'device_id': _cut(deviceId, 128),
      'app_version': _cut(appVersion, 32),
      'platform': _cut(platform, 20),
      'host': _cut(_mask(host ?? ''), 64),
      'stage': _cut(_mask(stage), 60),
      'message': _cut(_mask(message), 1000),
      'stack': _cut(_mask(stack ?? ''), 4000),
      'console_tail': son.map((l) => _cut(_mask(l), 300)).toList(),
      'local_time': DateTime.now().toIso8601String().split('.').first,
      'event_id': _eventId(),
    };
  }

  /// Yakalanmayan bir hatayı bildirir.
  static Future<void> send({required String stage, required Object error, StackTrace? stack}) =>
      _gonder(stage: stage, message: error.toString().split('\n').first, stack: stack?.toString());

  /// Hata olmayan ama sunucunun bilmesi gereken durum (ör. bozuk ayar dosyası kendi kendine onarıldı).
  static Future<void> report({required String stage, required String message}) =>
      _gonder(stage: stage, message: message, stack: null);

  static Future<void> _gonder({required String stage, required String message, String? stack}) async {
    final anahtar = '$stage|${_cut(message, 120)}';
    if (_attempted.contains(anahtar) || _sentOk >= maxSuccess || _attempts >= maxAttempts) return;
    if (_attempted.length > 200) _attempted.clear(); // haftalarca açık POS'ta sınırsız büyümesin
    _attempted.add(anahtar); // aynı hata süreç içinde bir kez denenir (döngü koruması)
    _attempts++;
    Map<String, dynamic>? payload;
    try {
      final info = await _deviceInfo();
      payload = buildPayload(
        stage: '$stage:${CrashBeacon.stage}',
        message: message,
        stack: stack,
        deviceId: info[0],
        appVersion: info[1],
        platform: info[2],
        host: _hostName(),
        tail: _crumbs,
      );
      await _teslimEt(payload);
      _sentOk++; // bütçe YALNIZ başarıda harcanır
      // Ağın AYAKTA olduğu kanıtlandı: bekleyen kuyruğu şimdi boşalt (45 sn'lik gecikmeye kalmayabilir,
      // kasiyer hata ekranında uygulamayı kapatıyor).
      unawaited(flushSpool());
    } catch (e) {
      if (kDebugMode) print('[CrashBeacon] gonderilemedi: $e');
      if (payload != null) await _kuyrugaYaz(payload); // ağ yoksa kaybolmasın
    }
  }

  static Future<void> _teslimEt(Map<String, dynamic> payload) async {
    final creds = await StorageService.readBackupCredentials()
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    final apiUrl = guvenliApiUrl(creds?['api_url']);
    await (transport ?? _post)(payload, creds?['api_key'], apiUrl);
  }

  /// Yalnız `https://api.syncresto.com` kabul edilir; aksi halde bilinen adres. Yedek dosyası
  /// kurcalansa bile API anahtarı yabancı sunucuya gitmez; sondaki eğik çizgi de temizlenir.
  @visibleForTesting
  static String guvenliApiUrl(String? stored) {
    if (stored == null || stored.trim().isEmpty) return defaultApiUrl;
    final u = Uri.tryParse(stored.trim());
    if (u == null || u.scheme != 'https' || u.host.isEmpty) return defaultApiUrl;
    // TAM eşleşme: `*.syncresto.com` yerine tek host. CF bölgesinde bir alt alan adı devralınırsa
    // (dangling CNAME) beacon anahtarı oraya taşımasın. Bu uç zaten yalnız api'de var.
    if (u.host != 'api.syncresto.com') return defaultApiUrl;
    return 'https://${u.host}';
  }

  static Future<void> _post(Map<String, dynamic> payload, String? apiKey, String apiUrl) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      headers: <String, String>{if (apiKey != null && apiKey.isNotEmpty) 'X-API-Key': apiKey},
      // 4xx = TESLİM EDİLDİ say (404 "uç yok", 400 "gövde hatalı" tekrar denemekle düzelmez).
      // Yalnız 5xx ve 429 kuyruğa girer: sunucu "sonra gel" diyor demektir.
      validateStatus: (s) => s != null && s < 500 && s != 429,
    ));
    try {
      await dio.post('$apiUrl/api/pos/crash-report', data: payload);
    } finally {
      dio.close(force: true); // POS haftalarca açık kalıyor; keep-alive havuzu birikmesin
    }
  }

  // ---------------- gönderilemeyen raporlar ----------------

  /// Test için kuyruk dosyası yolu (path_provider eklentisi birim testinde yok).
  @visibleForTesting
  static String? spoolPathOverride;

  static Future<File?> _kuyrukDosyasi() async {
    final ovr = spoolPathOverride;
    if (ovr != null) return File(ovr);
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/crash_pending.json');
    } catch (_) {
      return null;
    }
  }

  /// Kuyruk işlemlerini sıraya sokar: flushSpool okurken _kuyrugaYaz araya girip yazarsa
  /// flushSpool'un eski listesi üzerine yazması yeni raporu KAYBEDİYORDU (denetim bulgusu).
  static Future<void> _siraya(Future<void> Function() gorev) {
    final sonuc = _kuyrukSirasi.then((_) => gorev());
    _kuyrukSirasi = sonuc.then((_) {}, onError: (Object _) {});
    return sonuc;
  }

  static Future<void> _atomikYaz(File f, List<Map<String, dynamic>> list) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _kuyrugaYaz(Map<String, dynamic> payload) => _siraya(() async {
        try {
          final f = await _kuyrukDosyasi();
          if (f == null) return;
          final list = await _kuyrukOku(f);
          list.add(payload);
          while (list.length > 5) {
            list.removeAt(0);
          }
          await _atomikYaz(f, list);
        } catch (e) {
          if (kDebugMode) print('[CrashBeacon] kuyruga yazilamadi: $e');
        }
      });

  static Future<List<Map<String, dynamic>>> _kuyrukOku(File f) async {
    try {
      if (!await f.exists()) return <Map<String, dynamic>>[];
      final parsed = jsonDecode(await f.readAsString());
      if (parsed is! List) return <Map<String, dynamic>>[];
      return parsed.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[]; // bozuk kuyruk raporu engellemesin
    }
  }

  /// Açılışta (ağ toparlansın diye gecikmeli) çağrılır: önceki oturumda gönderilemeyen raporları yollar.
  /// Kendi deneme sayacı vardır — elektrik kesintisinden sonra modem kapalıyken 5 eski rapor,
  /// O AN yaşanan çökmenin bütçesini yiyordu (denetim bulgusu).
  static Future<void> flushSpool() => _siraya(() async {
        try {
          final f = await _kuyrukDosyasi();
          if (f == null || !await f.exists()) return;
          final list = await _kuyrukOku(f);
          if (list.isEmpty) {
            await f.delete();
            return;
          }
          final kalan = <Map<String, dynamic>>[];
          for (final p in list) {
            if (_spoolAttempts >= 5) {
              kalan.add(p);
              continue;
            }
            _spoolAttempts++;
            try {
              await _teslimEt(p);
            } catch (_) {
              kalan.add(p); // hâlâ ağ yok — bir sonraki açılışta tekrar
            }
          }
          if (kalan.isEmpty) {
            await f.delete();
          } else {
            await _atomikYaz(f, kalan);
          }
        } catch (e) {
          if (kDebugMode) print('[CrashBeacon] kuyruk bosaltilamadi: $e');
        }
      });

  /// [deviceId, appVersion, platform] — log_service ile aynı kaynaklar; hata olursa 'unknown'.
  static Future<List<String>> _deviceInfo() async {
    var deviceId = 'unknown';
    var version = '?';
    var platform = Platform.operatingSystem;
    try {
      final pi = await PackageInfo.fromPlatform();
      version = pi.buildNumber.isNotEmpty ? '${pi.version}+${pi.buildNumber}' : pi.version;
    } catch (_) {}
    try {
      final di = DeviceInfoPlugin();
      if (Platform.isWindows) {
        deviceId = (await di.windowsInfo).deviceId;
        platform = 'windows';
      } else if (Platform.isMacOS) {
        deviceId = (await di.macOsInfo).systemGUID ?? 'unknown';
        platform = 'macos';
      } else if (Platform.isLinux) {
        deviceId = (await di.linuxInfo).machineId ?? 'unknown';
        platform = 'linux';
      }
    } catch (_) {}
    return <String>[deviceId, version, platform];
  }

  static String _hostName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }
}
