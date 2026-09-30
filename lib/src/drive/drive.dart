import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scenarios/target.dart';
import 'lane.dart';
import 'live_settle.dart';
import 'resolve.dart';

/// What one drive verb did — the engine half of a journal step. The wire and
/// observation bundle live with the guest extensions, not here.
class DriveStep {
  DriveStep({
    required this.verb,
    required this.settle,
    required this.elapsed,
    this.target,
    this.attempts = 1,
  });

  final String verb;
  final String? target;

  /// Resolve attempts the actionability retry ladder spent, 1 when the first
  /// try reached the target.
  final int attempts;

  final LiveSettleResult settle;

  /// Whole transaction: retries + act + settle.
  final Duration elapsed;

  Map<String, Object?> toJson() => {
    'verb': verb,
    if (target != null) 'target': target,
    'attempts': attempts,
    'elapsedMs': elapsed.inMilliseconds,
    'settle': settle.toJson(),
  };
}

/// The live half of the verb engine: scenarios' vocabulary — same targets,
/// same actionability ladder, same refusal wording — executed against a
/// running app's real `WidgetsBinding`.
///
/// The one behavioral difference from a scenario is time. A scenario's screen
/// is settled by construction when a verb runs; a live screen is mid-flight —
/// a route transition holds an `IgnorePointer` up and both pages are briefly
/// in the tree — so every refusal here is treated as possibly transient:
/// resolve + reachability retry until [actTimeout], settling between attempts
/// (a plain wait advances zero frames on a hidden window), and only the
/// deadline surfaces the error. Measured: taps land on the first frame a
/// transition releases them (`2026-08-11-run-drive-spike-findings.md`).
///
/// **Where it runs is a [DriveLane].** The default is the live one; a
/// [TesterLane] runs the same verbs under a widget test's fake clock, which is
/// how a preview reaches a state before it is photographed.
class Drive {
  Drive({WidgetsBinding? binding})
    : this.on(LiveLane(binding ?? WidgetsBinding.instance));

  Drive.on(this.lane) : controller = lane.controller;

  final DriveLane lane;
  final WidgetController controller;

  /// Deadline for the resolve/reachability retry ladder.
  var actTimeout = const Duration(seconds: 3);

  /// Settle budget between retry attempts.
  var retryPump = const Duration(milliseconds: 60);

  /// Default settle budget after an act.
  var settleBudget = const Duration(milliseconds: 800);

  /// Default hold for [hover] and [unhover] — real elapsed time, not a settle.
  ///
  /// 600ms because that is the top of the range apps actually configure:
  /// Flutter's own `Tooltip.waitDuration` default is zero, and the themes that
  /// set one land between 300 and 600. The hold stops the moment the app
  /// reacts, so this is what an *unreactive* control costs, not what a tooltip
  /// costs.
  var hoverHold = const Duration(milliseconds: 600);

  /// Default gap between [doubleTap]'s two taps — real elapsed time, and the
  /// one thing about that verb that is not free to be zero.
  ///
  /// 80ms sits in the middle of the only window that works: above
  /// `kDoubleTapMinTime` (40ms), below which the recognizer treats the pair as
  /// one restarted tap, and well under `kDoubleTapTimeout` (300ms), after
  /// which it is two separate taps.
  var doubleTapGap = const Duration(milliseconds: 80);

  SemanticsHandle? _semantics;

  /// Lets go of what a verb took hold of for the rest of the drive's life —
  /// the semantics tree a `{"label"}` target turned on.
  ///
  /// A live app keeps it for as long as it runs, and never needs this. A
  /// widget test does: it fails a body that ends with a handle open, so a
  /// drive on a [TesterLane] is disposed before its body returns.
  void dispose() {
    _semantics?.dispose();
    _semantics = null;
  }

