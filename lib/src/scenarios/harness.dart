import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/group.dart';
import 'package:test_api/src/backend/group_entry.dart';
import 'package:test_api/src/backend/live_test.dart';
import 'package:test_api/src/backend/message.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';

export 'time_mode.dart' show ScenarioTime;

import '../bytes.dart';
import '../flutter_gpu_diagnosis.dart';
import '../devices.dart';
import '../drive/resolve.dart' show visibleTextsOf;
import '../inspect/guest_inspect.dart';
import '../real_work/tracker.dart';
import 'async_watchdog.dart';
import '../app_events/events.dart';
import 'film.dart';
import 'fonts.dart';
import 'live_binding.dart';
import 'motion.dart';
import 'network.dart';
import 'notification.dart';
import 'profile.dart';
import 'selector.dart';
import 'settle.dart';
import 'progress.dart';
import 'stall.dart';
import 'report.dart';
import 'reel.dart';
import 'run_args.dart';
import 'scenario.dart';
import 'scene_stage.dart';
import 'shots.dart';
import 'time_mode.dart';
import 'run_listener.dart';
import '../inspect/semantics_capture.dart';
import '../translations/index.dart';

// ignore_for_file: implementation_imports

/// How many event summaries ride inline on a step. The full list is always on
/// disk beside the pixels; this is the part a reader gets without asking, and
/// a screen that logs in a build method must not turn one step's record into
/// a wall.
const _maxInlineTitles = 12;

/// How wide one inline title may be.
///
/// Two caps, because a summary is bounded by rows times width and this is
/// the half that was open. A stored title is capped at 300 characters and
/// that is right for the artifact; twelve of those inline is 3,600 characters
/// on one step, and a step is not the unit anyone budgets in. A db event's
/// title is a whole SQL statement now, so the case is ordinary rather than
/// pathological: measured, twenty hand-formatted queries on one step put
/// 1,980 bytes of titles in the run's answer.
///
/// 120 keeps what a title is scanned for — the verb and the subject, `select
/// … from … join …`, `POST` and its path — and drops the tail. The whole one
/// is in the capture either way, which is what `scenarios read events: true`
/// reads.
const _maxInlineTitleChars = 120;

/// The one-line summaries that ride inline on a step, capped.
///
/// The part an agent reasons about without opening a file. `system` is left
/// out — it is the channel a reader filters away, and it is most of the
/// volume: measured on the example suite, 183 of 189 events and 98% of the
/// bytes.
///
/// Both caps say when they bit. Handing back twelve of forty with nothing
/// saying so reads as "the app did twelve things", and the arithmetic that
/// would disprove it — `eventCount` minus the `system` count — needs the
/// exclusion rule above to be known first. A title cut short ends in `…` for
/// the same reason. `scenarios read events: true` hands back the whole list,
/// untruncated and filtered how you ask.
List<String>? inlineEventTitles(List<AppEvent> events) {
  if (events.isEmpty) return null;
  var titles = [
    for (var event in events)
      if (event.channel != AppChannel.system)
        // The detail is appended *after* the cut, never inside it: a status
        // code or a row count is a handful of characters and most of what the
        // line is read for, and losing `→ 500` to a long URL would be the
        // wrong half to drop.
        _capTitle(event.title) +
            (event.detail == null ? '' : ' → ${event.detail}'),
  ];
  if (titles.length <= _maxInlineTitles) return titles;
  return [
    ...titles.take(_maxInlineTitles),
    '… ${titles.length - _maxInlineTitles} more — scenarios read events: true',
  ];
}

String _capTitle(String title) => title.length <= _maxInlineTitleChars
    ? title
    : '${title.substring(0, _maxInlineTitleChars)}…';

/// The scenario harness `main`, called by the generated entrypoint the runner
/// compiles into `flutter_tester`:
///
/// ```dart
/// // GENERATED — build/flutterware/scenarios_harness.dart
/// import 'package:flutterware/src/scenarios/harness.dart' as harness;
/// import '../../test/scenarios/counter_test.dart' as s0;
///
/// void main() => harness.runHarness({
///   'test/scenarios/counter_test.dart': s0.main,
/// });
/// ```
///
/// Runs under `AutomatedTestWidgetsFlutterBinding` — FakeAsync, instantaneous
/// — in a directly-spawned `flutter_tester` (S4,
/// `2026-07-30-s4-flutter-tester-findings.md`). The host drives it over the VM
/// service:
///
/// - `ext.flutterware.scenarios.list` → every declared scenario, by file.
/// - `ext.flutterware.scenarios.run` → runs scenarios (optionally one, by
///   `file` + `scenario`), writing each step's PNG and widget tree under the
///   request's `out` directory and returning the step list. The
///   request/response shape is the barrier an agent needs: no watch mode, no
///   races.
///
/// Fonts load once at startup from the asset bundle's `FontManifest.json` —
/// flutterware's job, not every user's (S4's fonts finding). [runScenarios]
/// does the same for the `flutter test` lane, so the two agree about how wide
/// a line of text is.
Future<void> runHarness(
  Map<String, void Function()> scenarioMains, {
  Map<String, Future<void> Function(FutureOr<void> Function())> configs =
      const {},
  ScenarioTime time = ScenarioTime.fake,
}) async {
  // The whole harness — including every extension handler, which runs in the
  // zone it was registered in — is guarded: a failing scenario can leak an
  // async error after its LiveTest completes, and unguarded that reaches
  // `tester_main.cc`'s unhandled handler, which kills the process. A shared
  // harness dying because one scenario failed is the one outcome this may
  // never have.
  unawaited(
    runZonedGuarded(() => _runHarness(scenarioMains, configs, time), (
      error,
      stack,
    ) {
      stderr.writeln('[harness] uncaught: $error\n$stack');
    }),
  );
}

Future<void> _runHarness(
  Map<String, void Function()> scenarioMains,
  Map<String, Future<void> Function(FutureOr<void> Function())> configs,
  ScenarioTime time,
) async {
  // A lane is a process: the binding is the one thing chosen here that no
  // scenario can change afterwards, which is why `time` is a folder's word
  // and a package's, never a scenario's.
  var binding = time.isReal
      ? LiveHarnessBinding(
          animations: time.animations,
          wrapMessenger: _SpyMessenger.new,
        )
      : _HarnessBinding();
  scenarioHarnessTime = time;
  // Declared before anything is, because `scenario()` reads it as it declares.
  // Without this the harness's deadline is dead letter: `testWidgets` stamps
  // the binding's ten minutes on every test, `Timeout.apply` honours it, and
  // a wedged scenario takes ten real minutes to be called wedged.
  scenarioDefaultTimeout = const Timeout(_defaultScenarioTimeout);
  var fonts = await loadScenarioFonts();

  // **The runner's own lane has to arm the index itself.** `runScenarios` also
  // sets this, but under the harness that call is a *probe*: it returns as soon
  // as it has handed back the folder's profile, before it reaches the flag. So
  // the one line there covered a bare `flutter test` and nothing else, and a
  // project with the seam wired saw every export come back empty. It costs
  // nothing when no catalog is registered — the walk reads the flag and
  // returns — which is why it is on here rather than behind a request field.
  TranslationIndex.recording = true;

  var (
    :profiles,
    shots: folderShots,
    keyboards: folderKeyboards,
    shadows: folderShadows,
    networks: folderNetworks,
    settles: folderSettles,
    reels: folderReels,
  ) = await _probeFolders(
    configs,
    time,
  );

  var inspector = GuestInspector(
    rootOf: () => binding.rootElement,
    entryIdOf: () => null,
  );

  developer.registerExtension('ext.flutterware.scenarios.list', (_, _) async {
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'scenarios': _list(scenarioMains, profiles)}),
    );
  });

  developer.registerExtension('ext.flutterware.scenarios.run', (_, args) async {
    try {
      // The project's own default, under everything: a folder, a run and a
      // scenario each beat it. Read per request rather than once, because a
      // warm guest outlives an edit to `tool/flutterware.dart`.
      scenarioProjectNetwork = switch (args['networkDefault']) {
        null => null,
        var raw => parseScenarioNetwork(raw),
      };
      scenarioNetworkStorePath = args['networkStore'];
      var report = await _run(
        scenarioMains,
        inspector: inspector,
        outDir: args['out']!,
        file: args['file'],
        scenario: args['scenario'],
        tag: args['tag'],
        runArgs: _parseRunArgs(args),
        profiles: profiles,
        shots: folderShots,
        keyboards: folderKeyboards,
        shadows: folderShadows,
        networks: folderNetworks,
        settles: folderSettles,
        reels: folderReels,
        // Two passes rather than one: a dry run for the take, an edit, and
        // the film under the reel it cut. Only meaningful beside `filmDir`.
        filmReel: args['filmReel'] == 'true',
        // The host resolved a device id to geometry, or said it had nobody's
        // choice to resolve — in which case the folder's profile speaks and
        // the geometry that did arrive is only the host's fallback.
        device: args['device'],
        deviceUnspecified: args['deviceUnspecified'] == 'true',
        narrowestDevice: args['deviceChoice'] == 'narrowest',
        // Travels as an axis rather than baked into the geometry above,
        // because the device it applies to may still be undecided: when the
        // folder's profile is the one that picks, the rotation has to happen
        // in here, after it has spoken.
        orientation: switch (args['orientation']) {
          null => null,
          var name => orientationById(name),
        },
      );
      return developer.ServiceExtensionResponse.result(jsonEncode(report));
    } catch (error, stack) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    }
  });

  // The engine keeps the process alive; the timer keeps the isolate from ever
  // reading as idle between host calls.
  Timer.periodic(const Duration(days: 1), (_) {});
  print('flutterware scenarios harness ready — fonts: ${fonts.join(', ')}');
}

