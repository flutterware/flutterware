import 'dart:async';

// The device vocabulary, which is pure Dart and public — so this stays
// linkable from `fw`, like everything else this file imports.
import 'package:flutterware/devices.dart';

// The plain-Dart halves rather than the umbrella `ui_catalog.dart`, for the
// reason `headless_catalog.dart` gives at its own imports: this file is reached
// from `fw`, and the umbrella exports the demo annotations, which reach
// `package:flutter/widgets.dart` and would make `fw` unlinkable.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/log.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/semantics.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/watch.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axis.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/keyboard.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';

import '../embedder/guest_channel.dart';
import 'debug_flags.dart';

/// How patiently a read waits for the guest to be describing the entry it was
/// asked about.
///
/// A property of the guest rather than of the call, which is why it is set once
/// on the [InspectClient] and never passed to a method: how long to wait depends
/// entirely on whether the caller drove the build itself.
class InspectPatience {
  const InspectPatience({required this.attempts, required this.delay});

  /// The live panel. Short, because the session drove the reload and is waiting
  /// only on the frame after it.
  static const live = InspectPatience(
    attempts: 10,
    delay: Duration(milliseconds: 30),
  );

  /// A headless guest that has just been handed a kernel and still has to
  /// build, lay out and paint before it can answer about the new entry.
  static const headless = InspectPatience(
    attempts: 20,
    delay: Duration(milliseconds: 50),
  );

  /// Ask once and take the answer.
  ///
  /// For reading a guest nothing asked to change — the attach path, where the
  /// question is "is this session already showing the entry I want" and a no is
  /// an answer. Retrying there would mean waiting for a click.
  static const glance = InspectPatience(attempts: 1, delay: Duration.zero);

  final int attempts;
  final Duration delay;
}

/// Reads a guest's `ext.flutterware.*` inspection extensions.
///
/// One reader, two mounts. [HeadlessCatalog] brings up its own guest to
/// answer a `fw` or MCP call; [CatalogSession] holds a live one behind the
/// panel. Both ask the same guest the same questions, and before this existed
/// they asked it in two files — `settledAxes` beside `_readAxes`,
/// `settledKnobs` beside `_readKnobs`, with nothing keeping the pair honest and
/// three more reads about to be duplicated the same way.
///
/// The rule this encodes: **the shared unit is the guest extension and its
/// model, not the `PluginAction`.**
/// The panel cannot call an action — it must inspect the guest that is on
/// screen, not a re-render of it — so parity has to live below the action
/// layer, and this is where.
///
/// Pure Dart, like everything it reads. `fw` links it.
class InspectClient {
  InspectClient(this.channel, {required this.patience, this.abandoned});

  /// The guest, over whichever channel reaches it.
  final GuestChannel channel;

  final InspectPatience patience;

  /// Whether the caller has gone away mid-poll — a disposed session, a closed
  /// panel. Checked around every await, because the alternative is a reader
  /// that keeps talking to a guest on behalf of something that no longer
  /// exists.
  final bool Function()? abandoned;

  /// The widget tree [entryId] built, scoped to the demo.
  Future<InspectTree?> tree(String entryId) => _settle(
    'ext.flutterware.tree',
    InspectTree.fromJson,
    (tree) => tree.entryId,
    entryId,
  );

  /// The semantics tree [entryId] is showing — what a screen reader gets.
  ///
  /// Settles on the entry like [tree], and the guest holds up its end by
  /// withholding the entry id until a tree exists: enabling semantics takes a
  /// frame, and the retries here are what ride it out. Call [setSemantics]
  /// first — a live app has semantics off, and reading without enabling
  /// settles on nothing.
  Future<InspectSemantics?> semantics(String entryId) => _settle(
    'ext.flutterware.semantics',
    InspectSemantics.fromJson,
    (read) => read.entryId,
    entryId,
  );

