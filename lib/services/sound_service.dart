import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart';

/// 14 Haz 2026 — audioplayers KALDIRILDI.
/// Sebep: audioplayers_windows_plugin.dll, Windows'ta c0000005 (access
/// violation) ile uygulamayi ÇÖKERTIYORDU (WER crash raporlariyla kanitlandi:
/// Sig[3]=audioplayers_windows_plugin.dll, Sig[6]=c0000005). Ses asseti de
/// repoda yoktu, fallback URL 404'tu — yani audioplayers hic ÇALISMIYOR ama
/// her cagrida native crash riski tasiyordu. Native access violation Dart
/// try/catch ile YAKALANAMAZ → tek kesin cozum plugin'i tamamen cikarmak.
///
/// Yeni ses: harici paket YOK.
///  - Windows: user32.dll MessageBeep (FFI; 'ffi' paketi sqflite uzerinden
///    zaten transitif var — ek bagimlilik yok). Cokme imkansiz.
///  - macOS/Linux: Flutter built-in SystemSound.play (alert).
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) => _enabled = value;

  // Windows MessageBeep(UINT uType). Degerler: MB_ICONHAND=0x10,
  // MB_ICONEXCLAMATION=0x30, MB_ICONASTERISK=0x40.
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final int Function(int)? _messageBeep = _user32 == null
      ? null
      : _user32!.lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'MessageBeep');

  void _beep({int winType = 0x00000030}) {
    try {
      if (Platform.isWindows) {
        _messageBeep?.call(winType);
      } else {
        // macOS/Linux: Flutter'in yerlesik sistem sesi (harici paket yok)
        SystemSound.play(SystemSoundType.alert);
      }
    } catch (e) {
      // Ses kritik degil — hicbir sekilde uygulamayi etkilemesin
      print('[Sound] beep hatasi (yok sayildi): $e');
    }
  }

  /// Yeni siparis bildirim sesi
  Future<void> playNewOrderSound() async {
    if (!_enabled) return;
    _beep(winType: 0x00000030); // MB_ICONEXCLAMATION — dikkat cekici
  }

  /// Basari sesi
  Future<void> playSuccessSound() async {
    if (!_enabled) return;
    _beep(winType: 0x00000040); // MB_ICONASTERISK — yumusak
  }

  /// Hata sesi
  Future<void> playErrorSound() async {
    if (!_enabled) return;
    _beep(winType: 0x00000010); // MB_ICONHAND — hata tonu
  }

  void dispose() {
    // Native handle tutulmuyor; temizlenecek kaynak yok.
  }
}
