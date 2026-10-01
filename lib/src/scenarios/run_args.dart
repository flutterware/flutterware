import 'package:flutter/widgets.dart';

import '../devices.dart';
import 'film.dart';
import 'reel.dart';
import 'stage.dart';
import 'motion.dart';
import 'network.dart';
import 'pixels.dart';

/// The type of [ScenarioRunArgs.pixels], which callers naming the field need.
export 'pixels.dart';
import 'profile.dart';

/// One run's axis assignment — device geometry, locale, text scale,
/// brightness, the app's own axes — as the substrate applies it.
///
/// Every field is optional and null means "the test default": a scenario run
/// with no axes is byte-identical to what a bare `flutter test` produces.
class ScenarioRunArgs {
  const ScenarioRunArgs({
    this.size,
    this.pixelRatio,
    this.padding,
    this.platform,
    this.locale,
    this.textScale,
    this.brightness,
    this.accessibility = const ScenarioRunAccessibility(),
    this.captureScale,
    this.captureRaw = false,
    this.captureNative = false,
    this.pixels = ScenarioPixels.all,
    this.record,
    this.film,
    this.reel,
    this.stage,
    this.clockOrigin,
    this.assignment,
    this.expandTranslations,
    this.network,
  });

  /// The assignment a `flutter_test_config.dart` set, as the binding's test
  /// values want it.
  ///
  /// The same translation the host does before it calls the harness — device
  /// vocabulary in, numbers out — done here for the lane that has no host:
  /// a bare `flutter test`, where the profile is all there is.
  factory ScenarioRunArgs.forAssignment(ScenarioAssignment assignment) {
    // Already turned the right way up: the assignment resolves its own
    // rotation, so the numbers below are the ones the layout will meet.
    var device = assignment.orientedDevice;
    return ScenarioRunArgs(
      size: device == null ? null : Size(device.width, device.height),
      pixelRatio: device?.pixelRatio,
      padding: device == null ? null : _paddingOf(device),
      platform: _platformOf(device),
      locale: switch (assignment.language) {
        null => null,
        var tag => () {
          var parts = tag.split(RegExp('[-_]'));
          return parts.length > 1
              ? Locale(parts[0], parts[1])
              : Locale(parts[0]);
        }(),
      },
      assignment: assignment,
    );
  }

  /// These args with the film swapped: the same framing, the same axes, a
  /// different pass.
  ///
  /// What a reel render uses twice — once with [FilmSettings.dry] and no reel
  /// for the take, once with the film and the reel the edit made of it. Every
  /// other field is kept, which is the point: the two passes must see the
  /// same device, locale and clock, or the take describes a run the film
  /// never makes.
  ScenarioRunArgs filming(FilmSettings film, {Reel? reel}) => ScenarioRunArgs(
    size: size,
    pixelRatio: pixelRatio,
    padding: padding,
    platform: platform,
    locale: locale,
    textScale: textScale,
    brightness: brightness,
    accessibility: accessibility,
    captureScale: captureScale,
    captureRaw: captureRaw,
    captureNative: captureNative,
    pixels: pixels,
    record: record,
    film: film,
    reel: reel,
    stage: stage,
    clockOrigin: clockOrigin,
    network: network,
    assignment: assignment,
    expandTranslations: expandTranslations,
  );

  /// These args, re-framed as [device] turned to [orientation] — everything
  /// else kept.
  ///
  /// What the harness applies when a run named no device and the scenario's
  /// folder profile has one: the request still carries the language, the text
  /// scale and the accessibility switches the caller asked for, and only the
  /// screen comes from the folder.
  ///
  /// [orientation] comes from the request even though the device does not,
  /// which is the whole reason it travels the wire as an axis rather than as
  /// pre-rotated numbers: the host cannot rotate a device it never chose.
  ScenarioRunArgs withDevice(Device device, {ScreenOrientation? orientation}) {
    var oriented = device.oriented(orientation);
    return ScenarioRunArgs(
      size: Size(oriented.width, oriented.height),
      pixelRatio: oriented.pixelRatio,
      padding: _paddingOf(oriented),
      platform: _platformOf(oriented),
      locale: locale,
      textScale: textScale,
      brightness: brightness,
      accessibility: accessibility,
      captureScale: captureScale,
      captureRaw: captureRaw,
      captureNative: captureNative,
      pixels: pixels,
      record: record,
      film: film,
      reel: reel,
      stage: stage,
      clockOrigin: clockOrigin,
      network: network,
      // The scenario reads its axes off the assignment, so the device the
      // folder's profile just chose has to land there too — otherwise a body
      // adapting to `s.assignment?.device` sees the one axis the request did
      // not name as missing rather than as resolved.
      assignment: ScenarioAssignment(
        device: device,
        orientation: orientation,
        language: assignment?.language,
        axes: assignment?.axes ?? const {},
      ),
      expandTranslations: expandTranslations,
    );
  }

