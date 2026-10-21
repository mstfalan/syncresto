import 'ekran_olcum.dart';
import 'istek_olcum.dart';

/// Performans ölçümü ANAHTARI: sunucu /api/pos/settings 'performans_olcum'
/// (panel_settings pos_performans_olcum). VARSAYILAN KAPALI -> ölçüm yok, log yok.
/// Ayar her geldiğinde (açılış önbelleği + 5 dk yenileme + push) yeniden uygulanır.
bool _acik = false;
bool get performansOlcumAcik => _acik;

bool performansOlcumDegeri(Object? v) =>
    v == true || v == 1 || v == '1' || v == 'true';

void performansOlcumAyarla(Map<String, dynamic> settings) {
  final yeni = performansOlcumDegeri(settings['performans_olcum']);
  _acik = yeni; // baslat/ac/durdur/kapat idempotent: her ayar gelisinde yeniden uygulanir
  if (yeni) {
    EkranOlcum().baslat();
    IstekOlcum().ac();
  } else {
    EkranOlcum().durdur();
    IstekOlcum().kapat();
  }
}
