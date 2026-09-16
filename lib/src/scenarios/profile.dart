import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart'
    show LiveTestWidgetsFlutterBinding, TestWidgetsFlutterBinding;
import 'package:meta/meta.dart';

import '../devices.dart';
import '../translations/index.dart';
import 'fonts.dart';
import 'live_binding.dart';
import 'network.dart';
import 'settle.dart';
import 'shots.dart';
import 'reel.dart';
import 'time_mode.dart';

/// What a folder of scenarios is *for* — the devices and languages worth
/// offering them in.
///
/// Declared once, centrally, and named by a folder's `flutter_test_config.dart`
/// (which `flutter test` discovers by walking up from each test file, so a
/// mobile folder and a desktop folder can say different things without either
/// knowing about the other).
///
/// The list is the offered set, and its head is the default. The GUI shows
/// all of it; a bare `flutter test` takes the first. That is one list doing
/// both jobs, and it is why "show every phone in the picker but run two in CI"
/// is not a contradiction — CI brings its own list, and a profile never
/// declares one.
///
/// ```dart
/// // test/scenarios/mobile/flutter_test_config.dart
/// const phones = ScenarioProfile(
///   'phones',
///   devices: [Devices.iphone16, Devices.iphoneSe, Devices.androidTall],
///   languages: ['en', 'fr'],
/// );
///
/// Future<void> testExecutable(FutureOr<void> Function() testMain) =>
///     runScenarios(testMain, profile: phones);
/// ```
class ScenarioProfile {
  const ScenarioProfile(
    this.name, {
    this.devices = const [],
    this.languages = const [],
    this.orientations = const [],
  });

  /// What the profile is called — in the panel, and in a `--profile=` on the
  /// command line.
  final String name;

  /// The devices this folder's scenarios are worth looking at on. The first is
  /// what a run picks when none is named.
  final List<Device> devices;

  /// The locale tags, first one likewise. Empty means the platform default,
  /// which is what a project with one language wants and should not have to
  /// say.
  final List<String> languages;

  /// The orientations worth crossing the devices with, first one likewise.
  /// Empty means portrait, which is what almost every folder wants and should
  /// not have to say.
  ///
  /// Crossed rather than listed alongside the devices: a tablet in landscape is
  /// the same tablet, so `devices × orientations` is two short lists instead of
  /// one long one with the rotatable entries written twice.
  final List<ScreenOrientation> orientations;
}

/// One point of a matrix: the device, orientation and language a scenario is
/// running as.
class ScenarioAssignment {
  const ScenarioAssignment({this.device, this.orientation, this.language});

  final Device? device;
  final String? language;

  /// Null and [ScreenOrientation.portrait] mean the same thing here, and both
  /// leave every name below untouched — see [_landscape].
  final ScreenOrientation? orientation;

  /// The device this assignment actually renders as: the rotation is resolved
  /// once, here, and everything downstream reads plain geometry off it.
  Device? get orientedDevice => device?.oriented(orientation);

  /// Whether this point departs from portrait — the only case that adds a
  /// segment to a name.
  ///
  /// Portrait writes nothing. A name that grew a `-portrait` would move
  /// every artifact path that exists today, in every project, to record the
  /// default. Landscape is the departure, so only landscape is named.
  bool get _landscape =>
      orientation == ScreenOrientation.landscape &&
      (device?.canRotate ?? false);

  /// What names this assignment in a test's description and in an artifact
  /// path — `iphone-16-fr`, `ipad-landscape-fr`, or the empty string when
  /// nothing was assigned.
  String get slug =>
      [?device?.id, if (_landscape) 'landscape', ?language].join('-');

  /// How it reads in a test name: `[iPhone 16 · fr]`, `[iPad · landscape · fr]`.
  String get label =>
      [?device?.label, if (_landscape) 'landscape', ?language].join(' · ');

  bool get isEmpty => device == null && language == null && !_landscape;
}

/// The assignment the scenarios being declared right now belong to.
///
/// Set by [runScenarios] around each pass and read by `scenario()` **as it
/// declares**, so every test carries its own axes rather than reading a mutable
/// global when it runs. Null under the flutterware runner, which supplies the
/// assignment per request instead.
ScenarioAssignment? scenarioAmbientAssignment;

