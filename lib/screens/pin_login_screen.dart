import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/local_db_service.dart';
import '../services/image_cache_service.dart';
import '../services/lan_sync_service.dart';
import '../services/connectivity_service.dart';
import '../providers/theme_provider.dart';
import 'tables_screen.dart';
import 'setup_screen.dart';
import 'printer_settings_screen.dart';

class PinLoginScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;

  const PinLoginScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
  });

  @override
  State<PinLoginScreen> createState() => _PinLoginScreenState();
}

class _PinLoginScreenState extends State<PinLoginScreen>
    with TickerProviderStateMixin {
  String _pin = '';
  bool _isLoading = false;
  String? _errorMessage;

  bool _isOnline = true;
  int _pendingSync = 0;
  int _totalTables = 0;
  int _emptyTables = 0;
  int _occupiedTables = 0;
  String _version = '';
  File? _brandLogoFile; // cache'lenmis musteri logosu (offline'da gorunur)
  bool? _logoIsLight; // logo parlakligi: true=acik/beyaz (koyu zemin), false=koyu (beyaz zemin), null=analiz bekliyor
  double? _logoAspect; // logo en/boy orani (width/height) — kutu boyutu buna gore
  StreamSubscription<bool>? _connSub;
  late final AnimationController _shakeCtrl;
  final FocusNode _kbFocus = FocusNode();

  // Rate limiting
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;
  static const int _maxAttempts = 5;
  static const int _lockoutSeconds = 60;

  bool get _isLockedOut =>
      _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);

  String get _lockoutMessage {
    if (_lockoutUntil == null) return '';
    final remaining = _lockoutUntil!.difference(DateTime.now()).inSeconds;
    return 'Cok fazla deneme. ${remaining > 0 ? remaining : 0} saniye bekleyin.';
  }

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _isOnline = widget.apiService.isOnline;
    _connSub = ConnectivityService().connectionStream.listen((online) {
      if (mounted) setState(() => _isOnline = online);
    });
    _loadPendingSync();
    _loadVersion();
    _loadBrandLogo();
    _loadTableStats();
    WidgetsBinding.instance.addPostFrameCallback((_) => _kbFocus.requestFocus());
  }

  // brand_logo API'den goreli yol donebilir (/uploads/logos/..). backend_url ile tam URL'ye cevir.
  String? _resolveLogoUrl(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    final base = widget.storageService.getBackendUrl() ?? widget.storageService.getApiUrl();
    if (base == null || base.isEmpty) return null;
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = raw.startsWith('/') ? raw : '/$raw';
    return '$b$p';
  }

  // Musteri logosunu cache'le/yukle: cache'te varsa File goster (offline calisir);
  // yoksa online iken indirip cache'le (bir dahaki acilista offline hazir).
  Future<void> _loadBrandLogo() async {
    try {
      final theme = Provider.of<ThemeProvider>(context, listen: false);
      final url = _resolveLogoUrl(theme.brandLogoUrl);
      if (url == null || url.isEmpty) return;
      final cache = ImageCacheService();
      if (!cache.isReady) await cache.init();
      // Once cache'te var mi?
      File? f = await cache.getCachedImage(url);
      // Yoksa ve online isek indir
      if (f == null && widget.apiService.isOnline) {
        final p = await cache.downloadAndCache(url);
        if (p != null) f = File(p);
      }
      if (f != null && mounted) {
        setState(() => _brandLogoFile = f);
        _analyzeLogoBrightness(f); // zemin rengi icin parlaklik analizi
      }
    } catch (_) {}
  }

  // Logo pikselerinin ortalama parlakligini + en/boy oranini olc.
  // Parlaklik: saydam haric (alpha>16). acik logo -> koyu zemin, koyu logo -> beyaz zemin.
  // Oran: kutu genisligi/yuksekligi logonun sekline gore ayarlansin (kare/dikey/yatay).
  Future<void> _analyzeLogoBrightness(File file) async {
    try {
      final bytes = await file.readAsBytes();
      // Once gercek boyut icin decode (oran), sonra kucuk ornekle (parlaklik) — tek codec yeterli.
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final aspect = img.height > 0 ? img.width / img.height : null;

      // Parlaklik icin dusuk cozunurlukte tekrar decode (hizli + az RAM).
      double? avg;
      final smallCodec = await ui.instantiateImageCodec(bytes, targetWidth: 48);
      final smallFrame = await smallCodec.getNextFrame();
      final data = await smallFrame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data != null) {
        final buf = data.buffer.asUint8List();
        double sum = 0;
        int count = 0;
        for (int i = 0; i + 3 < buf.length; i += 4) {
          final a = buf[i + 3];
          if (a < 16) continue; // saydam pikseli sayma
          sum += 0.299 * buf[i] + 0.587 * buf[i + 1] + 0.114 * buf[i + 2];
          count++;
        }
        if (count > 0) avg = sum / count;
      }

      if (mounted) {
        setState(() {
          if (aspect != null && aspect.isFinite && aspect > 0) _logoAspect = aspect;
          if (avg != null) _logoIsLight = avg > 150; // >150 -> acik logo
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _shakeCtrl.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPendingSync() async {
    try {
      final items = await LocalDbService().getPendingSyncItems();
      if (mounted) setState(() => _pendingSync = items.length);
    } catch (_) {}
  }

  // Masa özeti — cached_tables'tan (offline'da da çalışır). Boş = occupied değil + adisyon yok.
  Future<void> _loadTableStats() async {
    try {
      final tables = await LocalDbService().getCachedTables();
      final total = tables.length;
      final empty = tables.where((t) =>
          t['status'] != 'occupied' && t['current_ticket_id'] == null).length;
      if (mounted) setState(() {
        _totalTables = total;
        _emptyTables = empty;
        _occupiedTables = total - empty;
      });
    } catch (_) {}
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = 'v${info.version}');
    } catch (_) {}
  }

  void _addDigit(String digit) {
    if (_pin.length >= 4) return;

    setState(() {
      _pin += digit;
      _errorMessage = null;
    });

    if (_pin.length == 4) {
      _attemptLogin();
    }
  }

  void _deleteDigit() {
    if (_pin.isEmpty) return;

    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  void _clearPin() {
    setState(() {
      _pin = '';
      _errorMessage = null;
    });
  }

  Future<void> _attemptLogin() async {
    // Rate limiting kontrolü
    if (_isLockedOut) {
      setState(() {
        _errorMessage = _lockoutMessage;
        _pin = '';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.apiService.waiterLogin(_pin);
      if (!mounted) return;

      if (result['success'] == true) {
        // Save waiter session (token offline modda null olabilir)
        final token = result['token'] as String?;
        final waiterJson = jsonEncode(result['waiter']);

        if (token != null) {
          await widget.storageService.saveWaiterSession(token, waiterJson);
          widget.apiService.setWaiterToken(token);
        }
        _failedAttempts = 0;

        // Log artık api_service.waiterLogin içinde tutuluyor

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => TablesScreen(
                storageService: widget.storageService,
                apiService: widget.apiService,
                printerService: widget.printerService,
                webSocketService: widget.webSocketService,
                waiter: result['waiter'],
              ),
            ),
          );
        }
      } else {
        _failedAttempts++;
        if (_failedAttempts >= _maxAttempts) {
          _lockoutUntil = DateTime.now().add(const Duration(seconds: _lockoutSeconds));
          _failedAttempts = 0;
        }
        setState(() {
          _errorMessage = _isLockedOut ? _lockoutMessage : (result['error'] ?? 'Gecersiz PIN');
          _pin = '';
        });
        _shakeCtrl.forward(from: 0); // yanlis PIN -> shake
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Giris hatasi';
        _pin = '';
      });
      _shakeCtrl.forward(from: 0);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // Sag ust dişli — hizli erisim menusu (LAN ayarlari / yazici testi / API key).
  void _openSettings() {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300], borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Ayarlar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: Icon(Icons.wifi_tethering, color: theme.primaryColor),
              title: const Text('LAN Senkron Ayarları'),
              subtitle: const Text('Aynı ağdaki kasalarla masa paylaşımı'),
              onTap: () { Navigator.pop(ctx); _openLanSettings(); },
            ),
            ListTile(
              leading: Icon(Icons.print, color: theme.primaryColor),
              title: const Text('Yazıcı Ayarları'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => PrinterSettingsScreen(printerService: widget.printerService),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key, color: Color(0xFF6B7280)),
              title: const Text('API Key Değiştir'),
              onTap: () { Navigator.pop(ctx); _changeApiKey(); },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _changeApiKey() {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('API Key Degistir'),
        content: const Text('Mevcut API key silinecek. Devam etmek istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogCtx);
              await widget.storageService.clearApiKey();
              if (!mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => SetupScreen(
                    storageService: widget.storageService,
                    apiService: widget.apiService,
                    printerService: widget.printerService,
                    webSocketService: widget.webSocketService,
                  ),
                ),
              );
            },
            child: const Text('Degistir', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // LAN senkron ayarlari — flag toggle + ana-kasa rolu + canli peer listesi.
  Future<void> _openLanSettings() async {
    final lan = LanSyncService();
    bool isMain = await lan.isThisMainDevice();
    bool enabled = lan.enabled;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return AlertDialog(
              title: const Text('LAN Senkron'),
              content: StreamBuilder<List<LanPeer>>(
                stream: lan.peersStream,
                initialData: lan.peers,
                builder: (context, snap) {
                  final peers = snap.data ?? const <LanPeer>[];
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('LAN Senkronu Aç'),
                        subtitle: const Text('Aynı ağdaki kasalar birbirinin masalarını görür'),
                        value: enabled,
                        onChanged: (v) async {
                          await lan.setEnabled(v);
                          setSt(() => enabled = v);
                        },
                      ),
                      if (enabled) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Bu cihaz ANA KASA'),
                          subtitle: const Text('Ağda lider bu cihaz olsun (opsiyonel)'),
                          value: isMain,
                          onChanged: (v) async {
                            await lan.setThisMainDevice(v);
                            setSt(() => isMain = v);
                          },
                        ),
                        const Divider(),
                        Text('Ağdaki kasalar (${peers.length})',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        if (peers.isEmpty)
                          const Text('Henüz kasa bulunamadı…',
                              style: TextStyle(color: Colors.grey, fontSize: 13))
                        else
                          ...peers.map((p) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Icon(p.isMain ? Icons.star : Icons.point_of_sale,
                                        size: 16, color: p.isMain ? Colors.amber[700] : Colors.grey),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text('${p.ip}:${p.port}',
                                          style: const TextStyle(fontSize: 13)),
                                    ),
                                  ],
                                ),
                              )),
                        const Divider(),
                        // Masa kilidi (lease) durumu — peer degisiminde otomatik yenilenir.
                        FutureBuilder<Map<String, dynamic>>(
                          future: lan.leaseStatus(),
                          builder: (context, ls) {
                            final data = ls.data;
                            if (data == null) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 4),
                                child: Text('Masa kilidi durumu yükleniyor…',
                                    style: TextStyle(color: Colors.grey, fontSize: 13)),
                              );
                            }
                            final mine = (data['mine'] as List?) ?? const [];
                            final foreign = (data['foreign'] as List?) ?? const [];
                            final heldCount = (data['heldCount'] as int?) ?? 0;
                            String tbl(dynamic e) =>
                                (e['table_number'] ?? 'M${e['table_id']}').toString();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Masa Kilidi (lease)',
                                    style: TextStyle(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                Row(children: [
                                  Icon(Icons.lock, size: 15, color: Colors.green[700]),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(
                                      mine.isEmpty
                                          ? 'Bu kasada kilitli masa yok'
                                          : 'Sizde: ${mine.map(tbl).join(", ")}',
                                      style: const TextStyle(fontSize: 13))),
                                ]),
                                const SizedBox(height: 2),
                                Row(children: [
                                  Icon(Icons.lock_outline, size: 15, color: Colors.orange[800]),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(
                                      foreign.isEmpty
                                          ? 'Başka kasada kilitli masa yok'
                                          : 'Diğer kasalarda: ${foreign.map(tbl).join(", ")}',
                                      style: const TextStyle(fontSize: 13))),
                                ]),
                                if (heldCount > 0) ...[
                                  const SizedBox(height: 2),
                                  Row(children: [
                                    Icon(Icons.sync_problem, size: 15, color: Colors.blue[700]),
                                    const SizedBox(width: 6),
                                    Expanded(child: Text(
                                        'Teslim bekleyen: $heldCount kayıt (otomatik gönderilecek)',
                                        style: TextStyle(fontSize: 13, color: Colors.blue[700]))),
                                  ]),
                                ],
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  );
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Kapat'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyName = widget.storageService.getApiKeyName() ?? 'POS';
    final theme = Provider.of<ThemeProvider>(context);

    return Scaffold(
      body: RawKeyboardListener(
        focusNode: _kbFocus,
        autofocus: true,
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
              _addDigit('0');
            } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
              _addDigit('1');
            } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
              _addDigit('2');
            } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
              _addDigit('3');
            } else if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
              _addDigit('4');
            } else if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
              _addDigit('5');
            } else if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
              _addDigit('6');
            } else if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
              _addDigit('7');
            } else if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
              _addDigit('8');
            } else if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
              _addDigit('9');
            } else if (key == LogicalKeyboardKey.backspace) {
              _deleteDigit();
            } else if (key == LogicalKeyboardKey.escape) {
              _clearPin();
            }
          }
        },
        child: Stack(
          children: [
            // Tek gradient + tek balon katmani TUM ekranda (sag/sol ton farki YOK).
            Positioned.fill(
              child: Container(decoration: BoxDecoration(gradient: theme.backgroundGradient)),
            ),
            const Positioned.fill(
              child: RepaintBoundary(child: _AnimatedBackdrop()),
            ),
            // Paneller SEFFAF — altta tek zemin gorunur.
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                if (!wide) {
                  return Center(
                    child: SingleChildScrollView(child: _buildPinCard(theme, keyName)),
                  );
                }
                return Row(
                  children: [
                    Expanded(flex: 5, child: _buildBrandPanel(theme)),
                    Expanded(
                      flex: 4,
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _buildPinCard(theme, keyName),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Colors.white.withOpacity(0.85),
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.settings_outlined, color: Color(0xFF475569)),
                  tooltip: 'Ayarlar',
                  onPressed: _openSettings,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== SOL MARKA PANELI (musteri) ====================
  Widget _buildBrandPanel(ThemeProvider theme) {
    // Logo parlakligina gore zemin: acik/beyaz logo -> koyu zemin, koyu logo -> beyaz zemin.
    // _logoIsLight null iken (analiz bitmemis) guvenli varsayilan: beyaz zemin (cogu logo koyu/renkli).
    final logoIsLight = _logoIsLight ?? false;
    final badgeBg = logoIsLight
        ? Colors.black.withOpacity(0.28) // acik logo -> koyu zemin
        : Colors.white;                  // koyu/renkli logo -> beyaz zemin

    // Logo kutusu logonun sekline gore boyutlanir (kare/dikey/yatay) + devasa logo kuculur.
    // Referans yukseklik 84, ama max genislik 280 ve max yukseklik 130 ile sinirli.
    const maxW = 280.0, maxH = 130.0, baseH = 84.0;
    final aspect = _logoAspect ?? (220 / 72); // analiz bitmemisse varsayilan yatay
    double logoH = baseH;
    double logoW = logoH * aspect;
    if (logoW > maxW) { logoW = maxW; logoH = logoW / aspect; }  // cok yatay/devasa -> genislikten sinirla
    if (logoH > maxH) { logoH = maxH; logoW = logoH * aspect; }  // cok dikey -> yukseklikten sinirla
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
                // MUSTERI logosu — zemin rengi logonun parlakligina gore otomatik.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: _buildBrandLogo(theme, width: logoW, height: logoH),
                ),
                const SizedBox(height: 40),

                const _LiveClock(),
                const SizedBox(height: 24),

                // Masa özeti: Toplam - Boş - Dolu (offline'da da cached_tables'tan).
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _tableStatBox(
                      label: 'Toplam Masa',
                      value: _totalTables,
                      icon: Icons.grid_view_rounded,
                    ),
                    _tableStatBox(
                      label: 'Boş Masa',
                      value: _emptyTables,
                      icon: Icons.check_circle_outline,
                      accent: const Color(0xFF22C55E),
                    ),
                    _tableStatBox(
                      label: 'Dolu Masa',
                      value: _occupiedTables,
                      icon: Icons.restaurant,
                      accent: const Color(0xFFF59E0B),
                    ),
                  ],
                ),
                const SizedBox(height: 28),

                // Durum rozetleri: baglanti + bekleyen sync
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _statusChip(
                      icon: _isOnline ? Icons.cloud_done : Icons.cloud_off,
                      label: _isOnline ? 'Çevrimiçi' : 'Çevrimdışı',
                      color: _isOnline ? const Color(0xFF22C55E) : const Color(0xFF94A3B8),
                    ),
                    if (_pendingSync > 0)
                      _statusChip(
                        icon: Icons.sync,
                        label: '$_pendingSync işlem bekliyor',
                        color: const Color(0xFFF59E0B),
                      ),
                  ],
                ),

                const Spacer(),

                // Bayi adi + surum/cihaz (alt bilgi seridi)
                Row(
                  children: [
                    Icon(Icons.storefront, color: Colors.white.withOpacity(0.75), size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        theme.brandName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (_version.isNotEmpty) _version,
                    widget.storageService.getApiKeyName() ?? 'POS',
                  ].join('  ·  '),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 13,
                  ),
                ),
          ],
        ),
    );
  }

  Widget _statusChip({required IconData icon, required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // Masa özeti kutusu (Toplam / Boş) — marka temasıyla uyumlu yarı-saydam kart.
  Widget _tableStatBox({
    required String label,
    required int value,
    required IconData icon,
    Color accent = Colors.white,
  }) {
    return Container(
      width: 130,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent.withOpacity(0.85), size: 18),
              const SizedBox(width: 6),
              Text(
                '$value',
                style: TextStyle(
                  color: accent,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== SAG PIN KARTI ====================
  Widget _buildPinCard(ThemeProvider theme, String keyName) {
    return AnimatedBuilder(
      animation: _shakeCtrl,
      builder: (context, child) {
        // Yanlis PIN'de yatay titreme: sonumlu sinus (4 salinim, genlik 0'a iner).
        final t = _shakeCtrl.value;
        final dx = t == 0 ? 0.0 : (1 - t) * 14 * sin(t * pi * 8);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // SyncResto urun logosu (asset) — beyaz kart uzerinde net. Musteri logosu SOL panelde.
            Image.asset(
              'assets/images/logo.png',
              width: 180, height: 60, fit: BoxFit.contain,
            ),
            const SizedBox(height: 24),

            const Text(
              'Garson Girişi',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '4 Haneli PIN Kodunuzu Giriniz',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),

            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Color(0xFFDC2626), fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // PIN dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (index) {
                final filled = index < _pin.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  width: 50,
                  height: 50,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: filled ? theme.primaryColor : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: filled ? theme.primaryColor : const Color(0xFFE5E7EB),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: filled
                        ? const Icon(Icons.circle, color: Colors.white, size: 16)
                        : null,
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),

            if (_isLoading)
              CircularProgressIndicator(color: theme.primaryColor)
            else
              _buildNumpad(),

            const SizedBox(height: 20),

            // Klavye ipucu
            Text(
              'Klavyeden rakam tuşlarını da kullanabilirsiniz',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
            const SizedBox(height: 16),

            // Baglanti/key bilgisi
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isOnline ? Icons.check_circle : Icons.cloud_off,
                    color: _isOnline ? theme.primaryColor : const Color(0xFF94A3B8),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    keyName,
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Musteri logosu (sol panel) — cache File > network(cozulmus URL) > firma ADI fallback.
  Widget _buildBrandLogo(ThemeProvider theme, {double width = 180, double height = 60}) {
    final fallback = _brandNameFallback(theme, height);
    if (_brandLogoFile != null) {
      return Image.file(
        _brandLogoFile!,
        width: width, height: height, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    final url = _resolveLogoUrl(theme.brandLogoUrl);
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        width: width, height: height, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : SizedBox(
              width: width, height: height,
              child: const Center(
                child: SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            ),
      );
    }
    return fallback;
  }

  // Logo yoksa firma ADINI yaz (SyncResto asset degil — burasi musteri tarafi).
  Widget _brandNameFallback(ThemeProvider theme, double height) {
    return Text(
      theme.brandName,
      style: TextStyle(
        color: const Color(0xFF1F2937),
        fontSize: (height * 0.42).clamp(20, 40),
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
    );
  }

  Widget _buildNumpad() {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('1'),
            _buildNumButton('2'),
            _buildNumButton('3'),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('4'),
            _buildNumButton('5'),
            _buildNumButton('6'),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('7'),
            _buildNumButton('8'),
            _buildNumButton('9'),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildActionButton('C', Colors.orange, _clearPin),
            _buildNumButton('0'),
            _buildActionButton(null, Colors.red, _deleteDigit, icon: Icons.backspace),
          ],
        ),
      ],
      ),
    );
  }

  Widget _buildNumButton(String digit) {
    // POS dokunmatik ekranlar için 92x74. _PressableKey: basinca scale-down geri bildirimi.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _PressableKey(
        onTap: () => _addDigit(digit),
        color: const Color(0xFFF3F4F6),
        child: Center(
          child: Text(
            digit,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2937),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(String? label, Color color, VoidCallback onPressed, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _PressableKey(
        onTap: onPressed,
        color: color.withOpacity(0.12),
        child: Center(
          child: icon != null
              ? Icon(icon, size: 28, color: color)
              : Text(
                  label!,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Basinca hafif kuculen tus (dokunmatik POS geri bildirimi). InkWell ripple + scale.
class _PressableKey extends StatefulWidget {
  final VoidCallback onTap;
  final Color color;
  final Widget child;
  const _PressableKey({required this.onTap, required this.color, required this.child});

  @override
  State<_PressableKey> createState() => _PressableKeyState();
}

class _PressableKeyState extends State<_PressableKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _down ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      child: Material(
        color: widget.color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(width: 92, height: 74, child: widget.child),
        ),
      ),
    );
  }
}

// Sadece saat/tarih saniyede rebuild olur (tum ekran degil).
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  static const _months = [
    'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'
  ];
  static const _days = [
    'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'
  ];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _greeting {
    final h = _now.hour;
    if (h >= 5 && h < 12) return 'Günaydın';
    if (h >= 12 && h < 18) return 'İyi çalışmalar';
    if (h >= 18 && h < 23) return 'İyi akşamlar';
    return 'İyi geceler';
  }

  @override
  Widget build(BuildContext context) {
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final ss = _now.second.toString().padLeft(2, '0');
    final date = '${_now.day} ${_months[_now.month - 1]} ${_now.year}, ${_days[_now.weekday - 1]}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _greeting,
          style: TextStyle(
            color: Colors.white.withOpacity(0.85),
            fontSize: 22,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$hh:$mm',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 76,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ss,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          date,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 18,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// Yumusak suzulen balonlar (arkaplan). RepaintBoundary ile izole (Fable O3).
class _AnimatedBackdrop extends StatefulWidget {
  const _AnimatedBackdrop();

  @override
  State<_AnimatedBackdrop> createState() => _AnimatedBackdropState();
}

class _AnimatedBackdropState extends State<_AnimatedBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 20))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => CustomPaint(painter: _BackdropPainter(_ctrl.value)),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  final double t;
  _BackdropPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final circles = [
      [0.15 + 0.05 * sin(t * 2 * pi), 0.28, 0.30, 0.05],
      [0.5 + 0.04 * cos(t * 2 * pi), 0.15 + 0.05 * sin(t * 2 * pi + 2), 0.26, 0.045],
      [0.82, 0.35 + 0.06 * cos(t * 2 * pi), 0.34, 0.05],
      [0.35 + 0.05 * sin(t * 2 * pi + 1), 0.82, 0.30, 0.045],
      [0.9 + 0.03 * sin(t * 2 * pi), 0.85, 0.24, 0.04],
    ];
    for (final c in circles) {
      paint.color = Colors.white.withOpacity(c[3]);
      canvas.drawCircle(
        Offset(size.width * c[0], size.height * c[1]),
        size.shortestSide * c[2],
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.t != t;
}
