import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/previews_results.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';

/// The audit's verdict on one rendered entry — in particular that a failed
/// network fetch, which `flutter_test`'s 400-for-everything binding makes
/// permanent, does not count the entry broken. Two such false positives out
/// of ninety were measured as enough to stop a consumer reading the audit.
void main() {
  test('a network-only failure is not a broken preview', () {
    var row = const PreviewAuditRow(
      id: 'demo/a.dart#A.new',
      errors: [
        {
          'exception': 'HTTP request failed, statusCode: 400, https://…',
          'library': 'image resource service',
          'network': true,
        },
      ],
    );
    expect(row.ok, isTrue);
    expect(row.indicting, isEmpty);
  });

  test('a real error still is, and keeps only its own entries', () {
    var row = const PreviewAuditRow(
      id: 'demo/a.dart#A.new',
      errors: [
        {
          'exception': 'HTTP request failed, statusCode: 400, https://…',
          'library': 'image resource service',
          'network': true,
        },
        {
          'exception': 'A RenderFlex overflowed by 7.8 pixels.',
          'library': 'rendering library',
        },
      ],
    );
    expect(row.ok, isFalse);
    expect(row.indicting, hasLength(1));
    expect('${row.indicting.single['exception']}', contains('RenderFlex'));
  });

  // The comparison refuses a frame taken while announced work was in flight.
  // An audit that passed the same entry called green what nothing can check.
  test('work still in flight when the harness stopped waiting is broken', () {
    var row = const PreviewAuditRow(
      id: 'demo/a.dart#A.new',
      pending: {
        'tracked': ['model import'],
      },
    );
    expect(row.ok, isFalse);
    expect(pendingWorkOf(row.pending), '`model import`');
  });

  test('the harness reply carries it, and an older one reads as none', () {
    var row = PreviewAuditRow.fromHarness('demo/a.dart#A.new', {
      'errors': <Object?>[],
      'pending': {'images': 2},
    });
    expect(row.pending, {'images': 2});
    expect(row.ok, isFalse);

    var older = PreviewAuditRow.fromHarness('demo/a.dart#A.new', {
      'errors': <Object?>[],
    });
    expect(older.pending, isEmpty);
    expect(older.ok, isTrue);
  });

  test('the audit entry says what it was waiting on, and only then', () {
    var waiting = CatalogAuditEntry(
      id: 'demo/a.dart#A.new',
      address: 'fw:///x',
      compiles: true,
      stillWaitingOn: pendingWorkOf({'images': 2}),
    );
    expect(waiting.toJson()['stillWaitingOn'], '2 image decodes');

    var landed = CatalogAuditEntry(
      id: 'demo/a.dart#A.new',
      address: 'fw:///x',
      compiles: true,
    );
    expect(landed.toJson().containsKey('stillWaitingOn'), isFalse);
  });

  test('a failure or compile error is never excused by the mark', () {
    expect(const PreviewAuditRow(id: 'a', failure: 'timed out').ok, isFalse);
    expect(const PreviewAuditRow(id: 'a', compileError: 'nope').ok, isFalse);
  });
}
