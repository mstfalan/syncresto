import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class ImageCacheService {
  static final ImageCacheService _instance = ImageCacheService._internal();
  factory ImageCacheService() => _instance;
  ImageCacheService._internal();

  final Dio _dio = Dio();
  String? _cacheDir;

  Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    _cacheDir = path.join(appDir.path, 'image_cache');

    // Cache klasörünü oluştur
    final dir = Directory(_cacheDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    print('[ImageCache] Cache dizini: $_cacheDir');
  }

  /// URL'den dosya adı oluştur
  String _urlToFileName(String url) {
    // URL'deki özel karakterleri temizle
    final cleanUrl = url
        .replaceAll('https://', '')
        .replaceAll('http://', '')
        .replaceAll('/', '_')
        .replaceAll('?', '_')
        .replaceAll('&', '_')
        .replaceAll('=', '_');
    return cleanUrl;
  }

  /// Görselin cache path'ini döndür
  String getCachePath(String url) {
    if (_cacheDir == null) {
      // Cache henüz init olmamış, boş string döndür
      return '';
    }
    return path.join(_cacheDir!, _urlToFileName(url));
  }

  /// Cache hazır mı?
  bool get isReady => _cacheDir != null;

  /// Görsel cache'de var mı kontrol et
  Future<bool> isImageCached(String url) async {
    if (_cacheDir == null) return false;
    final file = File(getCachePath(url));
    return await file.exists();
  }

  /// Görseli indir ve cache'le
  Future<String?> downloadAndCache(String url) async {
    if (_cacheDir == null) await init();

    try {
      final cachePath = getCachePath(url);
      final file = File(cachePath);

      // Zaten varsa path döndür
      if (await file.exists()) {
        return cachePath;
      }

      // İndir
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

      if (response.data != null) {
        await file.writeAsBytes(response.data!);
        print('[ImageCache] İndirildi: ${path.basename(url)}');
        return cachePath;
      }
    } catch (e) {
      print('[ImageCache] İndirme hatası ($url): $e');
    }
    return null;
  }

  /// Birden fazla görseli paralel indir
  Future<Map<String, String>> downloadMultiple(List<String> urls) async {
    if (_cacheDir == null) await init();

    final results = <String, String>{};
    final futures = <Future<void>>[];

    for (final url in urls) {
      if (url.isEmpty) continue;

      futures.add(() async {
        final cachePath = await downloadAndCache(url);
        if (cachePath != null) {
          results[url] = cachePath;
        }
      }());
    }

    await Future.wait(futures);
    return results;
  }

  /// Cache'deki görseli getir (File veya null)
  Future<File?> getCachedImage(String url) async {
    if (_cacheDir == null) return null;

    final file = File(getCachePath(url));
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// Cache'deki görseli bytes olarak getir
  Future<Uint8List?> getCachedImageBytes(String url) async {
    final file = await getCachedImage(url);
    if (file != null) {
      return await file.readAsBytes();
    }
    return null;
  }

  /// Tüm cache'i temizle
  Future<void> clearCache() async {
    if (_cacheDir == null) return;

    final dir = Directory(_cacheDir!);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    print('[ImageCache] Cache temizlendi');
  }

  /// Cache boyutunu hesapla
  Future<int> getCacheSize() async {
    if (_cacheDir == null) return 0;

    final dir = Directory(_cacheDir!);
    if (!await dir.exists()) return 0;

    int size = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        size += await entity.length();
      }
    }
    return size;
  }

  /// Cache boyutunu okunabilir formatta döndür
  Future<String> getCacheSizeFormatted() async {
    final bytes = await getCacheSize();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ───────────────────────────────────────────────────────────────────────
  // 1 Haz 2026 (v1.5.6) — Cache şişme önleme (donma fix)
  // Sahada %AppData%\com.syncresto.pos\image_cache\ GB'lara çıkıp donmaya
  // sebep oluyordu. audit() LRU silme + pruneByActiveUrls() stale temizlik.
  // ───────────────────────────────────────────────────────────────────────

  /// Toplam cache boyutu > maxBytes ise en eski (lastModified) dosyalardan
  /// başlayarak targetBytes altına düşür. Boot'ta + saatlik çağrılır.
  Future<void> audit({
    int maxBytes = 200 * 1024 * 1024,    // 200MB hard cap
    int targetBytes = 150 * 1024 * 1024, // 150MB hedef (LRU sonrası)
  }) async {
    if (_cacheDir == null) return;
    try {
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return;

      // 1) Dosyaları listele ve boyut+mtime topla
      final entries = <_FileMeta>[];
      int totalSize = 0;
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            entries.add(_FileMeta(entity, stat.size, stat.modified));
            totalSize += stat.size;
          } catch (_) {}
        }
      }

      if (totalSize <= maxBytes) {
        print('[ImageCache] audit OK: ${(totalSize / (1024 * 1024)).toStringAsFixed(1)}MB (limit ${maxBytes ~/ (1024 * 1024)}MB)');
        return;
      }

      // 2) Eskiden yeniye sırala (LRU — en eski mtime önce silinir)
      entries.sort((a, b) => a.modified.compareTo(b.modified));

      // 3) targetBytes altına düşene kadar sil
      int deleted = 0;
      int reclaimed = 0;
      for (final e in entries) {
        if (totalSize <= targetBytes) break;
        try {
          await e.file.delete();
          totalSize -= e.size;
          reclaimed += e.size;
          deleted++;
        } catch (_) {}
      }
      print('[ImageCache] audit: $deleted dosya silindi, ${(reclaimed / (1024 * 1024)).toStringAsFixed(1)}MB geri kazanıldı');
    } catch (e) {
      print('[ImageCache] audit hatası: $e');
    }
  }

  /// Aktif (menüde olan) URL'lerin dışındaki cache dosyalarını sil.
  /// sync sonrası çağrılırsa silinmiş/değişmiş ürünlerin eski cache'i temizlenir.
  Future<void> pruneByActiveUrls(Set<String> activeUrls) async {
    if (_cacheDir == null || activeUrls.isEmpty) return;
    try {
      final activeFileNames = activeUrls.map(_urlToFileName).toSet();

      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return;

      int deleted = 0;
      int reclaimed = 0;
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          final name = path.basename(entity.path);
          if (!activeFileNames.contains(name)) {
            try {
              final size = await entity.length();
              await entity.delete();
              reclaimed += size;
              deleted++;
            } catch (_) {}
          }
        }
      }
      if (deleted > 0) {
        print('[ImageCache] prune: $deleted stale dosya silindi, ${(reclaimed / (1024 * 1024)).toStringAsFixed(1)}MB geri kazanıldı');
      }
    } catch (e) {
      print('[ImageCache] prune hatası: $e');
    }
  }
}

/// Internal: audit() için dosya meta
class _FileMeta {
  final File file;
  final int size;
  final DateTime modified;
  _FileMeta(this.file, this.size, this.modified);
}