/// The `testExecutable` a scenario folder's `flutter_test_config.dart` hands to
/// `flutter test`.
///
/// Runs [testMain] once per assignment. With nothing configured that is a
/// single pass at the head of each axis — the fast inner loop, and the reason
/// `flutter test` on a scenario folder stays as quick as it was. CI asks for
/// more:
///
/// ```sh
/// flutter test --dart-define=fw.devices=iphone-se,iphone-16 \
///              --dart-define=fw.languages=en,fr,de \
///              --dart-define=fw.orientations=portrait,landscape
/// FW_DEVICES=iphone-se,iphone-16 FW_LANGUAGES=en,fr flutter test
/// ```
///
/// Both are read, the define wins, and the same pair of sources already serves
/// `screenshots-destination` — one convention for "the host tells the test
/// process something", not two. The loop lives here rather than outside, so a
/// matrix is one invocation and one compile.
///
/// [shots] is the folder's screenshot policy, and it is a fact about the
/// folder in the same way the devices and the languages are. A folder whose
/// captures feed a document generator wants every picture named and nothing
/// else rendered; measured on a real 125-scenario suite, saying it per
/// scenario meant a third of one folder's steps — 65 of 197, 41 MB a pass —
/// being rendered, written and then discarded wholesale by the exporter:
///
/// ```dart
/// Future<void> testExecutable(FutureOr<void> Function() testMain) =>
///     runScenarios(testMain, profile: documentation, shots: Shots.manual);
/// ```
///
/// A `scenario()` that names its own `shots:` still wins, and a folder that
/// says nothing is [Shots.auto] as it always was.
///
/// [keyboard] is the folder's software-keyboard policy, and it is **on**: a
/// scenario that taps a text field raises a keyboard exactly as a phone does,
/// so the layout is seen meeting the smaller screen and the shots are pictures
/// a phone could have taken. See [scenarioAmbientKeyboard] for what turning it
/// off restores and why a suite adopting this sees its pictures move once.
///
/// [network] is what this folder's http requests reach, and it is
/// [ScenarioNetwork.off]: nothing leaves the process, and a request nothing
/// stubbed fails with a message naming itself rather than hanging. A folder
/// whose scenarios are worth pointing at a real service says so once:
///
/// ```dart
/// Future<void> testExecutable(FutureOr<void> Function() testMain) =>
///     runScenarios(testMain, network: ScenarioNetwork.live);
/// ```
///
/// A `scenario()` that names its own `network:` still wins, and so does a run
/// that named one — `--network=live`, or `FW_NETWORK=live` in the bare
/// `flutter test` lane.
///
/// [shadows] is whether this folder's captures carry real shadows, and it is
/// **on**. `flutter_test` hard-codes `debugDisableShadows` to true for every
/// test it runs, which paints a `BoxShadow` with its blur dropped — a solid,
/// hard-edged copy of the shape — and turns a Material `elevation:` into a
/// stroked outline `elevation * 2` wide. That is the right default for a
/// golden file, whose whole job is to be compared across engine versions; it
/// is the wrong one for a picture somebody looks at, and every picture this
/// harness takes is looked at.
///
/// The cost is the one upstream's default buys off: shadow rasterisation is
/// not promised stable from one engine to the next, so a suite that gates on
/// `drift` across a Flutter bump has one more reason for its pictures to move.
/// Run to run on one machine it is deterministic, which is the comparison
/// `previews compare` and the drift report actually make. A folder that would
/// rather keep upstream's says so once, and gets the old pictures back byte
/// for byte:
///
/// ```dart
/// Future<void> testExecutable(FutureOr<void> Function() testMain) =>
///     runScenarios(testMain, profile: goldens, shadows: false);
/// ```
///
/// A suite adopting this version sees every shadowed surface move once — the
/// same shape the keyboard default has, and [scenarioAmbientKeyboard] says
/// what to do about it. The flag is set around each scenario's body and put
/// back before it ends, which is what keeps the binding's own end-of-test
/// check on its debug variables happy.
///
/// The clock this process runs scenarios on. Set once — by the harness when
/// it builds its binding, or by [runScenarios] under bare `flutter test` —
/// and read by the tester where fake and real time part ways.
ScenarioTime scenarioHarnessTime = ScenarioTime.fake;

