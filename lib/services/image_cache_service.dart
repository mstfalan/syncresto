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
}