class _HarnessBinding extends AutomatedTestWidgetsFlutterBinding {
  // A hot reload schedules a warm-up frame; outside a test that frame
  // asserts. Same guard S4 and the 2026-05 port carried.
  @override
  void scheduleWarmUpFrame() {
    if (inTest) super.scheduleWarmUpFrame();
  }

  @override
  TestDefaultBinaryMessenger createBinaryMessenger() =>
      _SpyMessenger(super.createBinaryMessenger());

  // Watched at the binding rather than only at `s.runAsync`, because the whole
  // point of `s.tester` is that a scenario may reach past us — and a
  // `tester.runAsync` that wedges takes the run down just as quietly.
  @override
  Future<T?> runAsync<T>(Future<T> Function() callback) =>
      watchRunAsync(() => super.runAsync(callback));
}

/// Every platform message, as a transition event.
///
/// Under the test binding all channel traffic passes through the messenger the
/// binding constructs, so this is where a plugin's conversation with its host
/// becomes visible with no cooperation from the app. What it does *not* see is
/// traffic that never happens: a plugin whose platform interface is gated on
/// the dart plugin registrant (sqflite) throws before sending, and an ffi
/// implementation never sends at all
/// (`2026-08-11-scenario-events-spike-findings.md`).
class _SpyMessenger extends TestDefaultBinaryMessenger {
  /// The configured messenger becomes the **delegate**, not the donor.
  ///
  /// It carries outbound handlers the binding installed — `flutter/keyboard`
  /// among them — and those are private. Rebuilding around its `delegate`
  /// instead drops them, `getKeyboardState` then goes to the engine, is never
  /// answered, and every run hangs. Measured, at length, by the spike.
  _SpyMessenger(super.inner);

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    var system = channel.startsWith('flutter/');
    var call = _decode(message);
    recordAppEvent(
      AppEvent.custom(
        channel: system ? AppChannel.system : AppChannel.platform,
        title: call == null ? channel : '$channel ${call.method}',
        detail: call == null ? '${message?.lengthInBytes ?? 0} bytes' : null,
        data: _arguments(call),
      ),
    );
    var result = super.send(channel, message);
    // What a deadline can quote: which sends the body never saw answered,
    // and from where in the app. Plugin traffic and asset reads only — the
    // framework's own chatter is nobody's deadlock, and a stack per message
    // is not free. A reply that arrives while the body is suspended is a
    // fake microtask nobody runs, so from the body's side it stays pending,
    // which is exactly what the diagnosis wants to list. A send with no
    // reply at all — a mock answering null, fire-and-forget — is not
    // recorded: nothing was ever going to answer it, and sixty-four of
    // those would push the send that actually wedged out of the list.
    if (result != null && (!system || channel == 'flutter/assets')) {
      var token = recordPendingSend(_sendTitle(channel, call, message));
      result.then(
        (_) => sendAnswered(token),
        onError: (Object _) => sendAnswered(token),
      );
    }
    if (system) return result;
    // Replies are recorded only when they say something went wrong. A
    // successful envelope in a widget test is either empty or a mock's canned
    // value — the spike measured nine identical 6-byte success envelopes from
    // one `enterText` — and a channel with nobody on the other end is the
    // "your fake is not wired" diagnostic worth keeping.
    result?.then(
      (reply) {
        if (reply == null) {
          recordAppEvent(
            AppEvent.custom(
              channel: AppChannel.platform,
              title: '$channel — no implementation',
              detail: call?.method,
              error: true,
            ),
          );
          return;
        }
        try {
          const StandardMethodCodec().decodeEnvelope(reply);
        } catch (error) {
          recordAppEvent(
            AppEvent.custom(
              channel: AppChannel.platform,
              title: '$channel ${call?.method ?? ''} failed'.trim(),
              body: '$error',
              error: true,
            ),
          );
        }
      },
      onError: (Object error) => recordAppEvent(
        AppEvent.custom(
          channel: AppChannel.platform,
          title: '$channel ${call?.method ?? ''} threw'.trim(),
          body: '$error',
          error: true,
        ),
      ),
    );
    return result;
  }

  /// `flutter/assets assets/model.glb` — an asset read is the key, utf-8,
  /// and the key is the whole diagnosis. Anything else is the channel and
  /// the method.
  String _sendTitle(String channel, MethodCall? call, ByteData? message) {
    if (channel == 'flutter/assets' && message != null) {
      try {
        return '$channel ${utf8.decode(message.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes))}';
      } on FormatException {
        // Not a key after all; fall through to the size.
      }
    }
    return call == null ? channel : '$channel ${call.method}';
  }

  /// The two codecs the framework and its plugins actually use, in the order
  /// they are common. A message neither decodes is reported by its size —
  /// binary payloads (`flutter/assets`) have nothing else to say.
  MethodCall? _decode(ByteData? message) {
    if (message == null) return null;
    try {
      return const StandardMethodCodec().decodeMethodCall(message);
    } catch (_) {
      try {
        return const JSONMethodCodec().decodeMethodCall(message);
      } catch (_) {
        return null;
      }
    }
  }

  Map<String, Object?> _arguments(MethodCall? call) =>
      switch (call?.arguments) {
        null => const {},
        Map<Object?, Object?> map => {
          for (var entry in map.entries) '${entry.key}': entry.value,
        },
        var other => {'arguments': other},
      };
}

/// Declares every scenario file as a group named by its path, so a test's
/// file is recoverable from the group it sits in.
///
/// Deliberately **not** `Declarer(fullTestName:)`: `test_api` composes a full
/// name out of every enclosing group, so a scenario the author wrapped in a
/// `group('…')` of their own is named `<file> <group> <scenario>` and never
/// matched the `<file> <scenario>` a caller asks with — it listed fine and
/// could not be run. Declaring registers closures, it does not execute them,
/// so the filtering costs nothing where it now happens: in the walk, against
/// the same leaf name the listing reports.
/// The declared tree, plus which of its tests are **scenarios**.
///
/// A `test/scenarios/` folder may hold ordinary `testWidgets` — a helper, a
/// unit test that drifted in — and those produce no steps, cannot be opened
/// in the panel, and used to be run anyway: `list` (the syntactic scan) and
/// `run` (this walk) disagreed about what the folder contained. `scenario()`
/// announces itself as it declares, which is the only reading that cannot be
/// wrong about a name the scan could not evaluate.
({Group root, Map<String, Set<String>> scenarios}) _declare(
  Map<String, void Function()> scenarioMains, {
  Map<String, Shots> shots = const {},
  Map<String, bool> keyboards = const {},
  Map<String, bool> shadows = const {},
  Map<String, ScenarioNetwork> networks = const {},
  Map<String, Settle> settles = const {},
  Map<String, ScenarioReelEdit> reels = const {},
}) {
  var declarer = Declarer();
  var scenarios = <String, Set<String>>{};
  declarer.declare(() {
    for (var entry in scenarioMains.entries) {
      group(entry.key, () {
        var sink = <String>[];
        scenarioDeclarationSink = sink;
        // Which file is declaring, for anything that has to tell two
        // identically-named scenarios apart — see [scenarioAmbientFile]. Armed
        // and cleared with the sink because it has the sink's lifetime
        // exactly: a file's `main()`, and nothing either side of it.
        scenarioAmbientFile = entry.key;
        // The folder's shots policy, armed around the file's own `main()`:
        // under this runner `runScenarios` returns at the probe, so the
        // ambient it sets in the `flutter test` lane is never set here and the
        // harness has to arm it itself — the same shape as the translation
        // index two functions up.
        scenarioAmbientShots = _nearest(entry.key, shots);
        scenarioAmbientKeyboard = _nearest(entry.key, keyboards);
        scenarioAmbientShadows = _nearest(entry.key, shadows);
        scenarioAmbientNetwork = _nearest(entry.key, networks);
        scenarioAmbientSettle = _nearest(entry.key, settles);
        scenarioAmbientReel = _nearest(entry.key, reels);
        try {
          entry.value();
        } finally {
          scenarioDeclarationSink = null;
          scenarioAmbientFile = null;
          scenarioAmbientShots = null;
          scenarioAmbientKeyboard = null;
          scenarioAmbientShadows = null;
          scenarioAmbientNetwork = null;
          scenarioAmbientSettle = null;
          scenarioAmbientReel = null;
        }
        scenarios[entry.key] = sink.toSet();
      });
    }
  });
  return (root: declarer.build(), scenarios: scenarios);
}

