import 'package:audioplayers/audioplayers.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _enabled = true;

  // Bir kez denenip basarisiz olan kaynaklar (asset/URL) tekrar denenmez.
  // Boylece eksik asset + olu fallback URL her siparis icin tekrar tekrar
  // exception + network istegi uretmez. Basarili kaynaklar flaglenmez,
  // davranislari degismez.
  static final Set<String> _failedSources = <String>{};

  bool get enabled => _enabled;
  set enabled(bool value) => _enabled = value;

  /// Play new order notification sound
  Future<void> playNewOrderSound() async {
    if (!_enabled) return;

    if (!_failedSources.contains('asset:new_order')) {
      try {
        // Use a system sound or asset
        await _audioPlayer.setSource(AssetSource('sounds/new_order.mp3'));
        await _audioPlayer.resume();
        return;
      } catch (e) {
        _failedSources.add('asset:new_order');
        print('[Sound] Ses calinamadi (asset tekrar denenmeyecek): $e');
      }
    }

    // Fallback - try URL sound
    if (!_failedSources.contains('url:new_order')) {
      try {
        await _audioPlayer.play(
          UrlSource('https://api.syncresto.com/sounds/notification.mp3'),
        );
      } catch (e2) {
        _failedSources.add('url:new_order');
        print('[Sound] URL ses de calinamadi (tekrar denenmeyecek): $e2');
      }
    }
  }

  /// Play success sound
  Future<void> playSuccessSound() async {
    if (!_enabled) return;
    if (_failedSources.contains('asset:success')) return;

    try {
      await _audioPlayer.play(AssetSource('sounds/success.mp3'));
    } catch (e) {
      _failedSources.add('asset:success');
      print('[Sound] Success sesi calinamadi (tekrar denenmeyecek): $e');
    }
  }

  /// Play error sound
  Future<void> playErrorSound() async {
    if (!_enabled) return;
    if (_failedSources.contains('asset:error')) return;

    try {
      await _audioPlayer.play(AssetSource('sounds/error.mp3'));
    } catch (e) {
      _failedSources.add('asset:error');
      print('[Sound] Error sesi calinamadi (tekrar denenmeyecek): $e');
    }
  }

  void dispose() {
    _audioPlayer.dispose();
  }
}