  /// These args with the app axes of the scenario's folder in place of the
  /// ones the request named — everything else kept.
  ///
  /// What the harness applies to every file: the request names a value for
  /// some axes, the folder's profile declares which axes there are, and only
  /// the two together say what a scenario in that folder is running as. A
  /// value the folder has no axis for is dropped here rather than carried —
  /// its scenarios cannot read it, and a picture labelled with it would claim
  /// a difference that was never made.
  ScenarioRunArgs withAppAxes(Map<String, String> axes) => ScenarioRunArgs(
    size: size,
    pixelRatio: pixelRatio,
    padding: padding,
    platform: platform,
    locale: locale,
    textScale: textScale,
    brightness: brightness,
    accessibility: accessibility,
    captureScale: captureScale,
    captureRaw: captureRaw,
    captureNative: captureNative,
    pixels: pixels,
    record: record,
    film: film,
    reel: reel,
    stage: stage,
    clockOrigin: clockOrigin,
    network: network,
    assignment: ScenarioAssignment(
      device: assignment?.device,
      orientation: assignment?.orientation,
      language: assignment?.language,
      axes: axes,
    ),
    expandTranslations: expandTranslations,
  );

  static EdgeInsets _paddingOf(Device device) => EdgeInsets.fromLTRB(
    device.insetLeft,
    device.insetTop,
    device.insetRight,
    device.insetBottom,
  );

  static TargetPlatform? _platformOf(Device? device) =>
      switch (device?.platform) {
        null => null,
        DevicePlatform.ios => TargetPlatform.iOS,
        DevicePlatform.android => TargetPlatform.android,
        DevicePlatform.macos => TargetPlatform.macOS,
        DevicePlatform.windows => TargetPlatform.windows,
        DevicePlatform.linux => TargetPlatform.linux,
      };

  final ScenarioRunAccessibility accessibility;

  /// The screen in **logical** pixels — what the layout reads from
  /// `MediaQuery`.
  final Size? size;

  final double? pixelRatio;

  /// Safe areas in logical pixels — the notch, without which an `AppBar`
  /// renders under the cutout and a capture misses the exact thing a phone
  /// frame exists to catch.
  final EdgeInsets? padding;

  final TargetPlatform? platform;
  final Locale? locale;
  final double? textScale;
  final Brightness? brightness;

  /// Output pixels per **logical** pixel in captured screenshots, or null for
  /// the device's own ratio (a real screenshot's resolution). Not an axis —
  /// it changes the artifact, never what the app sees.
  final double? captureScale;

  /// What `clock.now()` reads at the start of the scenario, or null for the
  /// project's own pin — which is `pinnedClockOrigin` unless
  /// `tool/flutterware.dart` declared another date.
  ///
  /// **Null is not the wall clock.** Under `FakeAsync` a scenario's clock
  /// advances deterministically — `s.wait(1 day)` moves it a day — but left
  /// to itself it *starts* at whatever time the run happened, so any screen
  /// showing a date differs run to run and no two runs of a suite are
  /// comparable. Every consumer that noticed pinned it by hand; the default is
  /// the pin so that nobody has to. A run that wants the wall clock back asks
  /// for it out loud — `--clock now`, which resolves to an instant before it
  /// reaches here, so the report still names a date somebody could re-run.
  ///
  /// Reaches only code that reads `package:clock` — the Flutter ecosystem's
  /// convention, and what `flutter_test` itself uses. A direct
  /// `DateTime.now()` cannot be intercepted by anything, in any test.
  final DateTime? clockOrigin;

  /// What this run's http requests reach, or null when the request named
  /// nothing and the folder's own answer stands.
  ///
  /// A run-level override rather than an axis: it changes what the app can
  /// talk to, never how the screen is framed, and two runs that differ only
  /// here are the same picture taken twice — which is exactly the claim it is
  /// worth being able to check.
  final ScenarioNetwork? network;

  /// Capture at the device's own pixel ratio — a true screenshot, whatever
  /// the device turned out to be.
  ///
  /// Beats computing a [captureScale] host-side, because the device may have
  /// been chosen by the scenario's folder profile rather than by the caller:
  /// only the guest, at capture time, knows what ratio it is actually
  /// rendering at. Wins over [captureScale] when both are set.
  final bool captureNative;

