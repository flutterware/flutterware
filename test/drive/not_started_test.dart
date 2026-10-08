import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/guest_drive.dart';

/// The window between the binding and `runApp`, which some apps never leave.
///
/// The generated wrapper installs the guest *around* the app's `main`, so
/// `ext.flutterware.act` is registered and answering before a single widget is
/// mounted. An app whose `main` throws — a config fetch against a dead port was
/// the reported case — stays there: the isolate lives, the VM service answers,
/// and every verb behind the extension walks a tree that is not there.
///
/// It used to answer `Null check operator used on a null value`, thrown by the
/// finder that `observe` runs. That is the worst sentence available — it names
/// flutterware for a failure in the app, and a consumer lost real time to it.
///
/// Plain `test`, not `testWidgets`, and that is the point. The test binding
/// mounts a `[root]` element of its own before the first `pumpWidget`, so
/// inside `testWidgets` this state cannot be reached at all; with only the
/// binding ensured, `rootElement` is null and `renderViews` is empty, which is
/// exactly what a real app looks like before `runApp`. A mounted app takes the
/// untouched path and is covered by every other drive and scenario test.
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('the state under test is the real one', () {
    expect(WidgetsBinding.instance.rootElement, isNull);
    expect(WidgetsBinding.instance.renderViews, isEmpty);
  });

  test('nothing mounted is a refusal that says so', () async {
    var guest = GuestDrive();

    var reply = await guest.debugDispatch({'verb': 'observe'});

    expect(reply['failure'], 'notStarted');
    expect(reply['error'], contains('runApp'));
    expect(
      reply['error'],
      contains('The app failed to start'),
      reason: 'it must say whose failure this is',
    );
    expect(
      reply['error'],
      isNot(contains('Null check')),
      reason: 'the crash it replaced',
    );
  });

  /// Every verb, not just `observe`: with nothing mounted there is no target to
  /// resolve either, so they all fail for one reason and get one sentence.
  test('a verb that needs a target is refused the same way', () async {
    var guest = GuestDrive();

    var reply = await guest.debugDispatch({'verb': 'tap', 'target': 'Log in'});

    expect(reply['failure'], 'notStarted');
    expect(reply['error'], contains('runApp'));
  });

  /// The half of the observation that does not need a tree is the half worth
  /// having here, so the reply is still shaped like a reply.
  test('the tree-shaped parts come back empty rather than crashing', () async {
    var guest = GuestDrive();

    var reply = await guest.debugDispatch({'verb': 'observe'});

    expect(reply['texts'], isEmpty);
    expect(reply['tree'], isNull);
    expect(reply['semantics'], isNull);
    expect(
      reply.containsKey('screenshot'),
      isTrue,
      reason: 'always taken, and null here rather than absent',
    );
  });
}
