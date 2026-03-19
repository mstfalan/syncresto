# SyncResto POS - Claude Code Memory

## Proje Bilgileri
| Özellik | Değer |
|---------|-------|
| **Proje** | SyncResto POS - Multi-tenant Flutter masaüstü uygulaması |
| **Platform** | macOS (Windows/Linux desteği planlanıyor) |
| **Mimari** | Multi-Tenant SaaS + Offline-First |
| **SyncResto API** | https://api.syncresto.com (Proxy) |
| **SyncResto Server** | 18.194.103.51 (EC2) |
| **Örnek Tenant** | GreenChef (63.178.229.236) |

---

## 🏢 Multi-Tenant Mimari (Mart 2026)

### Genel Bakış
SyncResto POS, tek bir Flutter uygulaması ile birden fazla restorana hizmet veren multi-tenant bir SaaS ürünüdür. Her restoran kendi API key'i ile sisteme bağlanır.

### Mimari Diyagramı
```
┌─────────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│  SyncResto POS  │────▶│  SyncResto API      │────▶│  Tenant Backend  │
│  (Flutter App)  │     │  (Proxy Server)     │     │  (GreenChef etc) │
│                 │     │  18.194.103.51      │     │  63.178.229.236  │
└─────────────────┘     └─────────────────────┘     └──────────────────┘
        │                        │                          │
        │  X-API-Key Header      │  Tenant Resolution       │
        │  SR_xxxxxxxx_xxx...    │  backend_url lookup      │
        ▼                        ▼                          ▼
   ┌─────────┐            ┌───────────┐             ┌────────────┐
   │ Offline │            │ PostgreSQL│             │ PostgreSQL │
   │ SQLite  │            │ (RDS)     │             │ (Tenant)   │
   └─────────┘            └───────────┘             └────────────┘
```

### API Key Sistemi
- **Format**: `SR_xxxxxxxx_xxxxxxxxxxxxxxxxxxxxxxxx` (40 karakter)
- **Prefix**: `SR_` (tanımlama)
- **Lookup**: İlk 11 karakter (hızlı DB sorgusu)
- **Hash**: SHA-256 ile saklanır (güvenlik)
- **Örnek**: `SR_bdfea51f_8fc954e9914c6ffa2a920d6f` (GreenChef)

### SyncResto API Endpoints (Proxy)
| Endpoint | Method | Açıklama |
|----------|--------|----------|
| `/api/pos/validate-key` | POST | API key doğrula, restaurant bilgisi dön |
| `/api/pos/waiters/login` | POST | PIN ile garson girişi |
| `/api/pos/waiters` | GET | Garson listesi |
| `/api/pos/tables/sections` | GET | Salonları getir |
| `/api/pos/tables` | GET | Masaları getir |
| `/api/pos/categories` | GET | Kategorileri getir |
| `/api/pos/products` | GET | Ürünleri getir |
| `/api/pos/settings` | GET | Ayarları getir (tema, marka) |
| `/api/pos/tickets/*` | ALL | Adisyon işlemleri |
| `/api/pos/printers` | GET | Yazıcıları getir |

### Tenant Veritabanı (SyncResto RDS)
```sql
-- restaurants: Ana müşteri tablosu
CREATE TABLE public.restaurants (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    slug VARCHAR(100) UNIQUE,
    schema_name VARCHAR(63) UNIQUE,
    backend_url VARCHAR(255),  -- Tenant API URL
    is_active BOOLEAN DEFAULT true
);

-- pos_api_keys: API key tablosu
CREATE TABLE public.pos_api_keys (
    id SERIAL PRIMARY KEY,
    restaurant_id INTEGER REFERENCES restaurants(id),
    api_key_hash VARCHAR(64),      -- SHA-256 hash
    api_key_prefix VARCHAR(11),    -- "SR_xxxxxxxx"
    name VARCHAR(100),             -- "Kasa 1", "Tablet 2"
    is_active BOOLEAN DEFAULT true
);

-- restaurant_licenses: POS lisans kontrolü
CREATE TABLE public.restaurant_licenses (
    restaurant_id INTEGER,
    module_id INTEGER,  -- pos_panel module
    is_active BOOLEAN,
    expires_at TIMESTAMP
);
```

