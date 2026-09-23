import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/real_work/tracker.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// Work the app announces with `RealWork.track` lands on the step that
/// started it, however long it takes — where the guessed turns would have
/// given up.
///
/// The load is a chain of root-zone delays with no frame between them, which
/// is the shape a model import has: several reads, one `setState` at the end.
/// Twelve guessed turns of the real loop cost ~30ms together and reset only
/// on a frame, so a frameless 120ms chain is past what guessing lands and
/// exactly what announcing does.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() {
    scenarioRunListener = null;
    resetTrackedRealWork();
  });

  group('a tracked load lands on the step that started it', () {
    scenario('so the first picture is the loaded one', (s) async {
      await s.pumpWidget(const _App(track: true));
      expect(find.text('Loaded'), findsOneWidget);
    });
    tearDown(() {
      expect(captures, hasLength(1));
      expect(captures.single.texts, contains('Loaded'));
      expect(captures.single.landed, isTrue);
      expect(captures.single.settled, isTrue);
      expect(RealWork.pending, 0);
    });
  });

  group('a tracked future that fails is forgotten too', () {
    scenario("and the failure stays the caller's", (s) async {
      var failing = RealWork.track(
        Future<void>.error(StateError('no model')),
        label: 'broken',
      );
      await expectLater(failing, throwsStateError);
      await s.pumpWidget(const _App(track: false));
    });
    tearDown(() => expect(RealWork.pending, 0));
  });

  test('a pending future is listed by its label', () {
    var completer = Completer<void>();
    RealWork.track(completer.future, label: 'scene model');
    expect(RealWork.pending, 1);
    expect(RealWork.pendingWork.single.label, 'scene model');
    expect('${RealWork.pendingWork.single}', 'scene model');
    resetTrackedRealWork();
    expect(RealWork.pending, 0);
    completer.complete();
  });
}

class _App extends StatefulWidget {
  const _App({required this.track});

  final bool track;

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    var load = _load();
    if (widget.track) RealWork.track(load, label: 'model');
  }

  Future<void> _load() async {
    for (var i = 0; i < 3; i++) {
      // Off the fake clock, and no frame asked for until the very end.
      await Zone.root.run(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: Center(child: Text(_loaded ? 'Loaded' : 'Loading'))),
  );
}
