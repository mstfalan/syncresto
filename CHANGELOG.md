# SyncResto POS - Changelog & Yapılanlar

## v1.4.0+32 (15 May 2026 — KRITIK WINDOWS FIX)

### Eski GPU Donanım Desteği — Software Rendering Default
- `windows/runner/main.cpp`: Software rendering **VARSAYILAN AÇIK** (`--enable-software-rendering`)
  - Sebep: Intel HD 2014-2016 model GPU'lar D3D11 ile `flutter_windows.dll` 0xc0000005 ACCESS_VIOLATION crash veriyordu
  - Process açılıyor ama pencere oluşmuyordu (RAM'de 47MB asılı kalıyordu)
  - POS UI 3D olmadığı için software rendering performans kaybı yok
  - Modern PC'lerde GPU rendering isteyenler için: `FLUTTER_DISABLE_SW_RENDER=1` env var ile bypass
- `windows/runner/main.cpp`: Pencere ekran ortasında açılır (multi-monitor / DPI offscreen sorunu için)
- `windows/runner/win32_window.cpp::Show()`: SW_RESTORE + SW_SHOWNORMAL + SetForegroundWindow + BringWindowToTop

### Test Edilen Donanım
- DESKTOP-UAJ9KMI: Intel i5-4300U (2014) + Intel HD 4400 + 4GB RAM + Win10 19045
- Önceki sürüm v1.3.5+27: hiç açılmıyor (3 kez crash)
- Önceki sürüm v1.3.9+31: arka planda asılı kalıyor (pencere yok)

## v1.0.2 (Beklemede)

### Fiş Formatı Güncellemesi (GreenChef Uyumlu)
- ✅ Dinamik brand_name ve contact_phone (settings'den)
- ✅ Web sipariş fişi GreenChef formatına uyumlu
- ✅ Mutfak fişi GreenChef formatına uyumlu
- ✅ Ürün bazlı yazıcı yönlendirme (printer_id)
- ✅ Puan indirimi (points_discount) desteği
- ✅ Ödeme yöntemi label'ları güncel (Kapıda Nakit/Kart, Online Ödeme)
- ✅ auto_print_web_orders ayarı desteği

### Dosya Değişiklikleri
- `lib/services/printer_service.dart` - Fiş formatları güncellendi
- `lib/screens/initial_sync_screen.dart` - Settings'i PrinterService'e aktarma

---

## v1.0.1 (17 Mart 2026)

### Otomatik Güncelleme Sistemi
- ✅ Versiyon kontrolü API endpoint'i (`/api/pos/version`)
- ✅ Güncelleme bildirimi modal'ı (zorunlu/opsiyonel)
- ✅ ZIP indirme ve progress bar
- ✅ Checksum doğrulama (SHA-256)
- ✅ macOS: ~/Applications'a otomatik kurulum
- ✅ Windows: %LOCALAPPDATA%\SyncResto POS'a otomatik kurulum
- ✅ Güncelleme sonrası otomatik yeniden başlatma
- ✅ macOS sandbox devre dışı (dosya sistemi erişimi için)

### Dosya Değişiklikleri
- `lib/services/version_service.dart` - Versiyon kontrol ve güncelleme servisi
- `lib/widgets/update_modal.dart` - Güncelleme bildirimi UI
- `lib/screens/initial_sync_screen.dart` - Başlangıçta versiyon kontrolü
- `macos/Runner/DebugProfile.entitlements` - Sandbox kapalı
- `macos/Runner/Release.entitlements` - Sandbox kapalı
- `windows/runner/CMakeLists.txt` - EXE ismi "SyncResto POS"
- `windows/runner/Runner.rc` - Windows metadata (şirket, ürün adı vb.)

### API (SyncResto Server)
- `/api/pos/version` - Versiyon bilgisi endpoint'i
- `/api/pos/logs` - Log gönderme endpoint'i (merkezi log)

---

## v1.0.0 (16 Mart 2026)

### Temel Özellikler
- ✅ Multi-tenant POS sistemi
- ✅ Offline çalışma desteği (SQLite cache)
- ✅ Lisans kontrolü (12 saat offline limit)
- ✅ WebSocket ile gerçek zamanlı senkronizasyon
- ✅ Yazıcı entegrasyonu (ESC/POS)
- ✅ Masa/adisyon yönetimi
- ✅ Garson PIN girişi

---

## Planlanan / Bekleyen

### Yapılacaklar
- [ ] Windows için icon ekleme
- [ ] Merkezi log sistemi admin paneli
- [ ] Checksum'ları GitHub release'e ekleme

### Notlar
- **Yeni sürüm göndermeden önce MUTLAKA sor!**
- GitHub Actions otomatik Windows build yapıyor
- macOS build manuel (flutter build macos --release)

---

## GitHub Releases

- **v1.0.0**: https://github.com/mstfalan/syncresto/releases/tag/v1.0.0
- **v1.0.1**: https://github.com/mstfalan/syncresto/releases/tag/v1.0.1

## API Versiyon Yönetimi

Sunucu: `https://api.syncresto.com`
Dosya: `/home/ubuntu/syncresto-api/routes/pos-version.js`

```javascript
const CURRENT_VERSION = {
  current_version: '1.0.1',      // En son sürüm
  min_required_version: '1.0.0', // Minimum desteklenen (altı zorunlu güncelleme)
  is_critical: false             // true = zorunlu güncelleme
};
```

## Build Komutları

```bash
# macOS Release Build
flutter build macos --release

# macOS ZIP oluştur
cd build/macos/Build/Products/Release
zip -r /tmp/SyncResto-macOS.zip "SyncResto POS.app"

# Windows (GitHub Actions otomatik yapıyor)
# Push yap, workflow çalışacak

# Windows artifact indir
gh run download <RUN_ID> -n SyncResto-Windows -D /tmp/windows-build

# Release'e yükle
gh release upload v1.x.x /tmp/SyncResto-macOS.zip --clobber
gh release upload v1.x.x /tmp/windows-build/SyncResto-Windows.zip --clobber
```