---

## 🎨 Dinamik Tema Sistemi (Mart 2026)

### ThemeProvider
Her restoran kendi marka renklerini kullanabilir. Renkler API'den alınır ve cache'lenir.

**Dosya**: `lib/providers/theme_provider.dart`

```dart
class ThemeProvider extends ChangeNotifier {
  Color _primaryColor = Color(0xFF2563EB);  // Default: SyncResto mavisi
  Color _secondaryColor;
  String _brandName = 'SyncResto POS';
  String? _brandLogoUrl;

  // Gradient sadece primary color'ın tonlarını kullanır
  LinearGradient get backgroundGradient {
    final hsl = HSLColor.fromColor(_primaryColor);
    final darkerShade = hsl.withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
    return LinearGradient(colors: [_primaryColor, darkerShade]);
  }

  void updateFromSettings(Map<String, dynamic> settings) {
    _primaryColor = parseColor(settings['primary_color'], _defaultPrimary);
    _secondaryColor = generateSecondary(_primaryColor);
    _brandName = settings['brand_name'] ?? 'SyncResto POS';
    _brandLogoUrl = settings['brand_logo'];
    notifyListeners();
  }
}
```

### Settings API Response
```json
{
  "primary_color": "#dc2626",
  "secondary_color": "#b91c1c",
  "brand_name": "Joi Lezzet Köşesi",
  "brand_logo": "https://joilezzetkosesi.com/uploads/logo.png"
}
```

### Salon Renkleri
Her salon (section) kendi rengine sahip olabilir:
- ALT KAT: `#3b82f6` (mavi)
- BALKON: `#22c55e` (yeşil)
- ÜST KAT: `#f59e0b` (turuncu)

---

## 🔐 Garson Yetki Sistemi (Mart 2026)

### Yetkiler
| Yetki | Açıklama | Buton |
|-------|----------|-------|
| `open_ticket` | Adisyon açabilir | Adisyon Aç |
| `add_item` | Ürün ekleyebilir | Ürün Ekle |
| `cancel_item` | Ürün iptal edebilir | Ürün X butonu |
| `apply_discount` | İndirim uygulayabilir | İndirim |
| `close_ticket` | Hesap kapatabilir | Nakit, Kredi Kartı |
| `void_ticket` | Adisyon iptal edebilir | Adisyon İptal |
| `transfer_table` | Masa değiştirebilir | Masa Değiştir |
| `print_receipt` | Fiş yazdırabilir | Yazdır, Mutfağa Gönder |
| `view_all_tables` | Tüm masaları görebilir | - |
| `edit_prices` | Fiyat değiştirebilir | - |

### API Response (Login)
```json
{
  "success": true,
  "waiter": {
    "id": 1,
    "name": "Ahmet",
    "permissions": {
      "open_ticket": true,
      "add_item": true,
      "cancel_item": true,
      "apply_discount": false,
      "close_ticket": false,
      "void_ticket": false,
      "transfer_table": true,
      "print_receipt": true
    }
  }
}
```

### Flutter Implementasyonu
**Dosya**: `lib/widgets/ticket_modal.dart`

```dart
bool _hasPermission(String permission) {
  final permissions = widget.waiter['permissions'] as Map<String, dynamic>?;
  if (permissions == null) return true; // Yetki bilgisi yoksa izin ver
  return permissions[permission] == true;
}

// Kullanım örneği:
if (_hasPermission('apply_discount')) ...[
  _buildSmallActionButton(
    icon: Icons.percent,
    label: 'Indirim',
    onPressed: _openDiscountModal,
  ),
],
```

---

## ⚡ Auto-Refresh ve Responsive Grid (Mart 2026)