/// The live binding, created once, for a folder that runs on the real clock
/// under bare `flutter test`. `runScenarios(time: real)` calls it; a config
/// that initializes a binding itself must call this rather than
/// `TestWidgetsFlutterBinding.ensureInitialized()`, because a binding already
/// built is the one the folder gets — and the wrong one is refused here by
/// name rather than found later as a scenario settling in fake seconds on a
/// real clock.
LiveTestWidgetsFlutterBinding ensureLiveScenarioBinding({
  double animations = 0.1,
}) {
  switch (_currentTestBinding()) {
    case LiveTestWidgetsFlutterBinding live:
      return live;
    case null:
      return LiveHarnessBinding(
        animations: animations,
        wrapMessenger: (inner) => inner,
      );
    case var other:
      throw StateError(
        'runScenarios(time: real) needs the live binding, but '
        "${other.runtimeType} is already initialized. In this folder's "
        'flutter_test_config.dart call `ensureLiveScenarioBinding()` instead '
        'of `TestWidgetsFlutterBinding.ensureInitialized()`, or call neither '
        '— runScenarios initializes the right one.',
      );
  }
}

/// The test binding, or null before any is initialized — `instance` throws
/// there, and the throw is the only door the base class leaves.
TestWidgetsFlutterBinding? _currentTestBinding() {
  try {
    return TestWidgetsFlutterBinding.instance;
  } on FlutterError {
    return null;
  }
}

/// Also loads the project's fonts, once, before anything is declared — the
/// step `flutter test` otherwise leaves to each project's own
/// `flutter_test_config.dart`. Without it this lane measures text in the
/// fallback font while the flutterware harness measures it in the real one,
/// and the disagreement surfaces as overflows on screens that do not overflow.
Future<void> runScenarios(
  FutureOr<void> Function() testMain, {
  ScenarioProfile? profile,
  Shots? shots,
  bool keyboard = true,
  bool shadows = true,
  ScenarioNetwork? network,
  Settle? settle,
  ScenarioReelEdit? reel,
  ScenarioTime? time,
}) async {
  // Under the flutterware runner this is called to *ask* what the folder is
  // for, not to declare anything: the harness reads the profile here and
  // declares the files itself, one pass, with the axes the request named.
  // Whatever setup the config does around `testMain` still runs — which is the
  // point of coming through this door rather than parsing the file.
  // Armed before the probe returns, not after: under the harness this function
  // is called only to *ask* what the folder is for, so anything below the
  // early return never runs in the runner's lane. The harness arms it too, for
  // the folder that declares no config at all.
  TranslationIndex.recording = true;

  if (scenarioProbing) {
    scenarioProbedProfile = profile;
    scenarioProbedShots = shots;
    scenarioProbedKeyboard = keyboard;
    scenarioProbedShadows = shadows;
    scenarioProbedNetwork = network;
    scenarioProbedTime = time;
    scenarioProbedSettle = settle;
    scenarioProbedReel = reel;
    return;
  }

  // The clock, resolved the way `network` resolves `FW_NETWORK`: the argument,
  // else the environment, else fake. Under the harness this never runs — the
  // probe returned above — and the harness said its own clock when it built
  // its binding. Resolved before the fonts because the binding has to exist
  // before anything touches the engine.
  var resolvedTime =
      time ??
      switch (Platform.environment['FW_TIME']) {
        null || '' => null,
        var raw => parseScenarioTime(raw),
      };
  if (resolvedTime?.isReal ?? false) {
    ensureLiveScenarioBinding(animations: resolvedTime!.animations);
  }
  scenarioHarnessTime = resolvedTime ?? ScenarioTime.fake;

  // Before the first declaration and after the probe returns: the harness
  // loads its own, and a scenario laid out in the fallback font reports itself
  // as `RenderFlex overflowed by 3.5 pixels` rather than as a font problem.
  //
  // The defaults too, and only here: this line runs under bare `flutter test`
  // alone — the harness probes and returns above — which is exactly the lane
  // whose `--use-test-fonts` boxes every family nobody loads bytes for. See
  // [loadDefaultScenarioFonts] for why the harness must not do this.
  await loadScenarioFonts();
  await loadDefaultScenarioFonts();

  var assignments = scenarioAssignments(profile);
  scenarioAmbientShots = shots;
  scenarioAmbientKeyboard = keyboard;
  scenarioAmbientShadows = shadows;
  scenarioAmbientNetwork = network;
  scenarioAmbientTime = resolvedTime;
  scenarioAmbientSettle = settle;
  scenarioAmbientReel = reel;
  try {
    for (var assignment in assignments) {
      scenarioAmbientAssignment = assignment;
      // More than one pass means the same scenario is declared more than once,
      // so its name has to say which is which. One pass leaves names alone —
      // nobody wants `Counter [iPhone 16 · en]` in a suite that runs one way.
      scenarioAmbientIsMatrix = assignments.length > 1;
      await testMain();
    }
  } finally {
    scenarioAmbientAssignment = null;
    scenarioAmbientIsMatrix = false;
    scenarioAmbientShots = null;
    scenarioAmbientKeyboard = null;
    scenarioAmbientShadows = null;
    scenarioAmbientNetwork = null;
    scenarioAmbientSettle = null;
    scenarioAmbientReel = null;
  }
}

