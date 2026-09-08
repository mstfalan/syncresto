// 8 Eyl 2026 — HIZLI SATIŞ adisyon hazırlama akışı (tables_screen butonu + QuickSaleHost ortak).
//
// Fable denetim kararları burada uygulanır:
//  • E2: bu masada sunucuya gitmemiş close/void varsa sunucuya SORMADAN offline create
//    (createLocalTicket priorClose zinciri: close1 -> create2). Aksi hâlde ödenmiş adisyon
//    "devam" diye geri açılırdı.
//  • Y1: hızlı satış adisyonu YALNIZ açan kasada devam eder; sunucu 400 "zaten açık" derse
//    offline create ile başka kasanın adisyonuna merge OLMAZ (offlineFallbackOn400:false).
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'quick_sale_rules.dart';

class QuickSaleOpenResult {
  /// 'ok' | 'other_device' | 'lan_only' | 'already_open' | 'lan_denied' | 'error'
  final String kind;
  /// AddItemModal'a verilecek id (online: sunucu id, offline: yerel id).
  final int? ticketId;
  final bool offline;
  final String? error;
  /// other_device / lan_only için açan kasa adı (varsa).
  final String? deviceName;
  const QuickSaleOpenResult._(this.kind, {this.ticketId, this.offline = false, this.error, this.deviceName});

  bool get ok => kind == 'ok' && ticketId != null;

  static QuickSaleOpenResult basarili(int ticketId, {bool offline = false}) =>
      QuickSaleOpenResult._('ok', ticketId: ticketId, offline: offline);
  static QuickSaleOpenResult hata(String kind, {String? error, String? deviceName}) =>
      QuickSaleOpenResult._(kind, error: error, deviceName: deviceName);
}

class QuickSaleFlow {
  final ApiService apiService;
  final LocalDbService _db;
  QuickSaleFlow({required this.apiService, LocalDbService? db}) : _db = db ?? LocalDbService();

  static const String _deviceDisplayNameKey = 'pos_device_display_name'; // storage_service ile AYNI

  Future<String?> _buKasa() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_deviceDisplayNameKey);
    } catch (_) {
      return null;
    }
  }

  static int? _safeInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  /// Gizli hızlı-satış masasında adisyon hazırla.
  /// [resume] true: masada BU kasanın açık adisyonu varsa ona DEVAM; yoksa yeni aç.
  /// [resume] false (ödeme/iptal/taşıma sonrası): her zaman YENİ adisyon.
  Future<QuickSaleOpenResult> hazirla({
    required Map<String, dynamic> table,
    required int waiterId,
    required bool resume,
  }) async {
    final tableId = _safeInt(table['id']);
    if (tableId == null) return QuickSaleOpenResult.hata('error', error: 'Hızlı satış masası geçersiz');

    final buKasa = await _buKasa();
    final pendingClose = await _db.hasPendingCloseForTable(tableId);

    if (resume && !pendingClose && QuickSaleRules.masaDolu(table)) {
      // LAN Faz 2: masa sadece başka kasanın LAN yansımasıyla dolu → salt-okunur.
      if (await _db.hasLanOnlyOpenTicket(tableId)) {
        final summary = await _db.getLanTicketSummary(tableId);
        return QuickSaleOpenResult.hata('lan_only', deviceName: summary?['opened_by_device']?.toString());
      }
      final acan = table['opened_by_device']?.toString();
      if (QuickSaleRules.baskaKasadaAcik(openedByDevice: acan, buKasa: buKasa)) {
        return QuickSaleOpenResult.hata('other_device', deviceName: acan);
      }
      final ticketData = await apiService.getTableTicket(tableId);
      Map<String, dynamic>? ticket;
      if (ticketData != null && ticketData['ticket'] != null) {
        ticket = ticketData['ticket'] as Map<String, dynamic>?;
      } else if (ticketData != null && !ticketData.containsKey('ticket') && ticketData['id'] != null) {
        ticket = ticketData;
      }
      if (ticket != null) {
        // İkinci savunma: sunucudan gelen adisyonun açan kasası (masa listesi bayat olabilir).
        final sunucuAcan = ticket['opened_by_device']?.toString();
        if (QuickSaleRules.baskaKasadaAcik(openedByDevice: sunucuAcan, buKasa: buKasa)) {
          return QuickSaleOpenResult.hata('other_device', deviceName: sunucuAcan);
        }
        final id = _safeInt(ticket['id']) ?? _safeInt(ticket['local_id']);
        if (id != null) return QuickSaleOpenResult.basarili(id, offline: ticket['offline'] == true);
      }
      // Masa "dolu" görünüyordu ama adisyon yok → yeni aç (aşağı düş).
    }

    final r = await apiService.openTicket(
      tableId: tableId,
      waiterId: waiterId,
      customerCount: 1,
      forceOffline: pendingClose,
      offlineFallbackOn400: false,
    );
    if (r['lan_denied'] == true) return QuickSaleOpenResult.hata('lan_denied', error: r['error']?.toString());
    if (r['already_open'] == true) return QuickSaleOpenResult.hata('already_open', error: r['error']?.toString());
    if (r['success'] != true) return QuickSaleOpenResult.hata('error', error: r['error']?.toString());
    final id = _safeInt(r['ticket_id']);
    if (id == null) return QuickSaleOpenResult.hata('error', error: 'Adisyon kimliği alınamadı');
    return QuickSaleOpenResult.basarili(id, offline: r['offline'] == true);
  }
}