### Masalar Ekranı Auto-Refresh
**Dosya**: `lib/screens/tables_screen.dart`

```dart
Timer? _refreshTimer;

void _startAutoRefresh() {
  _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    if (_isOnline && mounted) {
      _loadData(silent: true);  // UI flickering'i önle
    }
  });
}

Future<void> _loadData({bool silent = false}) async {
  if (!silent) {
    setState(() => _isLoading = true);  // Loading göster
  }
  // ... veri yükle ...
}
```

### Responsive Grid (Masalar)
Tüm masalar ekrana sığacak şekilde otomatik grid hesaplaması:

```dart
return LayoutBuilder(
  builder: (context, constraints) {
    final tableCount = tables.length;
    int bestCols = 1;
    double bestCellSize = 0;

    // Optimal sütun sayısını bul
    for (int cols = 1; cols <= tableCount; cols++) {
      final rows = (tableCount / cols).ceil();
      final cellWidth = (availableWidth - (cols - 1) * 12) / cols;
      final cellHeight = (availableHeight - (rows - 1) * 12) / rows;
      final cellSize = min(cellWidth, cellHeight);
      if (cellSize > bestCellSize) {
        bestCellSize = cellSize;
        bestCols = cols;
      }
    }

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(), // Scroll yok
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: bestCols,
        childAspectRatio: 1.0,
      ),
      // ...
    );
  },
);
```

---

## 🏗️ Proje Yapısı
```
lib/
├── main.dart                    # Uygulama giriş noktası
├── screens/
│   ├── setup_screen.dart        # İlk kurulum (API URL)
│   ├── initial_sync_screen.dart # İlk veri senkronizasyonu
│   ├── pin_login_screen.dart    # Garson PIN girişi
│   ├── tables_screen.dart       # Ana ekran - masa görünümü
│   ├── pos_screen.dart          # POS arayüzü (alternatif)
│   └── printer_settings_screen.dart # Yazıcı ayarları
├── services/
│   ├── api_service.dart         # REST API çağrıları
│   ├── local_db_service.dart    # SQLite yerel veritabanı
│   ├── sync_service.dart        # Arka plan senkronizasyon
│   ├── printer_service.dart     # ESC/POS yazıcı
│   ├── websocket_service.dart   # Socket.io bağlantısı
│   ├── storage_service.dart     # SharedPreferences
│   ├── connectivity_service.dart# İnternet durumu
│   ├── sound_service.dart       # Ses bildirimleri
│   └── image_cache_service.dart # Görsel önbellek
└── widgets/
    ├── ticket_modal.dart        # Adisyon yönetimi
    ├── discount_modal.dart      # İndirim uygulama
    ├── product_detail_modal.dart# Ürün detayları + ekstralar
    └── add_item_modal.dart      # Ürün ekleme
```

---

## 🎯 Temel Özellikler

### 🔐 Kimlik Doğrulama
- PIN tabanlı garson girişi (4+ hane)
- Offline çalışma için PIN'ler yerel DB'de önbelleklenir
- Aktif garson bilgisi uygulama genelinde saklanır

### 🪑 Masa Yönetimi
- Bölümler (sections): Bahçe, Salon, VIP vb.
- Masa durumları:
  - 🟢 Boş (available)
  - 🟡 Açık hesap (occupied)
  - 🔴 Mutfakta sipariş var (has_kitchen_order)
- Her masa kart olarak gösterilir, üzerinde tutar bilgisi

### 🧾 Adisyon (Ticket) Yönetimi
- **Açma**: Masaya tıkla → otomatik yeni adisyon
- **Ürün Ekleme**: Kategori/arama ile ürün seç
- **Ekstralar**: Ürüne ek malzeme (ücretli/ücretsiz)
- **Özel Fiyat**: Ürün bazında manuel fiyat girişi
- **Miktar**: +/- butonları ile ayarlama
- **Mutfağa Gönder**: Yazdırılmamış ürünleri yazıcıya gönder
- **Hesabı Kapat**: Ödeme al (nakit/kart) ve masayı boşalt
- **İptal (Void)**: Tüm adisyonu iptal et