/// Whether the folder being declared right now wants the software keyboard,
/// or null where it said nothing — which is on.
///
/// On by default, and one switch turns it off. A scenario that taps a
/// field now renders with a keyboard over the bottom third of the screen, the
/// way a phone would, so a suite adopting this version sees its pictures move
/// from the first tap on a field onward — once. `keyboard: false` restores the
/// old behaviour byte for byte, and it covers *both* halves: no insets, no
/// slab, and no refusal for a target under the band. `compareScenarioRuns` is
/// how a consumer reads the delta before deciding.
bool? scenarioAmbientKeyboard;

/// What the last probed config said about the keyboard.
bool? scenarioProbedKeyboard;

/// Whether the folder being declared right now wants real shadows, or null
/// where it said nothing — which is on, unlike every other `flutter_test`.
///
/// Read by `scenario()` **as it declares**, like [scenarioAmbientShots] and for
/// the same reason. See [runScenarios] for what the two renderings look like
/// and what turning it back off buys.
bool? scenarioAmbientShadows;

/// What the last probed config said about shadows.
bool? scenarioProbedShadows;

/// What the folder being declared right now said its http requests reach, or
/// null where it said nothing.
///
/// Read by `scenario()` **as it declares**, like [scenarioAmbientShots] and for
/// the same reason. A folder is the right altitude for this: the folder that
/// renders a design system wants nothing to leave the process, and the one
/// that exercises a payment sandbox does — and neither is a fact about a single
/// scenario.
ScenarioNetwork? scenarioAmbientNetwork;

/// What the last probed config said its http requests reach.
ScenarioNetwork? scenarioProbedNetwork;

/// The clock the folder being declared right now runs on, as
/// `runScenarios(time: …)` said it, or null where it said nothing — which is
/// [ScenarioTime.fake].
///
/// A lane is a process, so unlike the slots above nothing per scenario can
/// override this; it is read so the folder can be checked against the
/// binding the harness already built.
ScenarioTime? scenarioAmbientTime;

/// What the last probed config said about its clock, for the harness to
/// check against the package's declaration before it runs anything.
ScenarioTime? scenarioProbedTime;

/// The settle policy the folder being declared right now asked for, or null
/// where it asked for nothing — which is [Settle.standard].
///
/// Read by `scenario()` **as it declares**, like [scenarioAmbientShots] and for
/// the same reason. A folder is the altitude a policy like [Settle.strict]
/// wants: "a spinner in a picture is a bug here" is a fact about a suite, and
/// a scenario that names its own `settle:` still wins.
Settle? scenarioAmbientSettle;

/// What the last probed config said about settling.
Settle? scenarioProbedSettle;

/// The edit the folder being declared right now renders its reels with, or
/// null where it named none — which is the stock one.
///
/// Read by `scenario()` **as it declares**, like [scenarioAmbientSettle] and
/// for the same reason. A folder is a fair altitude for a house style — one
/// frame, one caption band, one closing card for every clip a product ships —
/// and a scenario that names its own `reel:` still wins.
ScenarioReelEdit? scenarioAmbientReel;

/// What the last probed config said about its reels.
ScenarioReelEdit? scenarioProbedReel;