  /// Turns the guest's semantics tree on or off.
  ///
  /// On is **required** like the other writes — a tab reading a guest that
  /// silently failed to enable would show "no semantics" about an app that
  /// has plenty. Off is tolerant, because it runs from disposes.
  Future<void> setSemantics(bool on) => on
      ? channel.requireExtension(
          'ext.flutterware.semantics',
          args: const {'on': 'true'},
        )
      : channel.callExtension(
          'ext.flutterware.semantics',
          args: const {'on': 'false'},
        );

  /// The knobs [entryId] declared while it built.
  Future<KnobReport?> knobs(String entryId) => _settle(
    'ext.flutterware.knobs',
    KnobReport.fromJson,
    (report) => report.entryId,
    entryId,
  );

  /// The axes the shell around [entryId] declared while it built.
  ///
  /// Settles on the *entry* rather than on a shell ever appearing: an entry
  /// whose wrapper is not a shell reports no shell and no axes, and that is an
  /// answer rather than something to keep waiting for.
  Future<AxisReport?> axes(String entryId) => _settle(
    'ext.flutterware.axes',
    AxisReport.fromJson,
    (report) => report.entryId,
    entryId,
  );

  /// What [entryId] reported while building and painting — build throws, layout
  /// overflows.
  Future<InspectErrors?> errors(String entryId) => _settle(
    'ext.flutterware.errors',
    InspectErrors.fromJson,
    (report) => report.entryId,
    entryId,
  );

  /// What [entryId] printed.
  ///
  /// Settles on the entry like everything else here: a buffer naming another
  /// demo is a read from before the switch.
  Future<InspectLogs?> logs(String entryId) => _settle(
    'ext.flutterware.logs',
    InspectLogs.fromJson,
    (report) => report.entryId,
    entryId,
  );

  /// Each line as the demo prints it, without waiting for a poll.
  ///
  /// The buffer and the stream are both needed and neither replaces the other:
  /// [logs] says what has already been printed, this says what is being
  /// printed now. A reader takes both and drops the overlap by
  /// [InspectLogLine.sequence] — matching on text and time instead would still
  /// be wrong about a demo printing the same word twice in a frame.
  Stream<InspectLogLine> get logLines =>
      channel.extensionEvents('flutterware.log').map(InspectLogLine.fromJson);

  /// Empties the guest's buffer — the console's clear button.
  ///
  /// Tolerant, like [clearErrors]: the cost of it failing is a stale list.
  Future<void> clearLogs() =>
      channel.callExtension('ext.flutterware.clearLogs');

  /// Forgets what the entry has reported so far.
  ///
  /// Tolerant rather than required, unlike the other writes: this is the one
  /// call whose failure costs nothing but a stale list, and a guest from before
  /// the extension existed should still be readable.
  Future<void> clearErrors() =>
      channel.callExtension('ext.flutterware.clearErrors');

  /// The node ids under a point, outermost first.
  ///
  /// Does no settling of its own on purpose. A hit is only meaningful against a
  /// particular tree, so the caller reads the tree first and this answers about
  /// the same build; settling here would resolve the point against a second
  /// reading the caller was never shown.
  Future<List<String>> hitTest(double x, double y) async {
    var json = await channel.callExtension(
      'ext.flutterware.hitTest',
      args: {'x': '$x', 'y': '$y'},
    );
    return [for (var id in json?['ids'] as List? ?? const []) '$id'];
  }

  /// Turns the knobs, and reports whether the demo took them.
  ///
  /// [payload] is the *whole* declared set, JSON-encoded — a name absent from it
  /// is what says "leave this at its default". Both callers build it with
  /// `paramPayloadFor`.
  ///
  /// A write, so it uses [GuestVmService.requireExtension], and routing both
  /// callers through here is most of why this class earns its keep. The tolerant
  /// form swallows JSON-RPC 32601, which is right for "does this old guest have
  /// the extension" and wrong for "call the extension I know exists" — and that
  /// exact confusion is how `setParameter` survived a week after being renamed
  /// to `setParameters`, applying nothing and reporting success. S0b fixed the
  /// headless caller; the panel's two writes were still tolerant.
  Future<bool> setKnobs(String payload) async {
    var json = await channel.requireExtension(
      'ext.flutterware.setKnobs',
      args: {'payload': payload},
    );
    return json?['applied'] == true;
  }