  late final TargetResolver _resolver = TargetResolver(
    controller,
    messages: const TargetMessages(
      narrowHint:
          'Narrow it: `{"nth": {"target": <the same target>, "index": <the '
          'number above>}}`, or `{"at": {"x": …, "y": …}}` with the centre of '
          'one of those boxes. `{"within": {"scope": …, "child": …}}` picks '
          'the one inside a named pane, and `item: <n>` acts on a numbered '
          "thing from the last reply's screen.",
      blankScreenHint:
          'Nothing has rendered in the widget tree — there is no text on '
          'screen at all, so this is not something `scrollTo` can reach. '
          'Either the app has not drawn yet, or what you are looking at is '
          'not Flutter: a permission dialog, a webview or a map is invisible '
          'here and addressable with `layer: native`.',
    ),
    describeScreen: _describeScreen,
    ensureSemantics: () async {
      _semantics ??= controller.binding.ensureSemantics();
      await lane.settle(const Duration(milliseconds: 100));
    },
  );

  Future<DriveStep> tap(dynamic target, {Duration? settle}) {
    return _act(
      'tap',
      target,
      settle,
      (finder) => controller.tapAt(_contact(target, finder)),
    );
  }

  /// Two taps in the same place, close enough together to read as one gesture.
  ///
  /// The gap between them is real elapsed time and cannot be skipped.
  /// `DoubleTapGestureRecognizer` *restarts* rather than fires when the second
  /// tap arrives inside `kDoubleTapMinTime` — 40ms, there because a touch
  /// screen reports one long touch intermittently and that rule is what tells
  /// the two apart. So [gap] defaults above it, with room left inside
  /// `kDoubleTapTimeout` (300ms), which the whole gesture must still fit in.
  ///
  /// A touch rather than a mouse double-click, like [tap]: `onDoubleTap`
  /// accepts either, and keeping the same pointer as [tap] makes this exactly
  /// "tap twice" on a phone as much as on a desktop.
  Future<DriveStep> doubleTap(
    dynamic target, {
    Duration? gap,
    Duration? settle,
  }) {
    return _act('doubleTap', target, settle, (finder) async {
      // Resolved once and reused: the second tap has to land inside
      // `kDoubleTapSlop` of the first, and re-reading the centre would follow
      // a widget that the first tap moved.
      var at = _contact(target, finder);
      await controller.tapAt(at);
      await lane.elapse(gap ?? doubleTapGap);
      await controller.tapAt(at);
    });
  }

  Future<DriveStep> longPress(dynamic target, {Duration? settle}) {
    return _act(
      'longPress',
      target,
      settle,
      (finder) => controller.longPressAt(_contact(target, finder)),
    );
  }

  /// A right-click — the mouse's other button, and the way a context menu is
  /// asked for on every desktop.
  ///
  /// The synthetic mouse is moved there and clicks, which is what a mouse does
  /// and what `onSecondaryTap` is waiting for. It is the same pointer [hover]
  /// uses, so the click leaves the target hovered — a context menu that opens
  /// under the cursor sees the cursor where it should be — and [unhover] is
  /// what ends that.
  Future<DriveStep> secondaryTap(dynamic target, {Duration? settle}) {
    return _act('secondaryTap', target, settle, (finder) async {
      var at = _contact(target, finder);
      await controller.sendEventToBinding(_mouse.hover(at));
      _hovering = describeTarget(target);
      try {
        await controller.sendEventToBinding(
          _mouse.down(at, buttons: kSecondaryButton),
        );
      } finally {
        // A pointer left down wedges every later mouse verb — `TestPointer`
        // asserts a hover is only generated while it is up.
        if (_mouse.isDown) await controller.sendEventToBinding(_mouse.up());
      }
    });
  }