/// Asks each folder's `flutter_test_config.dart` what it is for.
///
/// The config is *run*, not parsed: it is Dart, it may import its profile from
/// anywhere, and executing it is the only reading that cannot be wrong. Its
/// own setup runs too — the same setup `flutter test` gives that folder, which
/// this runner skipped entirely until now.
Future<
  ({
    Map<String, ScenarioProfile> profiles,
    Map<String, Shots> shots,
    Map<String, bool> keyboards,
    Map<String, bool> shadows,
    Map<String, ScenarioNetwork> networks,
    Map<String, Settle> settles,
    Map<String, ScenarioReelEdit> reels,
  })
>
_probeFolders(
  Map<String, Future<void> Function(FutureOr<void> Function())> configs,
  ScenarioTime time,
) async {
  var profiles = <String, ScenarioProfile>{};
  var shots = <String, Shots>{};
  var keyboards = <String, bool>{};
  var shadows = <String, bool>{};
  var networks = <String, ScenarioNetwork>{};
  var settles = <String, Settle>{};
  var reels = <String, ScenarioReelEdit>{};
  for (var MapEntry(key: directory, value: config) in configs.entries) {
    scenarioProbing = true;
    scenarioProbedProfile = null;
    scenarioProbedShots = null;
    scenarioProbedKeyboard = null;
    scenarioProbedShadows = null;
    scenarioProbedNetwork = null;
    scenarioProbedSettle = null;
    scenarioProbedReel = null;
    scenarioProbedTime = null;
    try {
      await config(() {});
      // Checked before anything runs rather than discovered as a scenario
      // that settles in fake seconds on a real clock: the binding was built
      // from the package's word, and the folder's has to be the same word.
      if (scenarioProbedTime case var folderTime?
          when folderTime.isReal != time.isReal) {
        throw StateError(
          'The folder says `runScenarios(time: ${folderTime.name})` and the '
          'package says `ScenariosPackage(time: ${time.name})`. A lane is a '
          'process, so both must agree — change one of them.',
        );
      }
      if (scenarioProbedProfile case var profile?) {
        profiles[directory] = profile;
      }
      if (scenarioProbedShots case var policy?) {
        shots[directory] = policy;
      }
      if (scenarioProbedKeyboard case var wanted?) {
        keyboards[directory] = wanted;
      }
      if (scenarioProbedShadows case var wanted?) {
        shadows[directory] = wanted;
      }
      if (scenarioProbedNetwork case var reach?) {
        networks[directory] = reach;
      }
      if (scenarioProbedSettle case var policy?) {
        settles[directory] = policy;
      }
      if (scenarioProbedReel case var edit?) {
        reels[directory] = edit;
      }
    } catch (error, stack) {
      stderr.writeln('[harness] $directory config: $error\n$stack');
    } finally {
      scenarioProbing = false;
      scenarioProbedProfile = null;
      scenarioProbedShots = null;
      scenarioProbedKeyboard = null;
      scenarioProbedShadows = null;
      scenarioProbedNetwork = null;
      scenarioProbedSettle = null;
      scenarioProbedReel = null;
      scenarioProbedTime = null;
    }
  }
  return (
    profiles: profiles,
    shots: shots,
    keyboards: keyboards,
    shadows: shadows,
    networks: networks,
    settles: settles,
    reels: reels,
  );
}

/// The profile whose folder contains [file] — the nearest one above it, which
/// is the rule `flutter test` itself resolves configs by.
ScenarioProfile? _profileFor(
  String file,
  Map<String, ScenarioProfile> profiles,
) => _nearest(file, profiles);

/// What the nearest folder above [file] says, out of a map keyed by directory
/// — the rule `flutter test` itself resolves configs by, and the same one for
/// every fact a folder declares.
T? _nearest<T>(String file, Map<String, T> byDirectory) {
  T? best;
  var bestLength = -1;
  for (var MapEntry(key: directory, value: value) in byDirectory.entries) {
    if ((file == directory || file.startsWith('$directory/')) &&
        directory.length > bestLength) {
      best = value;
      bestLength = directory.length;
    }
  }
  return best;
}

List<Map<String, Object?>> _list(
  Map<String, void Function()> scenarioMains,
  Map<String, ScenarioProfile> profiles,
) {
  var declared = _declare(scenarioMains);
  var scenarios = <Map<String, Object?>>[];
  void walk(Group group, String? file) {
    for (var entry in group.entries) {
      switch (entry) {
        case Test():
          if (!_isScenario(declared.scenarios, file, entry, group)) break;
          var profile = _profileFor(file ?? '', profiles);
          scenarios.add({
            'file': file ?? '',
            'name': _leafName(entry, group),
            if (entry.metadata.tags.isNotEmpty)
              'tags': entry.metadata.tags.toList()..sort(),
            if (entry.metadata.skip) 'skip': true,
            if (profile != null) ...{
              'profile': profile.name,
              'devices': [for (var d in profile.devices) d.id],
              'languages': profile.languages,
              'orientations': [for (var o in profile.orientations) o.name],
            },
          });
        case Group():
          walk(entry, file ?? entry.name);
        case GroupEntry():
          break;
      }
    }
  }

  walk(declared.root, null);
  return scenarios;
}

/// Whether a declared test came from `scenario()` rather than a plain
/// `testWidgets` that happens to live in the same folder.
bool _isScenario(
  Map<String, Set<String>> scenarios,
  String? file,
  Test test,
  Group group,
) => scenarios[file ?? '']?.contains(_leafName(test, group)) ?? false;

/// The scenario's own name, with the enclosing groups' prefix stripped —
/// `test_api` composes full names with spaces.
String _leafName(GroupEntry test, Group group) {
  if (group.name.isEmpty) return test.name;
  if (!test.name.startsWith(group.name)) return test.name;
  if (test.name.length == group.name.length) return '';
  return test.name.substring(group.name.length + 1);
}

/// The run request's axis assignment, from the flat string args the runner
/// sends. Geometry arrives resolved — the device vocabulary (`iphone-se` →
/// numbers) belongs to the host, and the harness applies numbers.
ScenarioRunArgs? _parseRunArgs(Map<String, String> args) {
  double? number(String key) {
    var raw = args[key];
    return raw == null ? null : double.parse(raw);
  }

  Size? size;
  if ((number('width'), number('height')) case (var width?, var height?)) {
    size = Size(width, height);
  }
  var insets = EdgeInsets.fromLTRB(
    number('insetLeft') ?? 0,
    number('insetTop') ?? 0,
    number('insetRight') ?? 0,
    number('insetBottom') ?? 0,
  );
  var locale = switch (args['language']) {
    null => null,
    var tag => () {
      var parts = tag.split(RegExp('[-_]'));
      return parts.length > 1 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
    }(),
  };
  // What the request *named*, kept beside the numbers it resolved to: the
  // body reads its axes off `s.assignment`, and both lanes have to answer the
  // same there. An unspecified device stays out — the geometry that arrived
  // with it is only the host's fallback, and the folder's profile may yet
  // speak (see `ScenarioRunArgs.withDevice`).
  var assignment = ScenarioAssignment(
    device: args['deviceUnspecified'] == 'true'
        ? null
        : deviceById(args['device'] ?? ''),
    orientation: switch (args['orientation']) {
      null => null,
      var name => orientationById(name),
    },
    language: args['language'],
  );
  var runArgs = ScenarioRunArgs(
    size: size,
    pixelRatio: number('pixelRatio'),
    padding: insets == EdgeInsets.zero ? null : insets,
    platform: switch (args['platform']?.toLowerCase()) {
      null => null,
      // By lowercase name: the wire says `ios`, the enum says `iOS`.
      var name => TargetPlatform.values.firstWhere(
        (p) => p.name.toLowerCase() == name,
      ),
    },
    locale: locale,
    textScale: number('textScale'),
    brightness: switch (args['brightness']) {
      null => null,
      'dark' => Brightness.dark,
      _ => Brightness.light,
    },
    accessibility: ScenarioRunAccessibility(
      boldText: args['boldText'] == 'true',
      highContrast: args['highContrast'] == 'true',
      invertColors: args['invertColors'] == 'true',
    ),
    captureScale: number('captureScale'),
    captureRaw: args['captureRaw'] == 'true',
    captureNative: args['captureNative'] == 'true',
    pixels: switch (args['pixels']) {
      'keyed' => ScenarioPixels.keyed,
      'named' => ScenarioPixels.named,
      'none' => ScenarioPixels.none,
      _ => ScenarioPixels.all,
    },
    expandTranslations: switch (args['expand']) {
      null => null,
      var raw => int.parse(raw),
    },
    film: _parseFilm(args, number),
    record: switch (number('recordIntervalMs')) {
      null => null,
      var interval => MotionRecording(
        interval: Duration(microseconds: (interval * 1000).round()),
        scale: number('recordScale'),
        maxFrames: number('recordMaxFrames')?.round() ?? 90,
      ),
    },
    clockOrigin: switch (args['clock']) {
      null => null,
      var raw => DateTime.parse(raw),
    },
    network: switch (args['network']) {
      null => null,
      var raw => parseScenarioNetwork(raw),
    },
    assignment: assignment.isEmpty ? null : assignment,
  );
  var untouched =
      runArgs.size == null &&
      runArgs.pixelRatio == null &&
      runArgs.padding == null &&
      runArgs.platform == null &&
      runArgs.locale == null &&
      runArgs.textScale == null &&
      runArgs.brightness == null &&
      runArgs.accessibility.isDefault &&
      runArgs.captureScale == null &&
      !runArgs.captureRaw &&
      !runArgs.captureNative &&
      runArgs.pixels == ScenarioPixels.all &&
      runArgs.record == null &&
      runArgs.film == null &&
      runArgs.clockOrigin == null &&
      runArgs.network == null &&
      runArgs.assignment == null &&
      runArgs.expandTranslations == null;
  return untouched ? null : runArgs;
}