  /// Turns the shell's axes, and reports what it says afterwards.
  ///
  /// Required rather than tolerant for the same reason [setKnobs] is.
  Future<AxisReport?> setAxes(String payload) async {
    var json = await channel.requireExtension(
      'ext.flutterware.setAxes',
      args: {'payload': payload},
    );
    return json == null ? null : AxisReport.fromJson(json);
  }

  /// Stages the guest as [platform] — null for a preview that is no device at
  /// all, which renders as the machine the studio is running on.
  ///
  /// The identity of the device, where the resize carries its geometry.
  /// The two travel apart because they have to: the window metrics reach the
  /// guest through the embedder's own event, which has fields for a size, a
  /// ratio and four insets and nothing else. Everything beyond geometry — the
  /// axes, the knobs, this — goes over the VM service.
  ///
  /// Through the framework's own `platformOverride` — see [stageGuestPlatform]
  /// for why that one rather than an extension of ours.
  Future<void> setStaging(DevicePlatform? platform) =>
      stageGuestPlatform(channel, platform);

  /// Tells the guest how tall its keyboard is and whether to raise it.
  ///
  /// Two halves of one fact, and neither is a keyboard on its own. The
  /// height is a measurement the host holds — it comes off the device table
  /// and the guest has no way to know it — and the mode is what the person
  /// looking at the picture asked for. What the app *wants* stays entirely on
  /// the guest's side: a field taking focus is a framework signal, and nothing
  /// here polls for it.
  ///
  /// Zero height is how a stage with no keyboard is said: a desktop window,
  /// and `Fit`, which is not a device and has nothing measured to draw. A
  /// forced-up keyboard there raises nothing rather than inventing a number.
  ///
  /// [keypadHeight] is the shorter keyboard a `phone` or `number` field gets,
  /// and null means this device does not shrink for one. *Which* keyboard is
  /// asked for stays entirely on the guest's side: it is on the text input
  /// channel, and the host has no business guessing at it.
  ///
  /// Required rather than tolerant, like the other writes: a keyboard that
  /// silently failed to arrive looks exactly like a layout that survived it.
  Future<KeyboardState?> setKeyboard({
    required KeyboardMode mode,
    required double height,
    double? keypadHeight,
  }) async {
    var json = await channel.requireExtension(
      'ext.flutterware.keyboard',
      args: {
        'mode': mode.name,
        'height': '$height',
        // **The empty string is a value here, not an omission.** It says *this
        // device does not shrink for a digit pad*, which every iPad and every
        // Android geometry means and which is a different fact from a host
        // that has nothing to say.
        'keypadHeight': keypadHeight == null ? '' : '$keypadHeight',
      },
    );
    return json == null ? null : KeyboardState.fromJson(json);
  }

  /// What the guest's keyboard is doing, without changing it.
  Future<KeyboardState?> keyboard() async {
    var json = await channel.callExtension('ext.flutterware.keyboard');
    return json == null ? null : KeyboardState.fromJson(json);
  }

  /// Closes the keyboard the way a platform does — the dismiss key.
  ///
  /// Not a mode change: the guest tells the focused field its connection went
  /// away, the field unfocuses, and the keyboard comes down *because the view
  /// dismissed it*. That is the only gesture on a real phone that takes a
  /// keyboard away from outside the app, and it is the one that makes the app
  /// react rather than making artwork disappear.
  Future<KeyboardState?> dismissKeyboard() async {
    var json = await channel.requireExtension(
      'ext.flutterware.keyboard',
      args: const {'dismiss': 'true'},
    );
    return json == null ? null : KeyboardState.fromJson(json);
  }

  /// Every move the keyboard makes, pushed rather than polled.
  ///
  /// The interesting transitions are the *app's* — a field took focus, a view
  /// let go of one — so a host that had to ask would find out a poll late. For
  /// a control drawn over the keyboard band, a poll late means drawn in the
  /// wrong place.
  Stream<KeyboardState> get keyboards => channel
      .extensionEvents('flutterware.keyboard')
      .map(KeyboardState.fromJson);

