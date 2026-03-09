import 'package:audioplayers/audioplayers.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _enabled = true;

  bool get enabled => _enabled;
  set enabled(bool value) => _enabled = value;

  /// Play new order notification sound
  Future<void> playNewOrderSound() async {
    if (!_enabled) return;

    try {
      // Use a system sound or asset
      await _audioPlayer.setSource(AssetSource('sounds/new_order.mp3'));
      await _audioPlayer.resume();
    } catch (e) {
      print('[Sound] Ses calinamadi: $e');
      // Fallback - try URL sound
      try {
        await _audioPlayer.play(
          UrlSource('https://www.greenchef.com.tr/sounds/notification.mp3'),
        );
      } catch (e2) {
        print('[Sound] URL ses de calinamadi: $e2');
      }
    }
  }

  /// Play success sound
  Future<void> playSuccessSound() async {
    if (!_enabled) return;

    try {
      await _audioPlayer.play(AssetSource('sounds/success.mp3'));
    } catch (e) {
      print('[Sound] Success sesi calinamadi: $e');
    }
  }

  /// Play error sound
  Future<void> playErrorSound() async {
    if (!_enabled) return;

    try {
      await _audioPlayer.play(AssetSource('sounds/error.mp3'));
    } catch (e) {
      print('[Sound] Error sesi calinamadi: $e');
    }
  }

  void dispose() {
    _audioPlayer.dispose();
  }
}