/// The shots policy the folder being declared right now asked for, or null
/// where it asked for nothing.
///
/// Read by `scenario()` **as it declares**, the same way
/// [scenarioAmbientAssignment] is, and for the same reason: a matrix declares
/// one body once per assignment and each declaration must keep what it was
/// made under. A scenario that names its own `shots:` still wins.
Shots? scenarioAmbientShots;

/// Whether more than one assignment is being declared — the switch that puts
/// the axis in a scenario's name.
bool scenarioAmbientIsMatrix = false;

/// Set by the harness while it asks a folder's `flutter_test_config.dart` what
/// its profile is. [runScenarios] answers and declares nothing.
///
/// The seam exists because declaration must stay **synchronous** — `test_api`
/// builds the group the moment the declaring closure returns, so a config that
/// awaits anything before calling `testMain` would declare into a group that
/// had already been built. Asking first, declaring after, keeps both honest.
bool scenarioProbing = false;

/// What the last probed config declared.
ScenarioProfile? scenarioProbedProfile;

/// The shots policy the last probed config declared, alongside its profile.
Shots? scenarioProbedShots;

/// The assignments one `flutter test` invocation should declare: the request's
/// lists when it made any, and the profile's own heads when it did not.
///
/// A device a run names but the table does not know is refused rather than
/// approximated — running at the wrong screen produces a picture that is wrong
/// without looking wrong.
@visibleForTesting
List<ScenarioAssignment> scenarioAssignments(
  ScenarioProfile? profile, {
  String? devicesOverride,
  String? languagesOverride,
  String? orientationsOverride,
}) {
  var deviceIdList = _list(
    devicesOverride ?? _setting('devices', 'FW_DEVICES'),
  );
  var languageList = _list(
    languagesOverride ?? _setting('languages', 'FW_LANGUAGES'),
  );
  var orientationList = _list(
    orientationsOverride ?? _setting('orientations', 'FW_ORIENTATIONS'),
  );

  var devices = <Device?>[];
  if (deviceIdList.isNotEmpty) {
    for (var id in deviceIdList) {
      if (id == fitDeviceId) {
        devices.add(null);
        continue;
      }
      var device = deviceById(id);
      if (device == null) {
        throw ArgumentError.value(
          id,
          'fw.devices',
          'no such device. Accepted: ${deviceIds.join(', ')}',
        );
      }
      devices.add(device);
    }
  } else {
    devices.add(profile?.devices.firstOrNull);
  }

  var languages = <String?>[];
  if (languageList.isNotEmpty) {
    languages.addAll(languageList);
  } else {
    languages.add(profile?.languages.firstOrNull);
  }

  var orientations = <ScreenOrientation?>[];
  if (orientationList.isNotEmpty) {
    for (var name in orientationList) {
      var orientation = orientationById(name);
      if (orientation == null) {
        throw ArgumentError.value(
          name,
          'fw.orientations',
          'no such orientation. Accepted: ${orientationIds.join(', ')}',
        );
      }
      orientations.add(orientation);
    }
  } else {
    orientations.add(profile?.orientations.firstOrNull);
  }

  return [
    for (var device in devices)
      // **A device that cannot turn contributes one point, not two.** Crossing
      // a desktop with both orientations would run it twice for byte-identical
      // pixels, which is a doubled CI bill for a picture nobody asked for
      // twice. The bare surface collapses for the same reason.
      for (var orientation
          in (device?.canRotate ?? false)
              ? orientations
              : const <ScreenOrientation?>[null])
        for (var language in languages)
          ScenarioAssignment(
            device: device,
            orientation: orientation,
            language: language,
          ),
  ];
}

/// A dart-define, then an environment variable — the pair
/// `screenshots-destination` already reads, for the same reason.
String? _setting(String define, String variable) {
  var defined = switch (define) {
    'devices' => const String.fromEnvironment('fw.devices'),
    'languages' => const String.fromEnvironment('fw.languages'),
    'orientations' => const String.fromEnvironment('fw.orientations'),
    _ => '',
  };
  if (defined.isNotEmpty) return defined;
  var value = Platform.environment[variable];
  return (value == null || value.isEmpty) ? null : value;
}

List<String> _list(String? raw) => [
  if (raw != null)
    for (var part in raw.split(','))
      if (part.trim().isNotEmpty) part.trim(),
];
