import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware_app/src/run/flag_memory.dart';
import 'package:flutterware_app/src/run/handle.dart';

KnobDescriptor knob(String name, {Object? value, Object? defaultValue}) =>
    KnobDescriptor(
      name: name,
      kind: KnobKind.boolean,
      value: value ?? false,
      defaultValue: defaultValue ?? false,
    );

RunHandle handleFor({
  String worktree = '/repo',
  String? package,
  String entrypoint = 'lib/main.dart',
  String device = 'macos',
}) => RunHandle(
  worktree: worktree,
  worktreeName: '~',
  device: device,
  entrypoint: entrypoint,
  package: package,
  launcherPid: 1,
  startedAt: DateTime(2026, 8, 11),
);

void main() {
  late Directory dir;
  late FlagMemory memory;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fw-flags-');
    memory = FlagMemory(dir.path);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String key([RunHandle? handle]) => FlagMemory.keyFor(handle ?? handleFor());

  test('a wish survives a new FlagMemory over the same directory', () {
    memory.wish(key(), 'newCheckout', true);

    expect(FlagMemory(dir.path).wishes(key()), {'newCheckout': true});
  });

  /// A flag is remembered per app, whatever entrypoint or device it was
  /// launched with. A flag you turned on for the simulator is one you
  /// meant for the app.
  test('entrypoint and device do not split a project memory', () {
    memory.wish(key(handleFor(entrypoint: 'lib/main_dev.dart')), 'flag', true);

    expect(memory.wishes(key(handleFor(device: 'iphone'))), {
      'flag': true,
    }, reason: 'same worktree, same package');
  });

  test('a different package in the same worktree keeps its own', () {
    memory.wish(key(handleFor(package: 'app')), 'flag', true);

    expect(memory.wishes(key(handleFor(package: 'admin'))), isEmpty);
  });

  test('a wish can be taken back, one at a time or all at once', () {
    memory
      ..wish(key(), 'a', true)
      ..wish(key(), 'b', 'x')
      ..forget(key(), 'a');
    expect(memory.wishes(key()), {'b': 'x'});

    memory.forgetAll(key());
    expect(memory.wishes(key()), isEmpty);
  });

  /// What makes the cockpit's list complete on the second run: a flag nobody
  /// has navigated to yet is still nameable.
  test('every knob ever reported is remembered, by shape not by value', () {
    memory.remember(key(), [knob('newCheckout', value: true)]);

    var remembered = memory.seen(key()).single;
    expect(remembered.name, 'newCheckout');
    expect(
      remembered.value,
      isFalse,
      reason: 'the run-time value is that run business, not durable state',
    );
  });

  test('remembering merges rather than replaces', () {
    memory
      ..remember(key(), [knob('a')])
      ..remember(key(), [knob('b')]);

    expect(memory.seen(key()).map((k) => k.name), ['a', 'b']);
  });

  test('an unreadable memory is an empty one, not a crash', () {
    File('${dir.path}/flags.json').writeAsStringSync('{ not json');

    expect(memory.wishes(key()), isEmpty);
    expect(memory.seen(key()), isEmpty);

    // And it heals: the next write replaces the rubbish.
    memory.wish(key(), 'a', 1);
    expect(memory.wishes(key()), {'a': 1});
  });
}