### 🏷️ İndirim Sistemi
- Yüzde indirimi: %5, %10, %15, %20 vb.
- Sabit tutar: Manuel TL girişi
- Ara toplam üzerinden hesaplanır

### 📦 Ürün Yönetimi
- Kategoriler: Görsel ikonlarla listele
- Arama: Ürün adına göre filtre
- Detaylar: İsim, fiyat, açıklama, kalori, stok, görsel
- Ekstralar: Ek malzemeler (fiyatlı/fiyatsız)

### 🔄 Senkronizasyon
- **Offline-First**: İnternet olmadan tam çalışır
- **SQLite**: Tüm veriler yerel DB'de
- **Background Sync**: Her 10 saniyede kontrol
- **Sync Queue**: Offline işlemler kuyrukta bekler

### 🌐 Real-time Özellikler
- WebSocket (Socket.io) ile anlık bildirimler
- Events: `new_order`, `order_updated`, `table_status_changed`
- Ses bildirimi: Yeni sipariş geldiğinde

### 🖼️ Görsel Önbellekleme
- Ürün görselleri ilk sync'te indirilir
- Offline erişim için yerel dosyada saklanır

---

## 🗄️ Yerel Veritabanı Tabloları (SQLite)
| Tablo | Açıklama |
|-------|----------|
| `categories` | Ürün kategorileri |
| `products` | Ürün kataloğu |
| `product_extras` | Ürün ek malzemeleri |
| `sections` | Restoran bölümleri |
| `tables` | Masalar |
| `tickets` | Adisyonlar |
| `ticket_items` | Adisyon kalemleri |
| `ticket_item_extras` | Kalem ekstraları |
| `waiters` | Garsonlar (PIN dahil) |
| `printers` | Yazıcı tanımları |
| `customers` | Müşteriler |
| `sync_queue` | Offline işlem kuyruğu |

---

## 🖨️ Yazıcı Sistemi

### Desteklenen Özellikler
- ESC/POS protokolü (TCP/IP, port 9100)
- Türkçe karakter dönüşümü (ş→s, ğ→g vb.)
- Yazıcı grupları: Mutfak, Bar, Kasa
- Kategori bazlı yönlendirme

### Fiş Formatı
- Logo/başlık
- Masa/garson bilgisi
- Ürün listesi (miktar x fiyat)
- Ara toplam/indirim/toplam
- Ödeme yöntemi
- QR kod (opsiyonel)

---

## 📱 Uygulama Akışı
```
SetupScreen (API URL gir)
    ↓
InitialSyncScreen (İlk veri çek)
    ↓
PinLoginScreen (Garson PIN)
    ↓
TablesScreen (Masa görünümü)
    ↓
TicketModal (Adisyon yönetimi)
```

---

## Tamamlanan İşlemler (2 Mart 2026)

### 1. Termal Yazıcı Entegrasyonu (Flutter)
- **Dosya**: `lib/services/printer_service.dart`
- ESC/POS protokolü ile termal yazıcı desteği
- TCP/IP üzerinden ağ yazıcılarına bağlantı (port 9100)
- Ağ tarama özelliği (192.168.1.* subnet)
- Türkçe karakter dönüşümü (`_turkishToAscii`)
- Adisyon fişi yazdırma (`printTicket`)
- Web sipariş fişi yazdırma (`printOrderReceipt`)

### 2. Yazıcı Ayarları Ekranı
- **Dosya**: `lib/screens/printer_settings_screen.dart`
- Ağ tarama butonu
- Manuel IP/Port girişi
- Bağlantı testi
- Ayarları SharedPreferences'a kaydetme

### 3. WebSocket/Socket.io Entegrasyonu
- **Dosya**: `lib/services/websocket_service.dart`
- `socket_io_client` paketi kullanılıyor
- Sunucuya otomatik bağlantı
- Event dinleme:
  - `new_web_order` - Yeni web siparişi
  - `order_update` - Sipariş güncelleme
  - `print_order` - Web'den yazdırma isteği

