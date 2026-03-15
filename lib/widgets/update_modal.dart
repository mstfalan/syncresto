import 'package:flutter/material.dart';
import '../services/version_service.dart';

/// Güncelleme modal'ı
/// Zorunlu ve opsiyonel güncellemeler için kullanılır
class UpdateModal extends StatefulWidget {
  final UpdateCheckResult updateResult;
  final VoidCallback? onLater; // "Sonra" butonu için (sadece opsiyonel güncellemelerde)

  const UpdateModal({
    super.key,
    required this.updateResult,
    this.onLater,
  });

  /// Modal'ı göster
  static Future<void> show(
    BuildContext context,
    UpdateCheckResult updateResult, {
    VoidCallback? onLater,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: !updateResult.isUpdateRequired, // Zorunlu ise kapatılamaz
      builder: (context) => UpdateModal(
        updateResult: updateResult,
        onLater: onLater,
      ),
    );
  }

  @override
  State<UpdateModal> createState() => _UpdateModalState();
}

class _UpdateModalState extends State<UpdateModal> {
  final VersionService _versionService = VersionService();

  bool _isDownloading = false;
  double _downloadProgress = 0;
  String _downloadStatus = '';
  String? _errorMessage;

  VersionInfo get _versionInfo => widget.updateResult.versionInfo!;
  bool get _isRequired => widget.updateResult.isUpdateRequired;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isRequired && !_isDownloading,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _isRequired ? Colors.red.shade50 : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _isRequired ? Icons.warning_amber_rounded : Icons.system_update,
                color: _isRequired ? Colors.red : Colors.blue,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isRequired ? 'Zorunlu Güncelleme' : 'Yeni Güncelleme Mevcut',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'v${_versionInfo.currentVersion}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isRequired) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.red.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Bu güncelleme zorunludur. Devam etmek için güncellemeniz gerekiyor.',
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Changelog
              if (_versionInfo.changelog.isNotEmpty) ...[
                const Text(
                  'Değişiklikler:',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 150),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _versionInfo.changelog.map((item) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
                              Expanded(child: Text(item, style: const TextStyle(fontSize: 13))),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // İndirme durumu
              if (_isDownloading) ...[
                Column(
                  children: [
                    LinearProgressIndicator(
                      value: _downloadProgress,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _versionInfo.isCritical ? Colors.red : Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _downloadStatus,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],

              // Hata mesajı
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Versiyon bilgisi
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Mevcut: v${widget.updateResult.currentVersion}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    'Yeni: v${_versionInfo.currentVersion}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          // Sonra butonu (sadece opsiyonel güncellemelerde ve indirme sırasında değil)
          if (!_isRequired && !_isDownloading)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onLater?.call();
              },
              child: const Text('Sonra'),
            ),

          // Güncelle butonu
          ElevatedButton.icon(
            onPressed: _isDownloading ? null : _startUpdate,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRequired ? Colors.red : Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            icon: _isDownloading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.download, size: 18),
            label: Text(_isDownloading ? 'İndiriliyor...' : 'Şimdi Güncelle'),
          ),
        ],
      ),
    );
  }

  Future<void> _startUpdate() async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadStatus = 'Hazırlanıyor...';
      _errorMessage = null;
    });

    try {
      // İndir
      final updateFile = await _versionService.downloadUpdate(
        _versionInfo,
        onProgress: (received, total) {
          if (total > 0) {
            setState(() {
              _downloadProgress = received / total;
              final mb = (received / 1024 / 1024).toStringAsFixed(1);
              final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
              _downloadStatus = 'İndiriliyor: $mb MB / $totalMb MB';
            });
          }
        },
      );

      if (updateFile == null) {
        throw Exception('İndirme başarısız oldu');
      }

      setState(() {
        _downloadStatus = 'Güncelleme uygulanıyor...';
      });

      // Güncellemeyi uygula
      final success = await _versionService.applyUpdate(updateFile);

      if (!success) {
        throw Exception('Güncelleme uygulanamadı');
      }

      // Uygulama kapanacak, bu noktaya ulaşılmaz
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _errorMessage = e.toString();
      });
    }
  }
}