  /// Parks a mouse over [target] and holds it there, so whatever the app only
  /// shows to a mouse has time to appear.
  ///
  /// Nothing about a live app has to cooperate for this to work:
  /// `RendererBinding.dispatchEvent` feeds every pointer event to
  /// [MouseTracker] before dispatching it, so a synthesized [PointerHoverEvent]
  /// drives `MouseRegion`, `InkWell.onHover`, a `Tooltip` and every
  /// `WidgetState.hovered` exactly as the platform's own mouse does. A tooltip
  /// is an `OverlayEntry`, which means it lands in the reply's texts like any
  /// other widget — a hover is how "does this control explain itself" becomes
  /// a question with a machine-readable answer.
  ///
  /// [hold] is time on the lane's clock — real on a live app, exact on a
  /// tester — which is why it exists at all. A settle waits on frames, tickers and image decodes; the interesting half
  /// of a hover is very often a `Timer` — `Tooltip.waitDuration` — which
  /// schedules none of the three until it fires. Measured on an app whose theme
  /// sets 400ms: hover-and-settle reported `settled: true` at 80ms with no
  /// tooltip on screen, every time. See [DriveLane.hold] for what the hold
  /// actually watches.
  ///
  /// The pointer stays where it is put. A mouse does not leave the screen
  /// because you pressed a key, so the hover outlives its step: a `tap` that
  /// follows still sees the control hovered, which is what you want when the
  /// thing to tap only appears on hover — and a `navigate` that follows leaves
  /// whatever is now under that coordinate hovered, which is not. Call
  /// [unhover] to end it.
  Future<DriveStep> hover(dynamic target, {Duration? hold, Duration? settle}) {
    return _act('hover', target, settle, (finder) async {
      await controller.sendEventToBinding(
        _mouse.hover(_contact(target, finder)),
      );
      _hovering = describeTarget(target);
      await lane.hold(hold ?? hoverHold);
    });
  }

  /// Takes the synthetic mouse off the screen, so everything it was hovering
  /// gets its exit.
  ///
  /// A no-op when nothing is parked, rather than a refusal: "there is no hover
  /// to end" is the state the caller wanted, and nothing about the screen is
  /// ambiguous. The step names what it released so the journal line reads
  /// `unhover "Save"`.
  Future<DriveStep> unhover({Duration? hold, Duration? settle}) async {
    var watch = Stopwatch()..start();
    var released = _hovering;
    if (released != null) {
      await controller.sendEventToBinding(_mouse.removePointer());
      _hovering = null;
      // Held for the same reason the enter is: a `Tooltip` dismisses on a
      // timer too (`_hoverExitDuration`), so an unhover that only settled
      // would come back with the tooltip still on screen.
      await lane.hold(hold ?? hoverHold);
    }
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(
      verb: 'unhover',
      target: released,
      settle: result,
      elapsed: watch.elapsed,
    );
  }

  /// Turns the mouse wheel over [target].
  ///
  /// Not a nicer [drag], and not [scrollTo]. A wheel turn is a pointer
  /// *signal*: the framework hit-tests it to whatever is under the pointer and
  /// hands it to that, so this is the verb that makes "scroll *this* pane"
  /// expressible. [scrollTo] picks a `Scrollable` and walks it, which is the
  /// right thing when the question is "get X on screen" and the wrong thing
  /// when the page has three scrollables and you mean the middle one.
  ///
  /// [by] is a wheel, not a finger, and the sign is the other way round.
  /// The delta is added to the scroll offset, so a positive `dy` moves *down*
  /// the list — where [drag]'s negative `dy` moves the finger up the screen to
  /// achieve the same thing. Both conventions are the platform's; neither is
  /// this engine's to change.
  ///
  /// The pointer is moved there first, because that is how a wheel reaches
  /// anything — so a scroll leaves the target hovered, exactly as a real mouse
  /// does, and [unhover] ends that.
  Future<DriveStep> scroll(dynamic target, Offset by, {Duration? settle}) {
    return _act('scroll', target, settle, (finder) async {
      await controller.sendEventToBinding(
        _mouse.hover(_contact(target, finder)),
      );
      _hovering = describeTarget(target);
      await controller.sendEventToBinding(_mouse.scroll(by));
    });
  }

  /// What the synthetic mouse is parked over, or null when it is off screen.
  String? get hovering => _hovering;
  String? _hovering;

  /// The synthetic mouse, made on first use.
  ///
  /// Its device id is deliberately not one an embedder produces. Every
  /// desktop embedder numbers its real mouse 0; [MouseTracker] keeps one state
  /// per device and asserts that an added event only ever follows a removed
  /// one. Sharing the human's device would make [unhover] delete a state the
  /// engine still believes it owns, and the human's next `PointerAddedEvent` —
  /// moving their real mouse back over the window — would fire that assert
  /// inside their app. The cost of the separate device is that the agent's
  /// hover and the human's coexist, so two things can read as hovered at once
  /// while they co-drive. That is the cheaper of the two.
  TestPointer get _mouse => _mousePointer ??= TestPointer(
    _mousePointerId,
    ui.PointerDeviceKind.mouse,
    _mouseDevice,
  );
  TestPointer? _mousePointer;