### 4. Web Admin Panel → POS Yazdırma Akışı
1. Admin panelde "Termal Yazıcıya Gönder" butonu
2. `POST /api/pos/printers/print-via-pos` endpoint'i
3. Sunucu `print_order` event'i yayınlar (Socket.io)
4. POS uygulaması event'i alır
5. Sipariş bilgileri + settings ile fiş oluşturulur
6. Yazıcıya TCP üzerinden gönderilir

### 5. Fiş Formatı (Web Siparişleri)
```
========== GREEN CHEF ==========
Tel: [veritabanından]
================================
SIPARIS: #260228-3469
Tarih: 02.03.2026 14:30
--------------------------------
MUSTERI BILGILERI
Ahmet Yilmaz
Tel: 0532 123 4567
Kadikoy, Istanbul
Not: Zili calmayin
--------------------------------
URUNLER
2 x Tavuk Cokertme      472.00 TL
  + Ekstra sos
1 x Ayran                30.00 TL
--------------------------------
Ara Toplam:             502.00 TL
Teslimat:                15.00 TL
Indirim:                -50.00 TL
--------------------------------
TOPLAM:                 467.00 TL
--------------------------------
Odeme: Kredi Karti
================================
Afiyet olsun!
www.greenchef.com.tr
```

## Sunucu Değişiklikleri

### API Endpoint'leri
- `POST /api/pos/printers/print-via-pos` - POS'a yazdırma isteği gönder
- Settings (brand_name, contact_phone) Socket.io event'ine eklendi

### Dosya Değişiklikleri
- `/var/www/greenchef/api/pos/printers.js` - print-via-pos route eklendi
- `/var/www/greenchef/services/printerService.js` - SQL syntax fix ($1)
- `/var/www/greenchef/public/admin/admin.js` - print-via-pos kullanacak şekilde güncellendi

## Veritabanı
- **Tablo**: `printers` - Yazıcı tanımları
- **Tablo**: `settings` - `auto_print_web_orders`, `brand_name`, `contact_phone`

## Bulunan Yazıcılar (Ağ Taraması)
- 192.168.1.86 (PalmX - Test edildi, çalışıyor)
- 192.168.1.90
- 192.168.1.112

## Bağımlılıklar (pubspec.yaml)
```yaml
dependencies:
  socket_io_client: ^3.0.2  # Socket.io client
  esc_pos_utils: ^1.1.0     # ESC/POS komutları
  esc_pos_printer: ^4.1.0   # Yazıcı bağlantısı
  audioplayers: ^6.1.0      # Bildirim sesleri
```

## Bilinen Sorunlar
1. **Ses dosyası eksik**: `assets/sounds/new_order.mp3` yok - bildirim sesi çalmıyor
2. **WebSocket DNS**: Bazen `greenchef.com.tr` DNS lookup hatası (geçici)

## Yapılacaklar (Planlandı)
1. NetGSM SMS entegrasyonu (plan dosyası mevcut)
2. Bildirim sesi eklenmesi
3. Bluetooth yazıcı desteği
4. Windows build testi

---

## GitHub Repository
- **Repo**: https://github.com/mstfalan/syncresto
- **Branch**: main
- **Clone**: `git clone https://github.com/mstfalan/syncresto.git`
- **Token**: `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` (sınırsız)

### GitHub Actions (Windows Build)
- **Workflow**: `.github/workflows/windows-build.yml`
- **Trigger**: Push to main branch veya manuel
- **Output**: `SyncResto-Windows.zip` artifact
- **İndirme**: GitHub → Actions → Son build → Artifacts → SyncResto-Windows

### Git Komutları
```bash
# Değişiklikleri push et
cd /Users/mustafalan/specpulse/projects/greenchef_pos
git add .
git commit -m "mesaj"
git push origin main

# Windows build otomatik başlar, ~5-10 dk sonra artifact hazır
```

