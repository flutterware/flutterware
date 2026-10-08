import 'package:flutterware/src/app_events/events.dart';
import 'package:test/test.dart';

/// Where an event was made, and the rules that keep it worth having.
void main() {
  setUp(() => appEventBuffer = AppEventBuffer());
  tearDown(() => appEventBuffer = null);

  /// Stands in for an app's own fake, which is what calls [recordAppEvent].
  void reportFromTheApp() =>
      recordAppEvent(AppEvent.request(method: 'GET', url: '/cart'));

  test('the origin names the app frame, not flutterware and not dart:', () {
    reportFromTheApp();

    var origin = appEventBuffer!.drain().$1.single.origin!;
    expect(origin, contains('event_origin_test.dart'));
    expect(origin, contains('reportFromTheApp'));
    expect(origin, isNot(contains('package:flutterware/')));
    expect(origin, isNot(startsWith('dart:')));
  });

  // A line moves whenever anything above it does, so keeping one would make
  // every event in a file read as changed after any edit — and the origin is
  // for excluding a *file*, which a line number does not help with.
  test('the origin keeps the file and the symbol, and drops the line', () {
    reportFromTheApp();

    var origin = appEventBuffer!.drain().$1.single.origin!;
    expect(origin, isNot(matches(RegExp(r':\d+:\d+'))));
    expect(origin.split(' '), hasLength(2));
  });

  // Capturing a stack is ~20x cheaper than symbolising it, so the capture
  // happens for every recorded event and the resolution only for those that
  // survive the caps and are about to be written.
  test('an event dropped by the cap never reaches the expensive half', () {
    for (var i = 0; i < maxAppEventsPerStep + 10; i++) {
      reportFromTheApp();
    }

    var (events, dropped) = appEventBuffer!.drain();
    expect(events, hasLength(maxAppEventsPerStep));
    expect(dropped, 10);
  });

  // A production app and a plain `flutter test` have no buffer, so the capture
  // never happens and nothing anywhere carries an origin.
  test('with no buffer listening there is no origin and no cost', () {
    appEventBuffer = null;
    var seen = <AppEvent>[];
    var stop = addAppEventListener(seen.add);

    reportFromTheApp();
    stop();

    expect(seen.single.origin, isNull);
  });

  test('a trace an async gap cut leaves the origin null, not wrong', () {
    expect(
      originOf(StackTrace.fromString('<asynchronous suspension>')),
      isNull,
    );
  });

  test('the origin survives the round trip a comparison reads it through', () {
    reportFromTheApp();

    var event = appEventBuffer!.drain().$1.single;
    var json = event.toJson();

    expect(json['origin'], event.origin);
    expect(AppEvent.fromJson(json).origin, event.origin);
  });
}