  static const _mouseDevice = 1000;
  static const _mousePointerId = 1000;

  Future<DriveStep> drag(dynamic target, Offset by, {Duration? settle}) {
    return _act(
      'drag',
      target,
      settle,
      (finder) => controller.dragFrom(_contact(target, finder), by),
    );
  }

  /// Scrolls until [target] is on screen. Same contract as the scenario verb:
  /// the target may match nothing yet — being off screen is the reason to call
  /// it — and a target already on screen is a no-op, whether or not anything
  /// scrolls.
  Future<DriveStep> scrollTo(
    dynamic target, {
    dynamic within,
    double step = 200,
    int maxScrolls = 50,
    Duration? settle,
  }) async {
    var watch = Stopwatch()..start();
    var scrollable = within == null
        ? find.byType(Scrollable)
        : find.descendant(
            of: finderForTarget(within),
            matching: find.byType(Scrollable),
            matchRoot: true,
          );
    if (scrollable.evaluate().isEmpty) {
      var refusal = refusalWhenNothingScrolls(
        finderForTarget(target),
        describeTarget(target),
        within,
        _resolver.messages,
      );
      if (refusal != null) throw refusal;
      // Already on screen: nothing to walk, nothing to do — the same no-op
      // the scenario verb makes, so a flow ported between the two engines
      // keeps working on its short pages.
      var settled = await lane.settle(settle ?? settleBudget);
      return DriveStep(
        verb: 'scrollTo',
        target: describeTarget(target),
        settle: settled,
        elapsed: watch.elapsed,
      );
    }
    var finder = finderForTarget(target);
    // Built but behind the viewport: the walk only drags one way, so jump —
    // same reasoning, same helper as the scenario verb. The recheck waits
    // for a frame first, since the reveal is only geometry after layout.
    if (finder.evaluate().isEmpty) {
      if (scrolledPastTarget(finder, scrollable) case var behind?) {
        await Scrollable.ensureVisible(behind);
        var settled = await lane.settle(settle ?? settleBudget);
        if (finder.evaluate().isNotEmpty) {
          return DriveStep(
            verb: 'scrollTo',
            target: describeTarget(target),
            settle: settled,
            elapsed: watch.elapsed,
          );
        }
      }
    }
    try {
      await controller.scrollUntilVisible(
        finder,
        step,
        scrollable: scrollable.first,
        maxScrolls: maxScrolls,
      );
    } on StateError {
      throw TargetError(
        TargetFailure.notFound,
        _resolver.messages.scrollExhausted(
          maxScrolls,
          step,
          describeTarget(target),
        ),
      );
    }
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(
      verb: 'scrollTo',
      target: describeTarget(target),
      settle: result,
      elapsed: watch.elapsed,
    );
  }

