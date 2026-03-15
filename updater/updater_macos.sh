#!/bin/bash
# SyncResto POS macOS Updater Script
# Guvenlik: Bu script sadece SyncResto POS uygulamasi tarafindan calistirilir
# Arguman 1: ZIP dosyasi yolu
# Arguman 2: Uygulama dizini

set -e

ZIP_FILE="$1"
APP_DIR="$2"
BACKUP_DIR="${APP_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/SyncRestoUpdate"
LOG_FILE="${APP_DIR}/update_log.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

log "Guncelleme basladi"

# Parametreleri kontrol et
if [ -z "$ZIP_FILE" ]; then
    log "HATA: ZIP dosyasi belirtilmedi"
    exit 1
fi

if [ -z "$APP_DIR" ]; then
    log "HATA: Uygulama dizini belirtilmedi"
    exit 1
fi

# ZIP dosyasinin varligini kontrol et
if [ ! -f "$ZIP_FILE" ]; then
    log "HATA: ZIP dosyasi bulunamadi: $ZIP_FILE"
    exit 1
fi

log "Uygulama kapanmasi bekleniyor..."

# Uygulamanin kapanmasini bekle (5 saniye)
sleep 5

# Process kontrolu
if pgrep -x "greenchef_pos" > /dev/null; then
    log "Uygulama hala calisiyor, zorla kapatiliyor..."
    pkill -9 -x "greenchef_pos" || true
    sleep 2
fi

# Yedek dizini olustur
log "Yedek olusturuluyor: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Mevcut dosyalari yedekle
if [ -f "${APP_DIR}/greenchef_pos" ]; then
    cp "${APP_DIR}/greenchef_pos" "$BACKUP_DIR/" 2>/dev/null || true
fi
if [ -d "${APP_DIR}/data" ]; then
    cp -r "${APP_DIR}/data" "$BACKUP_DIR/" 2>/dev/null || true
fi

# Gecici dizin olustur
log "Gecici dizin olusturuluyor..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# ZIP dosyasini cikart
log "ZIP dosyasi cikarililiyor..."
if ! unzip -q "$ZIP_FILE" -d "$TEMP_DIR"; then
    log "HATA: ZIP cikarilirken hata olustu"
    log "Yedekten geri yukleniyor..."
    cp -r "$BACKUP_DIR"/* "$APP_DIR"/ 2>/dev/null || true
    exit 1
fi

# Yeni dosyalari kopyala
log "Yeni dosyalar kopyalaniyor..."
if ! cp -r "$TEMP_DIR"/* "$APP_DIR"/; then
    log "HATA: Dosyalar kopyalanirken hata olustu"
    log "Yedekten geri yukleniyor..."
    cp -r "$BACKUP_DIR"/* "$APP_DIR"/ 2>/dev/null || true
    exit 1
fi

# Calistirma izinleri ver
chmod +x "${APP_DIR}/greenchef_pos" 2>/dev/null || true

# Temizlik
log "Temizlik yapiliyor..."
rm -rf "$TEMP_DIR"
rm -f "$ZIP_FILE"

# Eski yedekleri temizle (7 günden eski)
find "$APP_DIR" -maxdepth 1 -type d -name "backup_*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

log "Guncelleme tamamlandi!"
echo "Guncelleme tamamlandi! Uygulama yeniden baslatiliyor..."

# Uygulamayi yeniden baslat
sleep 2
open "${APP_DIR}/greenchef_pos" 2>/dev/null || "${APP_DIR}/greenchef_pos" &

exit 0