/// The film settings a render request carries, or null for every ordinary run.
///
/// `filmDir` is what turns it on: everything else has a default, and a request
/// that names a directory is a request for a video in it. Refused beside
/// `record` rather than silently preferred — the two want the same seam and
/// opposite things from it, and a caller that asked for both has misunderstood
/// which run this is.
FilmSettings? _parseFilm(
  Map<String, String> args,
  double? Function(String key) number,
) {
  var directory = args['filmDir'];
  if (directory == null) return null;
  if (args['recordIntervalMs'] != null) {
    throw ArgumentError(
      'a run renders a film or records motion, not both: `filmDir` asks for '
      "every frame of the scenario at the film's own pace, and "
      '`recordIntervalMs` asks for the frames of each transition at the '
      "panel's. Drop one.",
    );
  }
  Duration? beat(String key) => switch (number(key)) {
    null => null,
    var ms => Duration(microseconds: (ms * 1000).round()),
  };
  var defaults = FilmSettings(directory: directory);
  return FilmSettings(
    directory: directory,
    fps: number('filmFps')?.round() ?? defaults.fps,
    scale: number('filmScale') ?? defaults.scale,
    branches: switch (args['filmBranches']) {
      null => const [],
      // JSON rather than a comma-separated list: a branch is a label an author
      // wrote in a sentence, and `'pay by card, then refund'` is a plausible
      // one.
      var raw => [for (var name in jsonDecode(raw) as List) '$name'],
    },
    open: beat('filmOpenMs') ?? defaults.open,
    travel: beat('filmTravelMs') ?? defaults.travel,
    aim: beat('filmAimMs') ?? defaults.aim,
    press: beat('filmPressMs') ?? defaults.press,
    dwell: beat('filmDwellMs') ?? defaults.dwell,
    close: beat('filmCloseMs') ?? defaults.close,
    maxFrames: number('filmMaxFrames')?.round() ?? defaults.maxFrames,
    pixels: args['filmPixels'] != 'false',
  );
}

Future<Map<String, Object?>> _run(
  Map<String, void Function()> scenarioMains, {
  required GuestInspector inspector,
  required String outDir,
  String? file,
  String? scenario,
  String? tag,
  ScenarioRunArgs? runArgs,
  Map<String, ScenarioProfile> profiles = const {},
  Map<String, Shots> shots = const {},
  Map<String, bool> keyboards = const {},
  Map<String, bool> shadows = const {},
  Map<String, ScenarioNetwork> networks = const {},
  Map<String, Settle> settles = const {},
  Map<String, ScenarioReelEdit> reels = const {},
  bool filmReel = false,
  String? device,
  bool deviceUnspecified = false,
  bool narrowestDevice = false,
  ScreenOrientation? orientation,
}) async {
  // Several selectors run in the order they were given — `--file=a,b` is
  // "a, then b" in one process, which is what a bisect across two files
  // needs: a future one file leaves behind in its fake zone only bites the
  // file that runs after it.
  var mains = file == null
      ? scenarioMains
      : {
          for (var selector in fileSelectors(file))
            for (var entry in scenarioMains.entries)
              if (selectsFile(selector, entry.key)) entry.key: entry.value,
        };
  var declared = _declare(
    mains,
    shots: shots,
    keyboards: keyboards,
    shadows: shadows,
    networks: networks,
    settles: settles,
    reels: reels,
  );
  var root = declared.root;

  var outcomes = <Map<String, Object?>>[];
  // What ran before the scenario running now, in this process — the name a
  // deadline quotes when the body is waiting on a future nothing here will
  // complete, since the usual owner of such a future is the previous body's
  // fake zone.
  String? previousName;
  // Emptied rather than read cumulatively: a warm guest serves many requests,
  // and a mode one of them ran under is not a fact about the next.
  scenarioNetworkModesRun.clear();
  // And the once-per-scenario network warnings, for the same reason: a warm
  // guest that stayed quiet on a re-run would be quiet about the run somebody
  // is actually watching.
  resetScenarioNetworkNotices();
  // What the first scenario's clock started at — the whole run's, since the
  // origin is resolved from the request and the request is one.
  DateTime? clockOrigin;
  var watch = Stopwatch()..start();

  // What each file runs as, worked out once per file. A request that named a
  // device is that device everywhere; a request that named none takes what the
  // file's folder profile puts first — which is how one run over a mixed suite
  // frames the mobile folder as a phone and the desktop folder as a window,
  // without the caller having to know either folder exists.
  var framings = <String, (ScenarioRunArgs?, String?)>{};
  (ScenarioRunArgs?, String?) framingFor(String file) =>
      framings.putIfAbsent(file, () {
        if (!deviceUnspecified) return (runArgs, device);
        var declared = _profileFor(file, profiles)?.devices;
        // The max-length probe measures on the tightest geometry the folder
        // claims — the narrowest *declared* device, never one the project
        // does not run on, which would manufacture false-tight limits.
        var chosen = narrowestDevice && (declared?.isNotEmpty ?? false)
            ? declared!.reduce(
                (a, b) => switch (a.width.compareTo(b.width)) {
                  < 0 => a,
                  > 0 => b,
                  // Total, like every ordering that picks a stable winner.
                  _ =>
                    a.height != b.height
                        ? (a.height < b.height ? a : b)
                        : (a.id.compareTo(b.id) <= 0 ? a : b),
                },
              )
            : declared?.firstOrNull;
        if (chosen == null) return (runArgs, device);
        return (
          (runArgs ?? const ScenarioRunArgs()).withDevice(
            chosen,
            orientation: orientation,
          ),
          chosen.id,
        );
      });

  /// Set when a scenario blew its deadline: the walk unwinds, and the report
  /// says the run stopped rather than that the rest passed.
  var abandoned = false;

  Map<String, Object?> skippedOutcome(Test entry, Group group, String? file) {
    var (_, framedDevice) = framingFor(file ?? '');
    return ScenarioRunOutcome(
      file: file ?? '',
      name: _leafName(entry, group),
      device: framedDevice,
      // Not a failure — `flutter test` exits 0 on a skipped test — but not
      // silently green either: the flag is what every surface above renders
      // as its own third state.
      ok: true,
      skipped: true,
      skipReason: entry.metadata.skipReason,
    ).toJson();
  }

  /// The selected skipped scenarios of a group nothing in will run — so a
  /// request that names one still finds it in the answer, saying skipped,
  /// rather than reading as a selector that matched nothing.
  void reportSkipped(Group group, String? groupFile) {
    for (var entry in group.entries) {
      switch (entry) {
        case Test():
          if (!_isScenario(declared.scenarios, groupFile, entry, group)) break;
          if (!_selects(entry, group, scenario, tag)) break;
          if (entry.metadata.skip) {
            outcomes.add(skippedOutcome(entry, group, groupFile));
          }
        case Group():
          reportSkipped(entry, groupFile ?? entry.name);
        case GroupEntry():
          break;
      }
    }
  }

  /// Mirrors `test_core`'s engine (`runner/engine.dart`, `_runGroup`): the
  /// group's `setUpAll` before its entries, its entries only if that passed,
  /// and its `tearDownAll` afterwards **whatever happened** — cleanup a
  /// failure skipped is cleanup that never runs, and this harness outlives the
  /// run by design.
  Future<void> walk(
    Group group,
    Suite suite,
    List<Group> parents,
    String? groupFile,
  ) async {
    // Before paying for a group's `setUpAll`, ask whether anything in it will
    // run at all. `test_core` never has to: it filters by rebuilding the group
    // tree, so an empty group never reaches the engine. We filter as we walk,
    // and the panel runs one scenario at a time — without this, running one
    // scenario would start every other file's fixtures. Skipped scenarios do
    // not count as running — but they still answer.
    if (!_runsAnything(declared.scenarios, group, groupFile, scenario, tag)) {
      reportSkipped(group, groupFile);
      return;
    }
    var scope = [...parents, group];

    var setUpAllError = group.setUpAll == null
        ? null
        : await _runHook(group.setUpAll!, suite, scope);

    for (var entry in group.entries) {
      if (abandoned) return;
      switch (entry) {
        case Test():
          // The name the listing shows, matched against the name the caller
          // asks for — the same vocabulary at both ends, whatever groups the
          // author nested the scenario in. Two scenarios sharing a leaf name
          // in one file both run, which is the honest reading of a request
          // that names only what the panel displays.
          var name = _leafName(entry, group);
          if (!_isScenario(declared.scenarios, groupFile, entry, group)) break;
          if (!_selects(entry, group, scenario, tag)) break;
          var (framedArgs, framedDevice) = framingFor(groupFile ?? '');
          // `scenario(skip: true)` reaches `testWidgets` and stops in the
          // test's metadata: enforcing it is the *engine*'s job
          // (`test_core`'s `_runSkippedTest`), and this harness walks the
          // declared tree itself. `LiveTest.run()` would execute the body of
          // a test `flutter test` reports as skipped — the two lanes
          // answering differently about the same file, with the runner red
          // on a body its author already declared broken.
          if (entry.metadata.skip) {
            outcomes.add(skippedOutcome(entry, group, groupFile));
            break;
          }
          if (setUpAllError != null) {
            // Reported against each scenario that would have run, not once
            // against the group: a caller who asked for one scenario must find
            // that scenario in the answer, failed and saying why.
            outcomes.add(
              ScenarioRunOutcome(
                file: groupFile ?? '',
                name: name,
                device: framedDevice,
                ok: false,
                errors: [setUpAllError],
              ).toJson(),
            );
            break;
          }
          // Read by `scenario()` inside the test body, applied through the
          // binding's own test values, reset by its tearDown — the run-args
          // zone of the design. Set per scenario rather than per request,
          // because the framing is per folder.
          scenarioRunArgs = framedArgs;
          // The clock the run actually ran under, read where the args are
          // live. A pinned date is only safe while it is *stated* — an app
          // with a trial expiry or a seasonal theme sits in a different state
          // under one, and a report that does not say so leaves whoever is
          // debugging it with a screen that disagrees with today for no
          // visible reason. Same reasoning as the axes.
          clockOrigin ??= resolvedScenarioClockOrigin;
          var outcome = filmReel && framedArgs?.film != null
              ? await _runReel(
                  entry,
                  suite,
                  scope,
                  args: framedArgs!,
                  file: groupFile ?? '',
                  name: name,
                  device: framedDevice,
                  inspector: inspector,
                  outDir: outDir,
                  previous: previousName,
                )
              : await _runOne(
                  entry.load(suite, groups: scope),
                  file: groupFile ?? '',
                  name: name,
                  device: framedDevice,
                  inspector: inspector,
                  outDir: outDir,
                  previous: previousName,
                );
          previousName = name;
          outcomes.add(outcome);
          // A scenario that timed out is still running in there, holding the
          // binding — the next one would fail on its leftovers and blame
          // itself. So the walk stops and the run answers with what it has,
          // which is the point of having a deadline at all.
          if (outcome['timedOut'] == true) {
            abandoned = true;
            return;
          }
        case Group():
          if (setUpAllError == null) {
            await walk(entry, suite, scope, groupFile ?? entry.name);
          }
        case GroupEntry():
          break;
      }
    }

    // Cleanup is skipped only here, and for the one reason that outranks it:
    // a `tearDownAll` runs on the binding the abandoned scenario is still
    // holding, so it is as likely to hang as to clean up — and the guest is
    // being thrown away regardless.
    if (group.tearDownAll case var hook? when !abandoned) {
      if (await _runHook(hook, suite, scope) case var error?) {
        // Its own outcome: a cleanup failure belongs to nobody's scenario, and
        // marking a scenario that passed as failed would be a lie.
        outcomes.add(
          ScenarioRunOutcome(
            file: groupFile ?? '',
            name: 'tearDownAll',
            ok: false,
            errors: [error],
          ).toJson(),
        );
      }
    }
  }

  var suite = Suite(root, SuitePlatform(Runtime.vm));
  // Armed for the whole request, like `scenarioRunArgs`: the padding is a
  // property of the pass, not of one scenario, and `TranslationIndex.reset()`
  // between scenarios deliberately leaves it alone.
  TranslationIndex.expandPercent = runArgs?.expandTranslations;
  try {
    await walk(root, suite, const [], null);
  } finally {
    scenarioRunArgs = null;
    TranslationIndex.expandPercent = null;
  }

  return {
    'ms': watch.elapsedMilliseconds,
    'scenarios': outcomes,
    if (clockOrigin != null) 'clock': clockOrigin!.toIso8601String(),
    // Which clock, said by the side that built the binding: a reader of the
    // report must know whether these pictures are comparable to the last.
    'time': scenarioHarnessTime.name,
    if (scenarioHarnessTime.isReal)
      'animations': scenarioHarnessTime.animations,
    if (scenarioNetworkModesRun.isNotEmpty)
      'network': [
        for (var mode in ScenarioNetwork.values)
          if (scenarioNetworkModesRun.contains(mode)) mode.name,
      ],
    // Says the list is short because the run stopped, not because that was
    // everything — and tells the host its guest is spent.
    if (abandoned) 'abandoned': true,
  };
}

