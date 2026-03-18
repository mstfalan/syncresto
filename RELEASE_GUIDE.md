# SyncResto POS - Yeni Sürüm Yayınlama Rehberi

## Adımlar

### 1. Versiyon Güncelle
```bash
# pubspec.yaml dosyasında version'ı güncelle
# Örnek: version: 1.0.2+3 → version: 1.0.3+4
```

### 2. GitHub'a Gönder
```bash
cd /Users/mustafalan/specpulse/projects/greenchef_pos
git add -A
git commit -m "v1.0.3 güncelleme"
git push origin main
```

### 3. GitHub Release Oluştur
```bash
# Release oluştur
gh release create v1.0.3 --repo mstfalan/syncresto --title "SyncResto POS v1.0.3" --notes "Güncelleme"

# Windows build'i indir (GitHub Actions ~5dk sonra tamamlanır)
gh run list --repo mstfalan/syncresto --limit 1
gh run download <RUN_ID> --repo mstfalan/syncresto --name SyncResto-Windows

# Windows zip'i release'e ekle
gh release upload v1.0.3 /tmp/SyncResto-Windows.zip --repo mstfalan/syncresto
```

### 4. SyncResto API Sunucusunu Güncelle (KRİTİK!)
```bash
# SSH ile bağlan
ssh -i ~/.ssh/babystorybook-key.pem ubuntu@18.194.103.51

# Versiyon dosyasını güncelle
cd ~/syncresto-api
nano routes/pos-version.js

# Şu satırları güncelle:
#   current_version: '1.0.3',
#   windows: '.../v1.0.3/SyncResto-Windows.zip',
#   macos: '.../v1.0.3/SyncResto-macOS.zip'

# PM2 restart
pm2 restart syncresto-api
```

### 5. Doğrulama
```bash
# API'den versiyon kontrolü
curl -s 'https://api.syncresto.com/api/pos/version' -H 'X-API-Key: SR_bf54112d_821c6f9182fb4148a27034e7' | python3 -m json.tool
```

---

## Hızlı Komutlar (Tek Satırda)

```bash
# Versiyon güncelle + commit + push
sed -i '' 's/version: 1.0.2+3/version: 1.0.3+4/' pubspec.yaml && git add -A && git commit -m "v1.0.3" && git push origin main

# Release + Windows zip (5dk bekle)
gh release create v1.0.3 --repo mstfalan/syncresto --title "SyncResto POS v1.0.3" --notes "Güncelleme"
# ... build tamamlandıktan sonra ...
gh run download $(gh run list --repo mstfalan/syncresto --limit 1 --json databaseId -q '.[0].databaseId') --repo mstfalan/syncresto --name SyncResto-Windows -D /tmp
gh release upload v1.0.3 /tmp/SyncResto-Windows.zip --repo mstfalan/syncresto

# Sunucu güncelle
ssh -i ~/.ssh/babystorybook-key.pem ubuntu@18.194.103.51 "cd ~/syncresto-api && sed -i \"s/current_version: '1.0.2'/current_version: '1.0.3'/g\" routes/pos-version.js && sed -i 's|v1.0.2/SyncResto|v1.0.3/SyncResto|g' routes/pos-version.js && pm2 restart syncresto-api"
```

---

## Notlar

- **GitHub Actions** otomatik Windows build yapar (~5 dakika)
- **macOS build** manuel yapılmalı (yerel makinede `flutter build macos`)
- Sunucu versiyonu güncellemezsen, eski sürüm kullananlar sürekli güncelleme isteyecek
- `min_required_version` zorunlu güncelleme için kullanılır (kritik güvenlik yamaları)
