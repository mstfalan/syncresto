# GreenChef POS - Claude Code Memory

## Proje Bilgileri
| Özellik | Değer |
|---------|-------|
| **Proje** | GreenChef POS - Flutter masaüstü uygulaması |
| **Platform** | macOS (Windows/Linux desteği planlanıyor) |
| **Backend** | Node.js + Express + PostgreSQL (AWS) |
| **Sunucu IP** | 63.178.229.236 |
| **API URL** | https://greenchef.com.tr/api |
| **Mimari** | Offline-First + Real-time Sync |

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

## SSH Bağlantısı
```bash
ssh -i ~/.ssh/greenchef-key.pem ubuntu@63.178.229.236
```

## PM2 Komutları
```bash
pm2 restart greenchef
pm2 logs greenchef --lines 50
```

## Flutter Komutları
```bash
cd /Users/mustafalan/specpulse/projects/greenchef_pos
flutter run -d macos
flutter clean && flutter pub get
```