/// Whether anything under [group] survives the scenario filter — the question
/// that decides whether its `setUpAll` is worth running.
bool _runsAnything(
  Map<String, Set<String>> scenarios,
  Group group,
  String? file,
  String? scenario,
  String? tag,
) {
  for (var entry in group.entries) {
    switch (entry) {
      case Test():
        // A skipped scenario never runs, so it alone is not worth a group's
        // fixtures — asking for it must not start every sibling's `setUpAll`.
        if (_isScenario(scenarios, file, entry, group) &&
            _selects(entry, group, scenario, tag) &&
            !entry.metadata.skip) {
          return true;
        }
      case Group():
        if (_runsAnything(
          scenarios,
          entry,
          file ?? entry.name,
          scenario,
          tag,
        )) {
          return true;
        }
      case GroupEntry():
        break;
    }
  }
  return false;
}

/// Whether a request naming [scenario] and/or [tag] wants this test.
///
/// The tag is `test_api`'s own — what `scenario(tags: …)` passes to
/// `testWidgets`, which is also what `flutter test --tags` filters on, so a
/// suite tagged for one runner is tagged for both.
bool _selects(Test test, Group group, String? scenario, String? tag) {
  if (scenario != null && _leafName(test, group) != scenario) return false;
  if (tag != null && !test.metadata.tags.contains(tag)) return false;
  return true;
}

/// Runs a group's `setUpAll` or `tearDownAll` — a synthetic test `test_api`
/// hangs off the group rather than putting in its entries, which is exactly
/// why a walk over `entries` alone never ran them.
///
/// Returns the failure, or null when it passed.
Future<ScenarioRunError?> _runHook(
  Test hook,
  Suite suite,
  List<Group> scope,
) async {
  var live = hook.load(suite, groups: scope);
  // `test_api` builds both hooks as **unguarded** tests (`guarded: false`):
  // they run no error zone of their own, on the understanding that whoever
  // runs them has one. Ours would be `runHarness`'s outermost guard, which
  // logs and swallows — and the LiveTest stays green, so the group would run
  // against a fixture that never got built. So the hook gets a zone here, and
  // what escapes into it is what failed.
  Object? escaped;
  StackTrace? escapedStack;
  await runZonedGuarded(() => live.run(), (error, stack) {
    escaped ??= error;
    escapedStack ??= stack;
  });
  // One turn of the event loop for an error raised on the way out.
  await Future<void>.delayed(Duration.zero);

  if (escaped == null && live.state.result.isPassing && live.errors.isEmpty) {
    return null;
  }
  var error = live.errors.firstOrNull;
  return ScenarioRunError(
    error: '${hook.name}: ${escaped ?? error?.error ?? 'failed'}',
    stack: (escapedStack ?? error?.stackTrace)?.toString(),
  );
}

/// Whether the binding's manufactured "Multiple exceptions (N)…" details is
/// fully covered by what the scenario buffered — by count when the sentence
/// carries one, by identity for anything else the binding hands over without
/// a stack.
bool _accountsFor(
  FlutterErrorDetails details,
  List<ScenarioCaughtError> caught,
) {
  var counted = RegExp(r'^Multiple exceptions \((\d+)\) were detected')
      .firstMatch(details.exceptionAsString());
  if (counted != null) return int.parse(counted.group(1)!) <= caught.length;
  return caught.any((c) => identical(c.exception, details.exception));
}