  /// Focuses the field at [target] and sets [text] as one editing value, the
  /// way a widget reports an edit the user made.
  ///
  /// Both halves have to be told, which is why this is not
  /// `TextInput.updateEditingValue`. That call is control-side: it pushes a
  /// value *into* the framework, and the platform's own editing state — the
  /// `UITextField`/`InputConnection` shadow the IME edits against — never
  /// hears about it. Measured on both an iOS simulator and an Android
  /// emulator (2026-08-11): after the agent wrote a sentence, the human's
  /// next keystroke on the soft keyboard *replaced* it, because as far as the
  /// platform knew the field was still empty. On a desktop with no soft
  /// keyboard this goes unnoticed; on a phone it breaks co-driving, which is
  /// the workflow this surface exists for.
  ///
  /// [EditableTextState.userUpdateTextEditingValue] is the framework's own
  /// name for "a user edit that did not come from the platform": it runs the
  /// input formatters, fires `onChanged`, and — through `endBatchEdit` —
  /// calls `setEditingState` on the live input connection, so the IME's next
  /// edit is a delta against what is actually on screen. It needs the
  /// connection to exist, which is what [EditableTextState.requestKeyboard]
  /// below is for.
  Future<DriveStep> enterText(dynamic target, String text, {Duration? settle}) {
    return _act('enterText', target, settle, (finder) async {
      var elements = editableWithin(finder).evaluate().toList();
      if (elements.length != 1) {
        throw TargetError(
          TargetFailure.notFound,
          '${describeTarget(target)} contains ${elements.length} text fields, '
          'and `enterText` needs one.',
        );
      }
      var state =
          (elements.single as StatefulElement).state as EditableTextState;
      state.requestKeyboard();
      // Focus and the input connection apply over a frame; give them one.
      await lane.settle(const Duration(milliseconds: 100));
      state.userUpdateTextEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
        SelectionChangedCause.keyboard,
      );
    });
  }

  /// One keystroke — `escape`, `enter`, `meta+k`, `shift+tab`.
  ///
  /// [chord] is `+`-separated: the last name is the key that fires, everything
  /// before it is held down for it and released after, in reverse. Names are
  /// `LogicalKeyboardKey` debug names spelled any way that reads (`arrowDown`,
  /// `Arrow Down`), a single character (`k`), or one of the shorthands people
  /// actually type — `cmd`, `ctrl`, `alt`, `opt`, `shift`, `esc`. A shorthand
  /// modifier resolves to its **left** key, which is what every `SingleActivator`
  /// checks for. A Mac shortcut and its Windows/Linux twin are different chords:
  /// `meta+k` and `control+k`.
  ///
  /// This is for shortcuts and navigation, not for typing. A character
  /// does not reach a text field through a key event on any platform — the
  /// platform's text input sends the edit, and the key event is a separate
  /// thing that happens to accompany it. So `key('a')` into a focused
  /// `TextField` leaves it empty, here and in a real app; [enterText] is the
  /// verb that types. What this is for is `escape`, `tab`, the arrows,
  /// `enter`, and every `Shortcuts` binding the app declares.
  ///
  /// `flutter_test`'s `simulateKeyDownEvent` cannot be used here, which is why
  /// this reimplements it. It always also sends the raw key message, and it
  /// sends it through `TestDefaultBinaryMessengerBinding.instance` — which, in a
  /// process whose binding is the real `WidgetsFlutterBinding`, throws
  /// `'_debugInitializedType == null': is not true`. Measured, first attempt.
  ///
  /// See [_sendKey] for the two halves a keystroke is, and why one of them is
  /// not enough.
  Future<DriveStep> key(String chord, {Duration? settle}) async {
    var watch = Stopwatch()..start();
    var names = [
      for (var name in chord.split('+'))
        if (name.trim().isNotEmpty) name.trim(),
    ];
    if (names.isEmpty) {
      throw TargetError(
        TargetFailure.notFound,
        '`key` needs something to press: a key name, or a chord like '
        '`meta+k` — the last name fires and the ones before it are held.',
      );
    }
    var trigger = _logicalKey(names.removeLast());
    var modifiers = [for (var name in names) _logicalKey(name)];
    // **Every key in the chord is checked before any of them is sent**, so a
    // refusal never leaves half a chord pressed.
    for (var key in [...modifiers, trigger]) {
      _checkSimulatable(key);
      // **Refused rather than injected on top.** A down for a key the human is
      // physically holding leaves the framework's idea of the keyboard wrong
      // the moment this releases it — and this is a surface two people drive
      // at once.
      if (HardwareKeyboard.instance.physicalKeysPressed.contains(
        _physicalKey(key),
      )) {
        throw TargetError(
          TargetFailure.covered,
          '${key.debugName} is already held down — the human has a finger on '
          'it, or a previous chord was interrupted. Pressing it again would '
          'leave the keyboard in a state neither of you meant. Let go and '
          'retry.',
        );
      }
    }

    var pressed = <LogicalKeyboardKey>[];
    var handled = false;
    try {
      for (var modifier in modifiers) {
        await _sendKey(modifier, down: true);
        pressed.add(modifier);
      }
      handled = await _sendKey(trigger, down: true, typing: modifiers.isEmpty);
      pressed.add(trigger);
    } finally {
      // In a `finally`, and only for what actually went down: a key left
      // pressed is state the human inherits for the rest of the run.
      for (var key in pressed.reversed) {
        await _sendKey(key, down: false);
      }
    }

    // **The one way this verb can silently do nothing, caught.** Key events
    // dispatch from whatever holds primary focus and bubble to its *ancestors*.
    // With nothing focused that is the root scope, which sits above the app's
    // `Shortcuts` — so every binding in the app is missed and the keystroke
    // lands nowhere. On a window that was launched hidden, or that the human
    // has never clicked, that is the *normal* state rather than an edge case:
    // measured on a real app, ⌘K did nothing three times running until one
    // `enterText` put focus in a field, and then opened the palette.
    //
    // Both halves are needed. Plenty of keystrokes are legitimately unhandled —
    // a letter typed at nothing, an Escape with no binding — so `handled` alone
    // would refuse constantly; and an app can handle a key through a
    // `HardwareKeyboard` handler with nothing focused at all, so the focus
    // alone would refuse wrongly. Together they mean the dispatch never reached
    // the app's tree and nothing else took it either.
    if (!handled && _nothingFocused) {
      throw TargetError(
        TargetFailure.notFound,
        'the keystroke went nowhere: nothing in the app holds focus, so it '
        "dispatched from the root scope — which sits *above* the app's "
        '`Shortcuts`, and above everything else that would have taken it. Give '
        'the app a focus first and retry: `tap` a control, or `enterText` into '
        'a field. (A window that was launched hidden, or that nobody has '
        'clicked, starts out like this.) The keys were pressed and released, '
        'so nothing is stuck.',
      );
    }

    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(
      verb: 'key',
      target: chord,
      settle: result,
      elapsed: watch.elapsed,
    );
  }

  static bool get _nothingFocused {
    var focus = FocusManager.instance.primaryFocus;
    return focus == null || focus == FocusManager.instance.rootScope;
  }

  /// One key transition, delivered the way the engine delivers one: the
  /// `KeyData` first, then the raw `flutter/keyevent` message. Answers whether
  /// anything took it.
  ///
  /// Both halves are required, and that is the whole finding.
  /// `KeyEventManager.handleKeyData` does not dispatch a non-synthesized event —
  /// it *queues* it and waits for the raw message that always follows on a real
  /// platform. Measured: `metaLeft` + `keyK` through `handleKeyData` alone
  /// reached no `Shortcuts` binding and changed nothing on screen. The raw
  /// message is what flushes the queue, dispatches, and answers `handled`.
  ///
  /// Three things worth knowing before changing this:
  ///
  /// - **`keyEventManager` is deprecated and is nonetheless the only door.**
  ///   Its replacement, `HardwareKeyboard.addHandler`, reaches `HardwareKeyboard`
  ///   listeners and stops there: `FocusManager` registers itself on
  ///   `keyEventManager.keyMessageHandler`, so nothing that goes around it ever
  ///   reaches `Shortcuts`, `Actions` or a focused `TextField`. A Flutter
  ///   release that removes these members takes this verb with it.
  /// - **The manager is called directly rather than through its channel.**
  ///   `handleRawKeyMessage` *is* the handler `ServicesBinding` puts on
  ///   `SystemChannels.keyEvent`, so this is the same code either way — but a
  ///   `channelBuffers.push` invokes it in the zone the listener was registered
  ///   in and answers back through that zone, which under a test binding's
  ///   `FakeAsync` never completes. Calling it here keeps the reply in the
  ///   caller's zone, and keeps `handled` observable in a widget test.
  /// - **The first keystroke of a run decides the process's transit mode.**
  ///   `KeyEventManager` latches onto whichever kind of message it sees first
  ///   and asserts on the other for the rest of the isolate's life. Sending the
  ///   `KeyData` first latches `keyDataThenRawKeyData` — which is what every
  ///   embedder Flutter currently ships does, so the human's own keyboard keeps
  ///   working. Sending only the raw message would latch the legacy mode and
  ///   then crash on the engine's next real key.
  Future<bool> _sendKey(
    LogicalKeyboardKey key, {
    required bool down,
    bool typing = false,
  }) async {
    var label = key.keyLabel;
    // A chord types nothing: ⌘K produces no character on a real keyboard, and
    // a field that took one would end up with a stray "k" in it.
    var character = down && typing && label.length == 1 ? label : '';
    var manager =
        // ignore: deprecated_member_use
        ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    manager.handleKeyData(
      ui.KeyData(
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: _physicalKey(key).usbHidUsage,
        logical: key.keyId,
        timeStamp: Duration.zero,
        character: character.isEmpty ? null : character,
        synthesized: false,
      ),
    );
    // ignore: deprecated_member_use
    var answer = await manager.handleRawKeyMessage(
      KeyEventSimulator.getKeyData(
        key,
        platform: _keyPlatform,
        isDown: down,
        character: character,
      ),
    );
    return answer['handled'] == true;
  }

  /// Which key table [KeyEventSimulator] should build the raw message from.
  static String get _keyPlatform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => 'macos',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.fuchsia => 'fuchsia',
      TargetPlatform.linux => 'linux',
      TargetPlatform.windows => 'windows',
    };
  }

  /// The spellings people reach for that are not a `LogicalKeyboardKey` debug
  /// name. Each modifier resolves to its **left** key, which is the one every
  /// `SingleActivator` is satisfied by — `isMetaPressed` is
  /// `metaLeft || metaRight`.
  static const _keyAliases = {
    'cmd': 'Meta Left',
    'command': 'Meta Left',
    'meta': 'Meta Left',
    'win': 'Meta Left',
    'ctrl': 'Control Left',
    'control': 'Control Left',
    'alt': 'Alt Left',
    'opt': 'Alt Left',
    'option': 'Alt Left',
    'shift': 'Shift Left',
    'esc': 'Escape',
    'return': 'Enter',
    'up': 'Arrow Up',
    'down': 'Arrow Down',
    'left': 'Arrow Left',
    'right': 'Arrow Right',
    'del': 'Delete',
  };

  static LogicalKeyboardKey _logicalKey(String name) {
    var wanted = (_keyAliases[name.toLowerCase()] ?? name)
        .toLowerCase()
        .replaceAll(' ', '');
    for (var key in LogicalKeyboardKey.knownLogicalKeys) {
      if (key.debugName?.toLowerCase().replaceAll(' ', '') == wanted) {
        return key;
      }
    }
    // `k` rather than `keyK`, and every other key whose label is what you
    // would call it.
    for (var key in LogicalKeyboardKey.knownLogicalKeys) {
      if (key.keyLabel.toLowerCase() == wanted) return key;
    }
    throw TargetError(
      TargetFailure.notFound,
      'no key is called "$name". Names are `LogicalKeyboardKey` debug names '
      'spelled any way that reads — `escape`, `enter`, `tab`, `arrowDown`, '
      '`f2`, `keyK` — a single character like `k`, or one of '
      '${_keyAliases.keys.join(', ')}.',
    );
  }

  /// Refuses a key this platform's tables cannot produce a keystroke for.
  ///
  /// [_physicalKey] is not this check, and cannot be. It answers from
  /// `knownPhysicalKeys` — every key on every keyboard — because that is the
  /// right set for the `usbHidUsage` the `KeyData` half needs. The raw half is
  /// built by `KeyEventSimulator.getKeyData` out of the *per-platform* tables,
  /// which are much smaller, and it reaches for three of them
  /// (`_findPhysicalKeyByPlatform`, `_getKeyCode`, `_getScanCode`) with a bare
  /// `assert(x != null); return x!;` at each. So a key the set above accepts
  /// can still have no macOS scan code or no Android key code.
  ///
  /// Measured: `f24`, `browserBack` and `abort` all pass [_physicalKey] and
  /// then throw `Failed assertion … not found in android physical key map`
  /// from inside `flutter_test`. That is an `AssertionError`, not a
  /// [TargetError], so it escapes the guest's refusal path entirely and comes
  /// back as a bare stack trace with no screen attached to it, which is a poor
  /// answer for a caller who only mistyped a key name.
  ///
  /// Rather than reimplement three private lookups that would then drift, this
  /// asks the same function the send will ask, and turns whatever it throws
  /// into a refusal the caller can act on. `getKeyData` reads state and
  /// mutates none, so calling it twice costs a map scan and nothing else.
  static void _checkSimulatable(LogicalKeyboardKey key) {
    try {
      KeyEventSimulator.getKeyData(key, platform: _keyPlatform);
    } on Object {
      throw TargetError(
        TargetFailure.notFound,
        '${key.debugName} is not in the key tables for $_keyPlatform, so no '
        'keystroke can be built for it here — Flutter maps a different set of '
        'keys per platform, and this one is missing from that set rather than '
        'from your spelling. Pick another key.',
      );
    }
  }

  /// A logical key's physical twin, matched the way `flutter_test` matches it:
  /// by debug name.
  ///
  /// The complete set, because this answers the `usbHidUsage` the `KeyData`
  /// half carries. Whether *this platform* can build a raw message for it is a
  /// second question, and [_checkSimulatable] is the one that asks it.
  static PhysicalKeyboardKey _physicalKey(LogicalKeyboardKey key) {
    for (var physical in PhysicalKeyboardKey.knownPhysicalKeys) {
      if (physical.debugName == key.debugName) return physical;
    }
    throw TargetError(
      TargetFailure.notFound,
      '${key.debugName} has no physical key on any keyboard this can '
      'simulate, so there is no keystroke to send.',
    );
  }

  /// The platform back gesture, injected the way the engine injects it — down
  /// `flutter/navigation` — so `PopScope`s run on the way in.
  Future<DriveStep> back({Duration? settle}) async {
    var watch = Stopwatch()..start();
    await lane.popRoute();
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(verb: 'back', settle: result, elapsed: watch.elapsed);
  }

  /// [duration] of the lane's clock, then a settle so what the wait released
  /// is applied.
  Future<DriveStep> wait(Duration duration, {Duration? settle}) async {
    var watch = Stopwatch()..start();
    await lane.elapse(duration);
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(verb: 'wait', settle: result, elapsed: watch.elapsed);
  }

  /// The act-less transaction: settle and look.
  Future<DriveStep> observe({Duration? settle}) async {
    var watch = Stopwatch()..start();
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(verb: 'observe', settle: result, elapsed: watch.elapsed);
  }

  List<String> visibleTexts() => visibleTextsOf(controller);

  /// Where a verb with a finger puts it down: the point the target *named*,
  /// or the centre of whatever it resolved to.
  ///
  /// The two are the same for every target that says *what* — a string, a
  /// key, a type — because the only place such a target can mean is the
  /// middle of what it found. They come apart for `{"at": {x, y}}`, which
  /// says *where*: the hit test picks the innermost widget under the point,
  /// and on the surfaces this form exists for — an SVG map, a chart, a
  /// signature pad, anything whose regions are painted rather than laid out —
  /// that widget is the whole canvas, whose centre is a different region
  /// altogether. Pressing the point is the only reading of `{"at"}` that is
  /// ever what was asked for.
  ///
  /// `{"item": n}` is this same form — the host turns an item's box into its
  /// centre — and it gains the same fidelity: the coordinate the reply
  /// published is the coordinate pressed, rather than the middle of whichever
  /// descendant happened to be under it.
  ///
  /// The target is still *resolved*, and that is not ceremony: covered,
  /// offscreen, gone and ambiguous stay refusals, and a point over nothing
  /// resolves to nothing and is refused like any other miss. Only the last
  /// step — where the finger lands on what was resolved — is the point's.
  Offset _contact(dynamic target, Finder finder) =>
      pointOf(target) ?? controller.getCenter(finder);

  Future<DriveStep> _act(
    String verb,
    dynamic target,
    Duration? settle,
    Future<void> Function(Finder finder) act,
  ) async {
    var watch = Stopwatch()..start();
    var attempts = 0;
    while (true) {
      attempts++;
      try {
        var finder = await _resolver.resolve(target, verb);
        await act(finder);
        break;
      } on TargetError {
        if (!lane.retries || watch.elapsed >= actTimeout) rethrow;
        await lane.settle(retryPump);
      }
    }
    var result = await lane.settle(settle ?? settleBudget);
    return DriveStep(
      verb: verb,
      target: describeTarget(target),
      settle: result,
      elapsed: watch.elapsed,
      attempts: attempts,
    );
  }

  String _describeScreen() {
    var texts = visibleTexts().where((t) => t.isNotEmpty).toList();
    if (texts.isEmpty) return 'none on screen';
    var shown = texts.take(20).map((t) => '"$t"').join(', ');
    return texts.length > 20 ? '$shown, …' : shown;
  }
}