---

---

## 🖥️ Sunucu Bilgileri

### SyncResto API Server (Proxy)
| Özellik | Değer |
|---------|-------|
| **IP** | 18.194.103.51 |
| **SSH** | `ssh -i ~/.ssh/babystorybook-key.pem ubuntu@18.194.103.51` |
| **Path** | `~/syncresto-api/` |
| **PM2** | `pm2 restart syncresto-api` |
| **Logs** | `pm2 logs syncresto-api --lines 50` |
| **Domain** | api.syncresto.com |

### GreenChef Backend (Örnek Tenant)
| Özellik | Değer |
|---------|-------|
| **IP** | 63.178.229.236 |
| **SSH** | `ssh -i ~/.ssh/greenchef-key.pem ubuntu@63.178.229.236` |
| **Path** | `/var/www/greenchef/` |
| **PM2** | `pm2 restart greenchef` |
| **Logs** | `pm2 logs greenchef --lines 50` |
| **Domain** | greenchef.com.tr, joilezzetkosesi.com |

### PostgreSQL Bağlantıları
```bash
# SyncResto RDS (Tenant yönetimi)
PGPASSWORD='ZNTo3ppGS0GfzdJUItiAox' psql -h babystorybook-db.postgres.database.azure.com -U babystorybookadmin -d postgres

# GreenChef RDS (Restoran verileri)
PGPASSWORD='GyZbQ0HKvPWr4Td73KSAbm9L' psql -h greenchef-db.c7g6a8ycwaij.eu-central-1.rds.amazonaws.com -U greenchef -d greenchef
```

### GreenChef Database Bilgileri
| Bilgi    | Değer                                                    |
|----------|----------------------------------------------------------|
| Host     | greenchef-db.c7g6a8ycwaij.eu-central-1.rds.amazonaws.com |
| Port     | 5432                                                     |
| User     | greenchef                                                |
| Password | GyZbQ0HKvPWr4Td73KSAbm9L                                 |
| Database | greenchef                                                |

---

## 🧪 Test Komutları

### API Key Doğrulama
```bash
curl -s -X POST 'https://api.syncresto.com/api/pos/validate-key' \
  -H 'X-API-Key: SR_bdfea51f_8fc954e9914c6ffa2a920d6f' \
  -H 'Content-Type: application/json' | python3 -m json.tool
```

### Garson Login
```bash
curl -s -X POST 'https://api.syncresto.com/api/pos/waiters/login' \
  -H 'X-API-Key: SR_bdfea51f_8fc954e9914c6ffa2a920d6f' \
  -H 'Content-Type: application/json' \
  -d '{"pin":"1234"}' | python3 -m json.tool
```

---

## Flutter Komutları
```bash
cd /Users/mustafalan/specpulse/projects/greenchef_pos
flutter run -d macos
flutter clean && flutter pub get

# Kill ve restart
pkill -f flutter; flutter run -d macos
```

---

## 📝 Değişiklik Geçmişi

### Mart 2026 - Multi-Tenant SaaS Dönüşümü
1. **SyncResto Proxy Mimarisi**: GreenChef-specific backend → Multi-tenant proxy
2. **API Key Sistemi**: Restaurant bazlı API key authentication
3. **Dinamik Tema**: Her restoran kendi renk/logo ile çalışıyor
4. **Garson Yetkileri**: 10 farklı yetki, UI'da conditional rendering
5. **Auto-Refresh**: Masalar 2 saniyede bir güncelleniyor (silent mode)
6. **Responsive Grid**: Tüm masalar ekrana sığıyor, scroll yok
7. **Branding**: GreenChef → SyncResto POS

### 14 Mart 2026 - Offline Sync İyileştirmeleri

#### Problem
Offline modda açılan ticket'lar server'a sync edilirken item'lar kayboluyordu (₺0 toplam). Ayrıca aynı masada zaten açık adisyon varsa hata veriyordu.

#### Çözümler