/// A reel: the same body twice.
///
/// Once **dry** — every beat pumped, nothing rasterised — for the take; then
/// the edit the scenario declared (or the stock one) cuts a [Reel] from it;
/// then once more, filmed, with the reel deciding what each output frame
/// shows. Both passes run under the same framing, locale and clock, because
/// the take is a map of the second run and a map of a different run is no map
/// at all. The take's timeline lands beside the film's directory, never in
/// it: a drain watches the film's for a head the dry pass never writes.
///
/// The dry pass's own report is what comes back when it failed: the scenario
/// broke before there was anything to cut, and that is the news. An edit that
/// throws is reported the same way, against the scenario it was cutting, so a
/// panel or a CLI shows one failed scenario rather than a harness that fell
/// over.
Future<Map<String, Object?>> _runReel(
  Test entry,
  Suite suite,
  List<Group> scope, {
  required ScenarioRunArgs args,
  required String file,
  required String name,
  required GuestInspector inspector,
  required String outDir,
  String? device,
  String? previous,
}) async {
  var film = args.film!;
  // Anything a previous request left finished is not this request's take.
  takeFinishedFilm();
  scenarioRunArgs = args.filming(film.dry('${film.directory}.take'));
  var dry = await _runOne(
    entry.load(suite, groups: scope),
    file: file,
    name: name,
    device: device,
    inspector: inspector,
    outDir: outDir,
    previous: previous,
  );
  if (dry['ok'] != true || dry['timedOut'] == true) return dry;

  Map<String, Object?> refused(String error, [StackTrace? stack]) =>
      ScenarioRunOutcome(
        file: file,
        name: name,
        device: device,
        ok: false,
        errors: [ScenarioRunError(error: error, stack: stack?.toString())],
      ).toJson();

  var finished = takeFinishedFilm();
  if (finished == null) {
    return refused(
      'the dry pass of `$name` filmed nothing, so there is no take to cut',
    );
  }
  var edit = finished.edit ?? const StockSceneReel();
  Reel reel;
  try {
    reel = edit.edit(finished.take);
  } catch (error, stack) {
    return refused('the edit (${edit.runtimeType}) failed: $error', stack);
  }
  scenarioRunArgs = args.filming(film, reel: reel);
  return _runOne(
    entry.load(suite, groups: scope),
    file: file,
    name: name,
    device: device,
    inspector: inspector,
    outDir: outDir,
    previous: name,
  );
}