  /// Puts [entryId] on screen without recompiling or reloading anything.
  ///
  /// The generated entrypoint imports every entry's wrapper, so the program the
  /// guest is already running holds the whole catalog — see [CatalogEntries].
  /// Switching is therefore a message and a frame rather than a compile and a
  /// reload, which on this repo's catalog is the difference between ~350ms and
  /// ~33ms.
  ///
  /// Returns false when this guest cannot do it: one built before the extension
  /// existed, or one whose program does not hold [entryId] — a demo the
  /// compiler quarantined is not in the program, and neither is one that
  /// appeared on disk after the guest started. Both recover the same way and
  /// the caller does it: compile and reload, which always works. The guest
  /// answers with what it is *actually* showing rather than raising, so telling
  /// the two apart costs a comparison instead of an exception path.
  Future<bool> showEntry(String entryId) async {
    var json = await channel.callExtension(
      'ext.flutterware.showEntry',
      args: {'id': entryId},
    );
    return json?['entry'] == entryId;
  }

  /// Asks the guest to say when what is on screen has moved.
  ///
  /// [nodeId] is the node whose box should be reported; null watches structure
  /// only. [minInterval] is the debounce — zero means every frame, and which of
  /// those is right is the host's call, because only the host knows whether it
  /// is driving an overlay that has to track an animation or a tree view that
  /// is happy a second late.
  ///
  /// Required rather than tolerant, like the other writes: a watch that
  /// silently failed to start looks exactly like a demo that is not moving.
  Future<WatchStats?> watch({
    String? nodeId,
    Duration minInterval = Duration.zero,
  }) async {
    var json = await channel.requireExtension(
      'ext.flutterware.watch',
      args: {
        'on': 'true',
        // `-` rather than the empty string, which the guest reads as "leave the
        // node alone" — a caller clearing the selection means it.
        'node': nodeId ?? '-',
        'minIntervalMillis': '${minInterval.inMilliseconds}',
      },
    );
    return json == null ? null : WatchStats.fromJson(json);
  }

  /// Stops the watch, so an uninspected guest costs nothing.
  ///
  /// Tolerant, unlike [watch], and for the reason [clearErrors] is: this runs
  /// from a dispose, where the guest may already be going away and there is
  /// nothing useful to do about it.
  Future<void> unwatch() =>
      channel.callExtension('ext.flutterware.watch', args: {'on': 'false'});

  /// What the watch has cost, without subscribing to it.
  Future<WatchStats?> watchStats() async {
    var json = await channel.callExtension('ext.flutterware.watch');
    return json == null ? null : WatchStats.fromJson(json);
  }

  /// The pushes themselves.
  ///
  /// Not filtered by entry here. A push naming another entry is the *evidence*
  /// that a switch has happened and this reader is behind, so dropping it
  /// silently would throw away the only signal for it.
  Stream<WatchPush> get watches =>
      channel.extensionEvents('flutterware.watch').map(WatchPush.fromJson);

  /// Polls [method] until what it decodes names [entryId].
  ///
  /// Null covers both "the guest does not register this" and "it never named
  /// the entry". They are one outcome at every call site — the headless side
  /// answers empty for both, the panel leaves what it is holding alone for both
  /// — so collapsing them keeps that decision visible where it is made rather
  /// than baked in here.
  ///
  /// Retrying at all is not politeness. The reports are recorded by the demo's
  /// *build*, so a read that lands between the reload and the frame describes
  /// the entry that was on screen before, and answering with it would be a
  /// confident description of the wrong thing.
  Future<T?> _settle<T>(
    String method,
    T Function(Map<String, Object?>) decode,
    String? Function(T) entryOf,
    String entryId,
  ) async {
    for (var attempt = 0; attempt < patience.attempts; attempt++) {
      var json = await channel.callExtension(method);
      if (abandoned?.call() ?? false) return null;
      // A guest from before the extension existed.
      if (json == null) return null;
      var report = decode(json);
      if (entryOf(report) == entryId) return report;
      await Future<void>.delayed(patience.delay);
      if (abandoned?.call() ?? false) return null;
    }
    return null;
  }
}
