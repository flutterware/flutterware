import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The settle policies on their own, driven through a plain `WidgetTester` —
/// the layer every verb delegates to.
void main() {
  testWidgets('a bounded settle gives up on an indefinite animation', (
    tester,
  ) async {
    await tester.pumpWidget(const _Spinner());

    // The measured trap: `pumpAndSettle` throws here, because a repeating
    // animation always has the next frame scheduled.
    expect(await Settle.standard.apply(tester), isFalse);
  });

  testWidgets('a bounded settle reports settled on a still app', (
    tester,
  ) async {
    await tester.pumpWidget(const _Still());

    expect(await Settle.standard.apply(tester), isTrue);
  });

  testWidgets('a bounded settle waits for a finite animation', (tester) async {
    await tester.pumpWidget(const _Fading());

    expect(await Settle.standard.apply(tester), isTrue);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
  });

  testWidgets('a budget shorter than the animation gives up mid-flight', (
    tester,
  ) async {
    await tester.pumpWidget(const _Fading());

    expect(
      await const Settle.upTo(Duration(milliseconds: 300)).apply(tester),
      isFalse,
    );
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1.0));
  });

  testWidgets('a bounded settle returns with a timer still pending', (
    tester,
  ) async {
    await tester.pumpWidget(const _SlowLoad(Duration(milliseconds: 200)));

    // True, and the load has not happened: a pending `Future.delayed` schedules
    // no frame, so 100ms is as far as the five-second budget gets.
    // `pumpAndSettle` measures identically — the SDK's contract, pinned here so
    // a change to it is a failing test rather than a surprise.
    expect(await Settle.standard.apply(tester), isTrue);
    expect(find.text('placeholder'), findsOneWidget);

    // Drained before the body returns, or the binding fails this test for the
    // very thing it is asserting.
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('Settle.elapse waits for work that schedules no frame', (
    tester,
  ) async {
    await tester.pumpWidget(const _SlowLoad(Duration(milliseconds: 200)));

    expect(
      await const Settle.elapse(Duration(seconds: 5)).apply(tester),
      isTrue,
    );
    expect(find.text('loaded'), findsOneWidget);
  });

  testWidgets('Settle.elapse spends the budget and no more', (tester) async {
    await tester.pumpWidget(const _SlowLoad(Duration(seconds: 10)));

    // Past the budget is past what any policy here waits for.
    expect(
      await const Settle.elapse(Duration(seconds: 5)).apply(tester),
      isTrue,
    );
    expect(find.text('placeholder'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });

  // `Settle.full` is `pumpAndSettle` itself, throw included — untested here
  // because the SDK's throw escapes its own `TestAsyncUtils.guard` after the
  // body returns and fails the test whatever the body does with it. That
  // behaviour is the SDK's, and it is exactly what the other policies exist
  // to avoid.

  testWidgets('Settle.none advances one frame and no clock', (tester) async {
    await tester.pumpWidget(const _Fading());
    var before = tester.widget<Opacity>(find.byType(Opacity)).opacity;

    expect(await Settle.none.apply(tester), isFalse);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, before);
  });

  testWidgets('Settle.frames advances exactly what it says', (tester) async {
    await tester.pumpWidget(const _Fading());

    // Two 100ms frames into a 1s fade.
    expect(await const Settle.frames(2).apply(tester), isFalse);
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      closeTo(0.2, 0.01),
    );
  });
}

class _Still extends StatelessWidget {
  const _Still();

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Text('still')));
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: CircularProgressIndicator()));
}

/// The shape a preview takes when it demonstrates a placeholder: a load that
/// finishes on a timer, and nothing scheduling frames until it does.
class _SlowLoad extends StatefulWidget {
  const _SlowLoad(this.delay);

  final Duration delay;

  @override
  State<_SlowLoad> createState() => _SlowLoadState();
}

class _SlowLoadState extends State<_SlowLoad> {
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      Future<void>.delayed(widget.delay).then((_) {
        if (mounted) setState(() => _loaded = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: Text(_loaded ? 'loaded' : 'placeholder')),
  );
}

/// A one-second fade that starts on its own — a finite animation, so a bounded
/// settle should ride it out.
class _Fading extends StatefulWidget {
  const _Fading();

  @override
  State<_Fading> createState() => _FadingState();
}

class _FadingState extends State<_Fading> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) =>
            Opacity(opacity: _controller.value, child: const Text('fading')),
      ),
    ),
  );
}
