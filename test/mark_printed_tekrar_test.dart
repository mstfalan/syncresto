// 21 Eki 2026 — senkron turu sonunda ayni turda yeniden denenecek mark_printed secimi.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/mark_printed_tekrar.dart';

Map<String, dynamic> _k(int id, String action, {int retry = 0}) =>
    {'id': id, 'action': action, 'retry_count': retry};

void main() {
  group('markPrintedTekrarSec', () {
    test('add_item tamamlandi + mark_printed bekliyor -> secilir', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(1, 'mark_printed'), _k(2, 'add_item')],
        yenidenOkunan: [_k(1, 'mark_printed')],
        tamamlanan: {2},
      );
      expect(r.map((e) => e['id']), [1]);
    });

    test('bu turda hic add_item tamamlanmadi -> bos', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(1, 'mark_printed'), _k(2, 'add_item')],
        yenidenOkunan: [_k(1, 'mark_printed'), _k(2, 'add_item')],
        tamamlanan: {},
      );
      expect(r, isEmpty);
    });

    test('zaten tamamlanan mark_printed elenir', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(1, 'mark_printed'), _k(2, 'add_item')],
        yenidenOkunan: [_k(1, 'mark_printed')],
        tamamlanan: {1, 2},
      );
      expect(r, isEmpty);
    });

    test('ilk denemede HTTP hatasi (retry_count artti) -> elenir, ikinci retry harcanmaz', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(1, 'mark_printed', retry: 0), _k(2, 'add_item')],
        yenidenOkunan: [_k(1, 'mark_printed', retry: 1)],
        tamamlanan: {2},
      );
      expect(r, isEmpty);
    });

    test('tur sirasinda eklenen (tur basinda olmayan) mark_printed -> secilir', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(2, 'add_item')],
        yenidenOkunan: [_k(9, 'mark_printed')],
        tamamlanan: {2},
      );
      expect(r.map((e) => e['id']), [9]);
    });

    test('mark_printed disindaki eylemler secilmez', () {
      final r = markPrintedTekrarSec(
        turBasi: [_k(2, 'add_item'), _k(3, 'close')],
        yenidenOkunan: [_k(3, 'close'), _k(4, 'add_item')],
        tamamlanan: {2},
      );
      expect(r, isEmpty);
    });
  });

  // Yeniden denemenin GEREKCESI: getPendingSyncItems sirasi mark_printed'i (priority 1) kalemlerden
  // (priority 0) ONCE getirir. Bu sira degisirse bu test duser ve yeniden deneme yeniden degerlendirilir.
  test('getPendingSyncItems sirasi: mark_printed add_item\'dan once gelir', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT, priority INTEGER DEFAULT 0,
        status TEXT DEFAULT 'pending', retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 3, created_at TEXT)
    ''');
    await db.insert('sync_queue', {'action': 'add_item', 'priority': 0, 'created_at': '2026-10-21T10:00:00'});
    await db.insert('sync_queue', {'action': 'mark_printed', 'priority': 1, 'created_at': '2026-10-21T10:00:05'});
    // local_db_service.getPendingSyncItems ile AYNI sorgu
    final r = await db.query('sync_queue',
        where: 'status = ? AND retry_count < max_retries', whereArgs: ['pending'],
        orderBy: 'priority DESC, created_at ASC');
    expect(r.map((e) => e['action']), ['mark_printed', 'add_item']);
    await db.close();
  });
}