Future<Map<String, Object?>> _runOne(
  LiveTest live, {
  required String file,
  required String name,
  required GuestInspector inspector,
  required String outDir,
  String? device,
  String? previous,
}) async {
  var steps = <ScenarioRunStep>[];
  var directory = Directory(
    '$outDir/${scenarioFileSafe(file)}/${scenarioFileSafe(name)}',
  )..createSync(recursive: true);
  // Each step's pixels, hashed, kept for one comparison: a verb whose picture
  // is byte-identical to its parent's changed nothing on screen, which is
  // what a stalled walk looks like from the inside — no exception, no failed
  // matcher, and (measured on a consumer suite) seven identical captures
  // passing as seven pages. By parent rather than by predecessor, so a
  // `split`'s branches each compare against the step they actually follow.
  //
  // The pixels rather than the tree, because the picture is what the flag is
  // about and the tree is not a projection of it. Measured on the same
  // consumer suite: of 297 steps the tree called unchanged, 275 had moved —
  // every `enterText` among them, the typed text being plainly on screen and
  // nowhere in the dump — while 102 genuine repeats went unflagged. A digest
  // per step also costs 16 characters where a tree costs its whole JSON.
  var digestByIndex = <int, String>{};
  // Per scenario, so the read set below belongs to *one* assignment. A matrix
  // runs its locales sequentially in one process, and an index carried across
  // them would report the last locale's value for every key — which is exactly
  // the value the falling-back-to-the-template report has to compare against.
  TranslationIndex.reset();

  // What a capture photographs, read at the shutter rather than when the
  // capture reaches the listener below — see [ScenarioScreenRead]. The tree,
  // the semantics and the translation keys all come out of this one read, so
  // all three describe the frame in the picture.
  scenarioScreenReader = () => ScenarioScreenRead(
    tree: inspector.read(),
    semantics: captureSemanticsTree(),
  );

  scenarioRunListener = (capture) {
    // The verb and what it was aimed at, which is what an automatic capture
    // is called now that it is not called `step 3`.
    var did = [?capture.verb, ?capture.target].join(' ').trim();
    var label = capture.name ?? (did.isEmpty ? 'step ${capture.index}' : did);
    // The stem shares its component with the index that precedes it and the
    // suffix that follows, so what is left over is what the label may use.
    var prefix = '${capture.index}-';
    var base =
        '${directory.path}/$prefix'
        '${scenarioFileSafe(capture.failure != null ? 'failed' : label, max: scenarioNameMax - prefix.length - _longestStepSuffix.length)}';
    var counts = <String, int>{};
    for (var event in capture.events) {
      counts[event.channel] = (counts[event.channel] ?? 0) + 1;
    }
    // What the app did on the way here, and the digest of it that rides the
    // record. Every kind of step has this — a document is reached the same way
    // a screen is — so it is written before the picture, which only some do.
    if (capture.events.isNotEmpty) {
      File('$base.events.json').writeAsStringSync(
        jsonEncode([
          for (var event in capture.events) event.toJson(),
        ], toEncodable: (value) => '$value'),
      );
    }
    ScenarioRunStep record(ScenarioRunStep step) {
      steps.add(step);
      markScenarioProgress();
      // Announced the moment it exists — the artifacts are already on disk —
      // so a host drawing the flow can fill it in while the scenario still
      // runs. The response at the end stays the complete report: streaming is
      // for watching, the barrier is for agents.
      developer.postEvent('flutterware.scenarios.step', {
        'file': file,
        'scenario': name,
        // Said on every step, not only in the final report: a host drawing
        // the flow live has to frame the first picture, and by then the
        // answer is already known.
        'device': ?device,
        'step': step.toJson(),
      });
      return step;
    }

    ScenarioRunStep beat(
      ScenarioStepKind kind, {
      String? payloadFile,
      String? mimeType,
      int? payloadBytes,
      String? digest,
      ScenarioNotification? notification,
    }) => ScenarioRunStep(
      index: capture.index,
      position: capture.position,
      parent: capture.parent,
      branch: capture.branch,
      name: capture.name,
      auto: capture.name == null,
      tags: capture.tags,
      kind: kind,
      file: payloadFile,
      mimeType: mimeType,
      bytes: payloadBytes,
      notification: notification,
      verb: capture.verb,
      target: capture.target,
      aim: capture.aim,
      events: capture.events.isNotEmpty ? '$base.events.json' : null,
      eventCount: capture.events.isNotEmpty ? capture.events.length : null,
      eventChannels: capture.events.isNotEmpty ? counts : null,
      eventTitles: inlineEventTitles(capture.events),
      eventsDropped: capture.eventsDropped > 0 ? capture.eventsDropped : null,
      settled: capture.settled,
      waited: capture.waited,
      landed: capture.landed,
      guessed: capture.guessed,
      digest: digest,
      strayFrames: capture.strayFrames,
      failure: capture.failure,
      keyboard: capture.keyboard,
    );

    // A beat with no frame. There is no picture to write, no tree to read, no
    // semantics and no movie — what it has is its own content, and the record
    // says which kind of content that is.
    //
    // Nothing was drawn here, so the picture in force is still whatever the
    // step before it photographed: the beat passes that digest on rather than
    // its own payload's, and a flow that stalls across a `document` is still
    // seen to have stalled.
    if (capture.kind != ScenarioCaptureKind.screen) {
      if (digestByIndex[capture.parent] case var inherited?) {
        digestByIndex[capture.index] = inherited;
      }
    }
    switch (capture.kind) {
      case ScenarioCaptureKind.document:
        var fileName = scenarioFileSafe(
          capture.fileName ?? capture.name ?? 'document',
        );
        var path = '$base.$fileName';
        File(path).writeAsBytesSync(capture.payload!);
        record(
          beat(
            ScenarioStepKind.document,
            payloadFile: path,
            mimeType: capture.mimeType,
            payloadBytes: capture.payload!.length,
            digest: _digest(capture.payload!),
          ),
        );
        return;
      case ScenarioCaptureKind.notification:
        record(
          beat(
            ScenarioStepKind.notification,
            notification: capture.notification,
          ),
        );
        return;
      case ScenarioCaptureKind.screen:
        break;
    }

    // A pixel-less capture — a max-length probe — has nothing to write and no
    // path to report; everything else about the step is recorded as ever.
    var imagePath = capture.format == 'none'
        ? ''
        : '$base.${capture.format == 'raw' ? 'raw' : 'png'}';
    if (imagePath.isNotEmpty) File(imagePath).writeAsBytesSync(capture.bytes!);
    // The tree next to the pixels — the step triple's third leg. Written to a
    // file rather than inlined: a run's response stays readable, and the tree
    // is fetched per step by whoever wants it.
    //
    // Read where the picture was taken and carried here, never read off the
    // live app: this capture waited a step to see whether a `screen` would
    // name it, and the app acted again in the meantime. Non-null because the
    // reader is installed beside the listener above, for every screen the
    // listener can be handed.
    // Null on the one capture nobody photographed: the step a timed-out
    // scenario never took, invented by the harness with whatever the tree
    // would still answer — which may be nothing.
    var screen = capture.screen;
    var read = screen?.tree;
    if (read != null) {
      File('$base.tree.json').writeAsStringSync(jsonEncode(read.toJson()));
    }
    var digest = _digest(capture.bytes!);
    // Only a verb that acts can be told it acted for nothing, and a failure's
    // capture already says everything. The flag is a fact, not a verdict — a
    // capture parked mid-flight with `Settle.none` is legitimately unchanged.
    //
    // `screen` used to be excluded here, on the grounds that it was "a
    // deliberate second picture of the same frame". It is not one any more:
    // where the screen did not move — nothing drawn since the capture, or
    // frames drawn and the render proven identical on dimensions, style,
    // words, tree read and bytes — the name lands on the capture that took
    // the frame and no second step exists. What still reaches this line is
    // a `screen` that declined to adopt — a second name on one frame, a
    // branch's first capture, `force: true` — and for those the flag says
    // something true.
    // Never on a pixel-less capture: every probe step digests the same empty
    // bytes, and "unchanged" would be a statement about pixels nobody took.
    var unchanged =
        capture.format != 'none' &&
        capture.verb != null &&
        capture.failure == null &&
        digestByIndex[capture.parent] == digest;
    digestByIndex[capture.index] = digest;
    // The seventh, and only when a catalog was wired up: which translation
    // keys this screen shows and where. Flattened out of the same read as the
    // tree — an export asking "which screens show this key" should not
    // have to parse every node of every step to find out.
    var keys = read?.translationKeys() ?? const [];
    var unkeyed = read?.unkeyedText() ?? const [];
    if (keys.isNotEmpty || unkeyed.isNotEmpty || capture.overflowErrors > 0) {
      File('$base.keys.json').writeAsStringSync(
        jsonEncode({
          'keys': [for (var key in keys) key.toJson()],
          if (unkeyed.isNotEmpty)
            'unkeyed': [for (var text in unkeyed) text.toJson()],
          // Layout overflow errors the expansion filter swallowed on the way
          // to this frame — a screen-level fact of a budget probe, so it rides
          // the artifact the budget reader already opens.
          if (capture.overflowErrors > 0)
            'flexOverflows': capture.overflowErrors,
        }),
      );
    }
    // And the fourth: what a screen reader gets. Absent rather than empty
    // when there is no semantics tree to read — which under `testWidgets`'s
    // default handle is never, but a capture must not invent a screen.
    var semantics = screen?.semantics;
    if (semantics != null) {
      File('$base.semantics.json').writeAsStringSync(jsonEncode(semantics));
    }
    // And the sixth: what the transition *looked like*. A directory of
    // numbered frames rather than one blob, so a player can decode the frame
    // it is on and no other, and so the panel's ordinary image plumbing —
    // which already reads a step's pixels off disk — reads these unchanged.
    String? framesDir;
    if (capture.motion.hasMotion) {
      var directory = Directory('$base.frames')..createSync(recursive: true);
      var extension = capture.format == 'raw' ? 'raw' : 'png';
      for (var (index, frame) in capture.motion.bytes.indexed) {
        File(
          '${directory.path}/'
          '${index.toString().padLeft(4, '0')}.$extension',
        ).writeAsBytesSync(frame);
      }
      framesDir = directory.path;
    }
    // The record every surface reads back, built as the published model so
    // the writer here and the readers everywhere cannot drift a field apart.
    // The paths are this machine's own; the host that knows the worktree
    // relativizes them and assigns the `fw://` address.
    var step = ScenarioRunStep(
      index: capture.index,
      position: capture.position,
      parent: capture.parent,
      branch: capture.branch,
      name: capture.name,
      auto: capture.name == null,
      tags: capture.tags,
      // Null on a pixel-less capture, like every other artifact that does not
      // exist — readers guard on `image != null`, and an empty path would
      // slip past them into a decode.
      image: imagePath.isEmpty ? null : imagePath,
      format: capture.format,
      width: capture.width,
      height: capture.height,
      tree: read == null ? null : '$base.tree.json',
      // Written for overflow counts too: flexOverflows is a screen-level
      // fact of a max-length probe, and it rides the artifact the probe
      // reader already opens.
      keys: keys.isNotEmpty || capture.overflowErrors > 0
          ? '$base.keys.json'
          : null,
      semantics: semantics != null ? '$base.semantics.json' : null,
      texts: capture.texts,
      statusBrightness: capture.statusBrightness,
      navBrightness: capture.navBrightness,
      // The transition into this step: the verb that caused it, and what the
      // app did on the way.
      verb: capture.verb,
      target: capture.target,
      aim: capture.aim,
      events: capture.events.isNotEmpty ? '$base.events.json' : null,
      eventCount: capture.events.isNotEmpty ? capture.events.length : null,
      eventChannels: capture.events.isNotEmpty ? counts : null,
      eventTitles: inlineEventTitles(capture.events),
      eventsDropped: capture.eventsDropped > 0 ? capture.eventsDropped : null,
      frames: framesDir,
      frameCount: framesDir != null ? capture.motion.bytes.length : null,
      frameWidth: framesDir != null ? capture.motion.width : null,
      frameHeight: framesDir != null ? capture.motion.height : null,
      // The fake milliseconds between two frames — what a player runs at to
      // show the animation at the speed the app would have played it.
      frameIntervalMs: framesDir != null
          ? capture.motionInterval!.inMilliseconds
          : null,
      framesDropped: framesDir != null && capture.motion.dropped > 0
          ? capture.motion.dropped
          : null,
      settled: capture.settled,
      waited: capture.waited,
      landed: capture.landed,
      guessed: capture.guessed,
      // Absent on a pixel-less capture, for the reason `unchanged` is false
      // there: every such step digests the same empty bytes, so a *reported*
      // digest would be a claim about pixels nobody took. `compareScenarioRuns`
      // skips a step with no digest, and would otherwise count these as
      // compared-and-identical — a `pixels: keyed` run is mostly ordinary
      // steps with a few pictureless ones among them, and drift would quietly
      // vouch for the screens it never looked at.
      digest: imagePath.isEmpty ? null : digest,
      strayFrames: capture.strayFrames,
      unchanged: unchanged,
      failure: capture.failure,
      keyboard: capture.keyboard,
    );
    record(step);
  };

  // The binding's failure path bypasses the LiveTest: `reportTestException`
  // dumps to console and throws from the binding's own zone, so the LiveTest
  // stays green and the error surfaces as an uncaught zone error. Intercepting
  // the reporter is how the failure lands in the outcome — the same hook
  // `flutter test`'s own bootstrap uses.
  var failures = <ScenarioRunError>[];
  var priorReporter = reportTestException;
  reportTestException = (details, testDescription) {
    var caught = scenarioCaughtErrors ?? const [];
    if (details.stack == null && caught.isNotEmpty) {
      // A details with no stack is the binding's own manufacture — "Multiple
      // exceptions (2) were detected…", a count of what it declined to show.
      // The scenario buffered the real ones as they were reported; each gets
      // its own entry, message and stack intact. The manufactured sentence
      // survives only when the buffer cannot account for it — an exception
      // raised outside the body proper — because dropping an error the run
      // knows happened is worse than one vague line.
      for (var error in caught) {
        failures.add(
          ScenarioRunError(
            error: _diagnosed(error.description),
            stack: error.stack?.toString(),
          ),
        );
      }
      if (!_accountsFor(details, caught)) {
        failures.add(
          ScenarioRunError(error: _diagnosed(details.exceptionAsString())),
        );
      }
    } else {
      failures.add(
        ScenarioRunError(
          error: _diagnosed(details.exceptionAsString()),
          stack: details.stack?.toString(),
        ),
      );
    }
  };

  // The three automatic lanes, installed **here** and not around the scenario
  // body: out here it is ordinary async, once per run rather than once per
  // split replay. Inside the body they would be under FakeAsync, where
  // `await subscription.cancel()` never returns — cancel hands back a
  // root-zone future and the fake clock does not drain the real microtask
  // queue. That hangs the whole run, silently, including scenarios that log
  // nothing (`2026-08-11-scenario-events-spike-findings.md`).
  appEventBuffer = AppEventBuffer();
  scenarioCaughtErrors = [];
  var records = Logger.root.onRecord.listen(
    (record) => recordAppEvent(
      AppEvent.log(
        record.message,
        level: record.level.name,
        logger: record.loggerName.isEmpty ? null : record.loggerName,
      ),
    ),
  );
  // Prints need no zone of ours. `test_api`'s Invoker already forks one with
  // its own print spec — which does not delegate upward, so a zone here would
  // see nothing — and republishes each line on this stream. Nobody used to
  // listen, which is why a `print` inside a scenario went nowhere at all.
  var messages = live.onMessage.listen((message) {
    // The stream's other type is `skip` — the reason a skipped test gives.
    // The walk answers a skipped scenario without loading it, so none should
    // arrive; filtered anyway, because it is a fact about the test, not
    // something the app printed.
    if (message.type != MessageType.print) return;
    recordAppEvent(
      AppEvent.custom(channel: AppChannel.print, title: message.text),
    );
  });

  // What the scenario declared — `scenario(timeout: Timeout(…))`, and
  // `Timeout.none` to opt out entirely — as a progress deadline rather than a
  // budget: see `progress.dart`. Read on every check, because a scenario's
  // body declares its own only once it starts; until then, and for a test
  // that is not a scenario, it is what the test's metadata says, where
  // `Timeout.none` is the harness having switched `test_api`'s timer off.
  scenarioDeclaredTimeout = null;
  Duration? declaredTimeout() {
    var metadata = live.test.metadata.timeout;
    var timeout =
        scenarioDeclaredTimeout ??
        (metadata == Timeout.none
            ? const Timeout(_defaultScenarioTimeout)
            : metadata);
    return timeout.apply(_defaultScenarioTimeout);
  }

  var watch = Stopwatch()..start();
  String? timedOut;
  // Anything the previous scenario's watchdog left is that scenario's, and it
  // may not be quoted at this one.
  scenarioAsyncStall = null;
  var deadline = ProgressDeadline(timeout: declaredTimeout);
  try {
    await Future.any([live.run(), deadline.stalled]);
  } on ScenarioStall catch (stall) {
    // The body is suspended somewhere past the last capture, and what the
    // app printed and did on the way there is the evidence. So the step it
    // never took is taken for it — failed, the diagnosis as its failure,
    // those events on it, no picture — which is the one case where inventing
    // a step is right: the flow really did reach a place nothing photographed.
    timedOut = _captureTimeout(steps, stall: stall, previous: previous);
  } finally {
    deadline.cancel();
    await records.cancel();
    await messages.cancel();
    // Whatever the app did after the last capture goes with it: there is no
    // step for it to belong to, and inventing one would put teardown —
    // `TextInput.clearClient` and its like — on the flow.
    appEventBuffer = null;
    scenarioCaughtErrors = null;
    reportTestException = priorReporter;
    scenarioRunListener = null;
    scenarioScreenReader = null;
    scenarioFlushHeld = null;
    scenarioBreakPlacement = null;
  }

  var errors = [
    if (timedOut case var message?) ScenarioRunError(error: message),
    ...failures,
    for (var error in live.errors)
      ScenarioRunError(
        error: _diagnosed('${error.error}'),
        stack: '${error.stackTrace}',
      ),
  ];
  var passed =
      timedOut == null && live.state.result.isPassing && errors.isEmpty;
  // Every key every catalog was asked for on the way through this
  // scenario, and what it answered — **including the keys whose value never
  // reached a glyph.** The steps say where a key was *seen*; only this says
  // it was read at all, which is the difference between "not on this screen"
  // and "this product never asks for it". Written per scenario, merged
  // across the run by whoever reads them, because a key reached by one
  // scenario is reached.
  var read = TranslationIndex.read;
  var outcome = ScenarioRunOutcome(
    file: file,
    name: name,
    // What it actually ran as — which the caller may not have said, having
    // left the folder's profile to answer.
    device: device,
    ok: passed,
    ms: watch.elapsedMilliseconds,
    steps: steps,
    stepCount: steps.length,
    unchangedCount: steps.where((step) => step.unchanged).length,
    unsettledCount: steps.where((step) => !step.settled && step.waited).length,
    guessedCount: steps.where((step) => step.guessed != null).length,
    errors: passed ? const [] : errors,
    translations: read.isNotEmpty ? read : null,
  );
  return {
    ...outcome.toJson(),
    // Read by the host, not by a reader: the body is still running in there,
    // so this harness is spent and the next run needs a fresh one.
    if (timedOut != null) 'timedOut': true,
  };
}