**1. Benzersiz Offline Ticket Numarası**
- Format: `OFFLINE-{masa_no}-{UUID8}` (örn: `OFFLINE-5-A7F3B2C1`)
- Çakışma riski yok (16^8 = 4.3 milyar kombinasyon)
- Aynı masada birden fazla offline ticket olabilir

**2. Server Değişiklikleri** (`/var/www/greenchef/api/pos/tickets.js`)
```javascript
// Offline ticket için "zaten açık adisyon var" kontrolü bypass
if (existingTicket && !req.body.is_offline) {
  return res.status(400).json({ error: 'Bu masada zaten açık adisyon var' });
}

// Offline ticket numarasını kullan
if (req.body.is_offline && req.body.offline_ticket_number) {
  ticketNumber = req.body.offline_ticket_number;
}

// Close/void için yetki bypass (is_offline === true || is_offline === "true")
const isOfflineClose = req.body.is_offline === true || req.body.is_offline === "true";
if (waiter_id && !isOfflineClose) {
  // yetki kontrolü
}

// Add item için kapalı ticket'a ekleme (is_offline true ise)
const ticketQuery = is_offline
  ? "SELECT id, status FROM tickets WHERE id = $1"
  : "SELECT id, status FROM tickets WHERE id = $1 AND status = 'open'";
```

**3. Flutter Sync Değişiklikleri** (`lib/services/sync_service.dart`)
```dart
// Ticket create sonrası server_id'yi sync_queue'ya kaydet
await _localDb.markSyncComplete(syncId, serverId: serverId);

// Item sync'te is_offline gönder (kapalı ticket'a da eklenebilir)
final response = await _dio!.post('/api/pos/tickets/$serverTicketId/items', data: {
  // ... diğer alanlar
  'is_offline': true, // Offline sync - kapalı ticket'a da eklenebilir
});

// Ticket silinmiş olsa bile depends_on_sync_id üzerinden server_id bul
if (serverTicketId == null) {
  final syncRecord = await db.query('sync_queue', where: 'id = ?', whereArgs: [syncId]);
  final dependsOnId = syncRecord.first['depends_on_sync_id'];
  final parentSync = await db.query('sync_queue', where: 'id = ?', whereArgs: [dependsOnId]);
  serverTicketId = parentSync.first['server_id'];
}
```

**4. Cleanup İyileştirmesi** (`lib/services/local_db_service.dart`)
```dart
// Pending item'ları olan ticket'ları silme
Future<void> cleanupSyncedTickets() async {
  for (final ticket in closedTickets) {
    // Bu ticket için pending sync işlemi var mı kontrol et
    final pendingSync = await db.query('sync_queue',
      where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ?)",
      whereArgs: [localId, '%"local_ticket_id":$localId%'],
    );

    if (pendingSync.isNotEmpty) {
      continue; // Temizlik atla
    }
    // ... silme işlemi
  }
}
```

**5. markSyncComplete Güncelleme**
```dart
Future<void> markSyncComplete(int syncId, {int? serverId}) async {
  final updateData = {
    'status': 'completed',
    'processed_at': DateTime.now().toIso8601String(),
  };
  if (serverId != null) {
    updateData['server_id'] = serverId;
  }
  await db.update('sync_queue', updateData, where: 'id = ?', whereArgs: [syncId]);
}
```

#### Sonuç
- ✅ Offline'da masa açılıyor
- ✅ Ürün ekleniyor
- ✅ Hesap kapatılıyor (nakit/kart)
- ✅ Online olunca sync ediliyor
- ✅ Web sitesinde item'larıyla birlikte görünüyor
- ✅ Aynı masada birden fazla offline ticket olabilir (farklı ödeme yöntemleri)

---

### Şubat-Mart 2026 - Temel Özellikler
1. Termal yazıcı entegrasyonu (ESC/POS, TCP/IP)
2. WebSocket real-time bildirimler
3. Offline-first mimari (SQLite)
4. Görsel önbellekleme
5. PIN tabanlı garson girişi
