import 'package:flutter/foundation.dart';

/// 24 Tem 2026 — Çıkmayan-fiş (retry tükenmiş mutfak fişi) bildirimi için global sinyal.
/// printer_service retry 5/5 tükendiğinde main.dart bunu tikler; POS sağ-üst rozet
/// bunu dinleyip listeyi (LocalDbService.getFailedKitchenPrints) yeniden çeker.
/// Basit bir "değişti" sayacı — badge poll'u beklemeden anlık yenileme sağlar.
final ValueNotifier<int> failedKitchenPrintsChanged = ValueNotifier<int>(0);