/// Hands the listener the step a timed-out scenario never took, and returns
/// the diagnosis it carries as its failure.
///
/// What the diagnosis is made of is on `stall.dart`. Read here, at the
/// deadline, while the body is still suspended and the facts still stand:
/// the fake zone's queue, the verb in flight, the sends nobody answered. The
/// tree is read too, when it will be read — the body is suspended between
/// frames, so it usually will — which is what puts `find` and the texts on
/// the failed step.
String _captureTimeout(
  List<ScenarioRunStep> steps, {
  required ScenarioStall stall,
  String? previous,
}) {
  // The capture the body was still holding — the automatic step waiting to
  // see whether the next verb names it — comes first, so the last picture
  // the scenario took is a step, and the invented one follows it.
  try {
    scenarioFlushHeld?.call();
  } catch (_) {
    // A held capture that will not write is a picture lost, not a run.
  }
  var (events, dropped) = appEventBuffer?.drain() ?? (const <AppEvent>[], 0);
  int? microtasks;
  try {
    microtasks = TestWidgetsFlutterBinding.instance.microtaskCount;
  } catch (_) {
    // Readable only while a test is in progress, which a timed-out one is —
    // but the binding asserts rather than answers if it is not.
  }
  var inFlight = scenarioVerbInFlight;
  var where = inFlight ?? scenarioLastVerb;
  var message = stallDiagnosis(
    deadline: stall.timeout,
    kind: stall.kind,
    elapsed: stall.elapsed,
    overdue: stall.work,
    landingTracked: scenarioLandingTrackedWork,
    watchdog: scenarioAsyncStall,
    microtasks: microtasks,
    inFlight: inFlight,
    lastVerb: scenarioLastVerb,
    sends: pendingSends,
    tracked: RealWork.pendingWork,
    pendingImages: PaintingBinding.instance.imageCache.pendingImageCount,
    previousScenario: previous,
    eventsOnFailedStep: events.isNotEmpty,
  );
  ScenarioScreenRead? screen;
  var texts = const <String>[];
  try {
    screen = scenarioScreenReader?.call();
    texts = visibleTextsOf(
      LiveWidgetController(TestWidgetsFlutterBinding.instance),
    );
  } catch (_) {
    // A tree that will not be read mid-suspension is a step without one.
  }
  // Past every index the run has handed out, not only past the steps that
  // reached here: a render that threw spends an index and leaves no step.
  var index =
      steps.fold(
        0,
        (highest, step) => step.index > highest ? step.index : highest,
      ) +
      1;
  ({int? parent, String? branch, String position})? placed;
  try {
    placed = scenarioBreakPlacement?.call();
  } catch (_) {
    // Placed where the flow was last seen instead.
  }
  var pendingImages = PaintingBinding.instance.imageCache.pendingImageCount;
  scenarioRunListener?.call(
    ScenarioStepCapture(
      index: index,
      position: placed?.position ?? '#$index',
      parent: placed == null ? steps.lastOrNull?.index : placed.parent,
      branch: placed?.branch,
      name: null,
      tags: const [],
      format: 'none',
      bytes: Uint8List(0),
      screen: screen,
      texts: texts,
      verb: where?.verb,
      target: where?.target,
      events: events,
      eventsDropped: dropped,
      // Neither is a claim this step can make: nothing waited for the app
      // to go quiet, and whatever was announced never arrived.
      settled: false,
      landed: pendingImages == 0 && RealWork.pending == 0,
      failure: message,
    ),
  );
  return message;
}

/// How long one scenario may go without progress before the run gives up on
/// it — see `progress.dart` for what counts.
///
/// `package:test`'s own default, and reached through
/// [scenarioDefaultTimeout] — `testWidgets` stamps the binding's ten minutes
/// on anything that does not name a timeout, so a runner that wants a deadline
/// of its own has to say so as the scenario is declared. It exists because a
/// scenario that never returns used to take the **whole run** with it: every
/// scenario before it had written its artifacts and none of them were ever
/// reported, which is a worse answer than a red scenario by a wide margin.
///
/// A scenario that genuinely needs longer — a long matrix, a capture-heavy
/// flow at 3× — says `scenario(timeout: …)`, which the message below offers.
const _defaultScenarioTimeout = Duration(seconds: 30);

/// `NAME_MAX` — 255 bytes on APFS, ext4 and NTFS alike, and per path
/// *component* rather than per path.
const scenarioNameMax = 255;

/// The longest suffix a step writes under its own stem, so a label can be
/// budgeted against it. Attachments add a name the scenario chose and are not
/// budgeted for: nothing here can bound what a caller passes.
const _longestStepSuffix = '.semantics.json';

/// Sanitises [name] into one path component, and **caps it**.
///
/// The cap is why this exists rather than a bare `replaceAll`. An automatic
/// capture is labelled by its verb and its target, and a target given as a
/// `Finder` describes itself with the matched widget's whole `toString()` —
/// `TextStyle` dump included. That ran past `NAME_MAX` and threw
/// `FileSystemException`, failing a scenario that had in fact run: the work
/// was done, and only writing it down was impossible.
String scenarioFileSafe(String name, {int max = scenarioNameMax}) {
  var safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  return safe.length <= max ? safe : safe.substring(0, max);
}

/// What a step's bytes hash to — the thing two runs of one suite are compared
/// by, so that comparing them costs neither run's images.
///
/// Truncated, and deliberately: this is compared against another digest from
/// the same flutterware and never parsed, so what matters is that two
/// different pictures collide about as often as never. Sixteen hex characters
/// is 64 bits against a suite of a few thousand steps.
String _digest(List<int> bytes) =>
    digestBytes(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

/// A failure with what this process knows about its own rasterizer appended.
///
/// The engine's Flutter GPU messages name the flag that is missing but not who
/// was meant to pass it, and the one that bites most —
/// `Failed to initialize ShaderLibrary:` — names nothing at all. A scenario
/// runs inside the tester, so it can read the flags the tester was given and
/// finish the sentence.
String _diagnosed(String failure) => withFlutterGpuDiagnosis(
  failure,
  executableArguments: Platform.executableArguments,
  macOS: Platform.isMacOS,
);
