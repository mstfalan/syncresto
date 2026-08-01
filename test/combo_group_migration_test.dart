// SQLite v15 -> v16 göçü: local_ticket_items'a combo_group_id/name/pick_name eklenirken
// SAHADAKİ AÇIK ADİSYON KALEMLERİ KAYBOLMAMALI. Kasada güncelleme anında açık masa varsa
// bu kalemler o restoranın parasıdır — göç veri kaybı yaparsa hesap yanlış kapanır.
//
// Test, v16 bloğundaki ALTER'ların BİREBİR aynısını (local_db_service.dart:_onUpgrade)
// gerçek sqflite üzerinde çalıştırır.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v15'teki local_ticket_items şeması (combo kolonları YOK)
const _v15Sema = '''
  CREATE TABLE local_ticket_items (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER,
    local_ticket_id INTEGER NOT NULL,
    server_ticket_id INTEGER,
    product_id INTEGER NOT NULL,
    product_name TEXT NOT NULL,
    quantity INTEGER DEFAULT 1,
    unit_price REAL NOT NULL,
    custom_price REAL,
    notes TEXT,
    extras TEXT,
    status TEXT DEFAULT 'pending',
    synced INTEGER DEFAULT 0,
    synced_at TEXT,
    printed INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    added_by INTEGER,
    added_by_name TEXT,
    delivered_at TEXT,
    delivered_by INTEGER,
    delivered_by_name TEXT,
    portion TEXT,
    payment_status TEXT,
    payment_method TEXT,
    skip_pos_print INTEGER DEFAULT 0
  )
''';

/// local_db_service.dart v16 bloğunun AYNISI
Future<void> _v16Goc(Database db) async {
  for (final k in ['combo_group_id', 'combo_group_name', 'combo_pick_name']) {
    try {
      await db.execute('ALTER TABLE local_ticket_items ADD COLUMN $k TEXT');
    } catch (_) {
      // kolon zaten var — idempotent
    }
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute(_v15Sema);
    // Güncelleme anında masada duran 3 kalem
    for (final r in [
      {'local_ticket_id': 7, 'product_id': 11, 'product_name': 'Adana', 'quantity': 2, 'unit_price': 250.0, 'created_at': '2026-07-31T10:00:00', 'notes': 'acı az'},
      {'local_ticket_id': 7, 'product_id': 12, 'product_name': 'Ayran', 'quantity': 3, 'unit_price': 30.0, 'created_at': '2026-07-31T10:01:00'},
      {'local_ticket_id': 8, 'product_id': 13, 'product_name': 'Kunefe', 'quantity': 1, 'unit_price': 180.0, 'created_at': '2026-07-31T10:02:00'},
    ]) {
      await db.insert('local_ticket_items', r);
    }
  });

  tearDown(() async => db.close());

  test('göç sonrası MEVCUT KALEMLER AYNEN durur (veri kaybı yok)', () async {
    final once = await db.query('local_ticket_items', orderBy: 'local_id');
    await _v16Goc(db);
    final sonra = await db.query('local_ticket_items', orderBy: 'local_id');

    expect(sonra.length, 3);
    for (int i = 0; i < once.length; i++) {
      for (final k in once[i].keys) {
        expect(sonra[i][k], once[i][k], reason: 'satır $i alan $k değişti');
      }
    }
  });

  test('göç sonrası 3 yeni kolon var ve eski kalemlerde NULL (combo dışı = eski davranış)', () async {
    await _v16Goc(db);
    final r = await db.query('local_ticket_items', where: 'product_name = ?', whereArgs: ['Adana']);
    expect(r.first.containsKey('combo_group_id'), true);
    expect(r.first['combo_group_id'], isNull);
    expect(r.first['combo_group_name'], isNull);
    expect(r.first['combo_pick_name'], isNull);
  });

  test('göç sonrası combo kalemi yazılıp okunabiliyor (çevrimdışı ekleme)', () async {
    await _v16Goc(db);
    await db.insert('local_ticket_items', {
      'local_ticket_id': 9,
      'product_id': 20,
      'product_name': '2 Al 1 Öde Pizza',
      'quantity': 1,
      'unit_price': 470.0,
      'created_at': '2026-07-31T11:00:00',
      'combo_group_id': 'cg17540000000001234',
      'combo_group_name': '2 Al 1 Öde Pizza',
      'combo_pick_name': 'Margarita',
    });
    final r = await db.query('local_ticket_items', where: 'combo_group_id IS NOT NULL');
    expect(r.length, 1);
    expect(r.first['combo_group_name'], '2 Al 1 Öde Pizza');
    expect(r.first['combo_pick_name'], 'Margarita');
  });

  test('aynı combo grubundaki 2 kalem ortak id ile gruplanabiliyor', () async {
    await _v16Goc(db);
    const gid = 'cg17540000000009999';
    for (final ad in ['Margarita', 'Sucuklu']) {
      await db.insert('local_ticket_items', {
        'local_ticket_id': 9, 'product_id': 20, 'product_name': '2 Al 1 Öde Pizza',
        'quantity': 1, 'unit_price': 470.0, 'created_at': '2026-07-31T11:00:00',
        'combo_group_id': gid, 'combo_group_name': '2 Al 1 Öde Pizza', 'combo_pick_name': ad,
      });
    }
    final r = await db.query('local_ticket_items', where: 'combo_group_id = ?', whereArgs: [gid]);
    expect(r.length, 2);
    expect(r.map((e) => e['combo_pick_name']).toList(), ['Margarita', 'Sucuklu']);
  });

  test('göç İKİ KEZ çalışsa da patlamaz ve veri bozulmaz (idempotent)', () async {
    await _v16Goc(db);
    await _v16Goc(db); // ikinci tur — ALTER hata verir, yutulur
    final r = await db.query('local_ticket_items');
    expect(r.length, 3);
    expect(r.first.containsKey('combo_pick_name'), true);
  });
}
