# SyncResto POS - Kaldığımız Yer (17 Mart 2026)

## Sorun
macOS release build'de siyah ekran sorunu var. Debug modda çalışıyor ama release build'de siyah ekran kalıyor.

**ÖNEMLİ:** Bu sorun benim yaptığım değişikliklerden ÖNCE de var - v1.0.1 orijinal kodunu da test ettik, aynı sorun. Yani sorun Flutter/macOS tarafında.

## Yapılması Gereken
1. Mac'i restart et
2. Restart sonrası şu komutu çalıştır:
```bash
cd /Users/mustafalan/specpulse/projects/greenchef_pos
open "build/macos/Build/Products/Release/SyncResto POS.app"
```
3. Eğer hala siyah ekran varsa, debug modda çalıştır:
```bash
flutter run -d macos
```

## Bekleyen Değişiklikler (git stash'ta)
GreenChef fiş formatı güncellemeleri:
- `printer_service.dart` - Dinamik brand_name, contact_phone, auto_print_web_orders
- `initial_sync_screen.dart` - loadBrandSettings callback
- `main.dart` - autoPrintWebOrders kontrolü

Stash'ı geri almak için:
```bash
git stash pop
```

## Denenen Çözümler (Hiçbiri İşe Yaramadı)
1. MainFlutterWindow.swift - window background color, makeKeyAndOrderFront
2. AppDelegate.swift - applicationDidFinishLaunching force refresh
3. Info.plist - FLTEnableImpeller false
4. main.dart - Platform.isMacOS delay
5. initial_sync_screen.dart - addPostFrameCallback
6. Flutter clean, pub cache temizleme
7. App container/cache silme
8. ~/Applications'daki yüklü versiyon da aynı sorun

## Sistem Bilgileri
- macOS: 26.0.1 (25A362)
- Xcode: 26.0.1
- Flutter: 3.41.1 (stable)
- Dart: 3.11.0

## Olası Neden
macOS 26 veya Xcode 26 ile Flutter arasında uyumluluk sorunu olabilir. Mac restart sonrası düzelmezse Flutter downgrade veya macOS rendering engine reset gerekebilir.
