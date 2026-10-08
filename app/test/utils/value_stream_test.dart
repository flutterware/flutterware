import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/utils/value_stream.dart';

void main() {
  test('value is readable synchronously, without subscribing', () {
    var source = ValueStream<int>(1);
    expect(source.value, 1);
    source.value = 2;
    expect(source.value, 2);
    expect(source.hasListeners, isFalse);
  });

  test('a subscriber is replayed the current value', () async {
    var source = ValueStream<int>(7);
    expect(await source.stream.first, 7);
  });

  test('a late subscriber gets the latest value, not the first', () async {
    var source = ValueStream<int>(1);
    source.value = 2;
    source.value = 3;
    expect(await source.stream.first, 3);
  });

  test('subscribers see the replay followed by every change', () async {
    var source = ValueStream<int>(1);
    var seen = <int>[];
    var subscription = source.listen(seen.add);
    await pumpEventQueue();

    source.value = 2;
    source.value = 3;
    await pumpEventQueue();

    expect(seen, [1, 2, 3]);
    await subscription.cancel();
  });

  test('two subscribers both see every value', () async {
    var source = ValueStream<int>(1);
    var a = <int>[], b = <int>[];
    var subA = source.listen(a.add);
    var subB = source.listen(b.add);
    await pumpEventQueue();

    source.value = 2;
    await pumpEventQueue();

    expect(a, [1, 2]);
    expect(b, [1, 2]);
    await subA.cancel();
    await subB.cancel();
  });

  test('setting an equal value does not notify', () async {
    var source = ValueStream<int>(1);
    var seen = <int>[];
    var subscription = source.listen(seen.add);
    await pumpEventQueue();

    source.value = 1;
    await pumpEventQueue();
    expect(seen, [1]);

    source.emit(1);
    await pumpEventQueue();
    expect(seen, [1, 1], reason: 'emit publishes unconditionally');

    await subscription.cancel();
  });

  group('laziness', () {
    test(
      'work starts on the first subscriber and stops after the last',
      () async {
        var started = 0, stopped = 0;
        var source = ValueStream<int>(
          0,
          onListen: () => started++,
          onCancel: () => stopped++,
        );

        expect(started, 0, reason: 'constructing must not start work');

        var a = source.listen((_) {});
        await pumpEventQueue();
        expect(started, 1);

        var b = source.listen((_) {});
        await pumpEventQueue();
        expect(started, 1, reason: 'a second subscriber does not restart it');

        await a.cancel();
        await pumpEventQueue();
        expect(stopped, 0, reason: 'one subscriber remains');

        await b.cancel();
        await pumpEventQueue();
        expect(stopped, 1);
      },
    );

    test('reading value never starts work', () async {
      var started = 0;
      var source = ValueStream<int>(0, onListen: () => started++);
      expect(source.value, 0);
      expect(started, 0);
    });

    test('subscribing again restarts work', () async {
      var started = 0;
      var source = ValueStream<int>(0, onListen: () => started++);
      await source.listen((_) {}).cancel();
      await pumpEventQueue();
      await source.listen((_) {}).cancel();
      await pumpEventQueue();
      expect(started, 2);
    });
  });

  test('errors reach subscribers and leave the value alone', () async {
    var source = ValueStream<int>(1);
    Object? seenError;
    var values = <int>[];
    var subscription = source.listen(
      values.add,
      onError: (Object e) {
        seenError = e;
      },
    );
    await pumpEventQueue();

    source.addError(StateError('boom'));
    await pumpEventQueue();

    expect(seenError, isStateError);
    expect(source.value, 1);
    expect(values, [1]);
    await subscription.cancel();
  });

  group('close', () {
    test('subscribers are done and the value stays readable', () async {
      var source = ValueStream<int>(5);
      var done = false;
      source.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();

      await source.close();
      await pumpEventQueue();

      expect(done, isTrue);
      expect(source.isClosed, isTrue);
      expect(source.value, 5);
    });

    test('subscribing after close replays the value, then completes', () async {
      var source = ValueStream<int>(5);
      await source.close();
      expect(await source.stream.toList(), [5]);
    });

    test('emitting after close throws', () async {
      var source = ValueStream<int>(1);
      await source.close();
      expect(() => source.emit(2), throwsStateError);
    });
  });
}