  /// Capture raw rgba8888 instead of PNG. **Recorded motion follows this
  /// too**, and that is usually what decides it.
  ///
  /// PNG charges ~7.5ms of encoder per picture, and **a recording is what
  /// decides whether that matters**: frames at 33ms arrive in hundreds where
  /// shots arrive in dozens. Measured on the example suite, three repeats,
  /// arms alternated in one warm process:
  ///
  /// | | raw | PNG |
  /// |---|---|---|
  /// | shots only (31 pictures) | 404ms / 48MB | 587ms / 0.3MB |
  /// | recording (31 shots + 340 frames) | **721ms** / 489MB | 3080ms / 6MB |
  ///
  /// So raw is 4.3× with a recording and 31% without — and 31% does not buy
  /// 160× the bytes. Ask for it where a recording is running, or where the
  /// reader must have rgba and has nothing to decode a PNG with.
  ///
  /// Writing the bytes is *not* what raw costs: 489MB measured at ~70ms,
  /// which the page cache absorbs. It looked like a wash for a long time for
  /// a different reason — every raw frame was hashed with `sha1` to make its
  /// drift digest, at 6.19ms against a PNG's 0.03, which is almost exactly
  /// the encoder raw had just skipped. See [digestBytes].
  final bool captureRaw;

  /// Record every transition's frames, or null to capture only the frame each
  /// step ended on — which is what a bare `flutter test` and every CLI run
  /// do, and what costs nothing.
  final MotionRecording? record;

  /// Set when this run is rendering a **film** rather than gathering evidence:
  /// every pumped frame is kept, the verbs are paced for a viewer rather than
  /// for a suite, and a cursor is drawn over the frames on the way out.
  ///
  /// Exclusive with [record] by construction rather than by assertion — the
  /// two want the same seam and want opposite things from it — and the harness
  /// refuses a request that asks for both.
  final FilmSettings? film;

  /// What the film's output shows and when, when an edit has decided.
  ///
  /// Never comes off the wire: a reel is built in this process by an edit
  /// reading a [Take], and there is no serialised form of one to send.
  final Reel? reel;

  /// What the frames are drawn through. Null for [BareStage] — the app with a
  /// cursor over it, which is what a film was before a stage existed.
  final ReelStage? stage;

  /// The axes above, in the vocabulary a scenario body reads —
  /// `ScenarioTester.assignment`.
  ///
  /// The numbers in this object are what the harness *applies*; this is what
  /// the request *named*, and it exists because a body adapting to its axes
  /// (`s.assignment?.language`) must see the same answer under the runner as
  /// under `flutter test` with `FW_LANGUAGES` — a run in Dutch that reads as
  /// no assignment at all was measured on a consumer suite as scenarios
  /// silently passing in English.
  final ScenarioAssignment? assignment;

  /// Which steps get a picture — see [ScenarioPixels].
  final ScenarioPixels pixels;

  /// Pad every translation read — the max-length probe. The number is a rung
  /// in `[1, 100]`: `percent` of each value's own ceiling, which is larger
  /// the shorter the value is (`TranslationIndex.expansionLength`). Applied
  /// through `TranslationIndex.expandPercent` for the request; null for every
  /// ordinary run. Design: `2026-08-19-translation-max-lengths-design.md`.
  final int? expandTranslations;
}

/// The accessibility features a run can turn on — the platform switches a
/// real user flips, applied through the binding's
/// `accessibilityFeaturesTestValue`.
class ScenarioRunAccessibility {
  const ScenarioRunAccessibility({
    this.boldText = false,
    this.highContrast = false,
    this.invertColors = false,
  });

  final bool boldText;
  final bool highContrast;
  final bool invertColors;

  bool get isDefault => !boldText && !highContrast && !invertColors;
}

/// Output pixels per logical pixel for a capture under [args], on a view whose
/// ratio is [devicePixelRatio].
///
/// One definition, because two things ask: the step's own screenshot, and the
/// frames of the transition into it — and a recording that resolved this
/// differently would land on a last frame that did not match the shot it is
/// supposed to become.
double scenarioCaptureScale(ScenarioRunArgs? args, double devicePixelRatio) =>
    (args?.captureNative ?? false)
    ? devicePixelRatio
    : (args?.captureScale ?? 1.0);

/// Set by the flutterware harness for the duration of one run request; null
/// under a bare `flutter test`, where every scenario runs at the test
/// defaults.
///
/// Deliberately not exported from `package:flutterware/flutter_test.dart` —
/// like `scenarioRunListener`, it is the seam between the authoring API and
/// the runner, not part of the authoring API.
ScenarioRunArgs? scenarioRunArgs;
