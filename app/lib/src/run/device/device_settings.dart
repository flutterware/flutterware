import 'dart:io';

/// The device a run is on, as something that can be *written* to.
///
/// Every other layer in the cockpit reads the app. This one reaches past it to
/// the appearance, the text size, the orientation, the locale and the
/// accessibility flags of the machine underneath — the four terminal commands
/// nobody remembers, made a control.
///
/// Deliberately **not** a member of `NativeDriver`, and the platform matrix is
/// why. That driver is an input and observation abstraction (`observe`,
/// `tapNode`, `enterText`, `foreground`) whose two backends are a Swift
/// accessibility helper and `adb`'s `uiautomator`. Settings share neither the
/// mechanism nor the matrix: `simctl` is not the accessibility helper, macOS
/// has settings while publishing almost no Flutter accessibility, and web has
/// settings over the DevTools protocol and no `NativeDriver` at all. One
/// interface answering both questions would be one interface answering two
/// unrelated ones.
///
/// What they do share is *which device is this, really*, and that is already
/// solved: `NativeSession` resolves it three ways and hands one of these back.
abstract class DeviceSettings {
  /// `ios-simulator` or `android` — the same spelling `NativeDriver.platform`
  /// uses, so a reply naming one names the same thing on both layers.
  String get platform;

  /// Every setting this target has, refusals included.
  ///
  /// A refusal is a row, not an absence: *"Android accepts
  /// `high_text_contrast_enabled` and no Flutter app sees it"* is the useful
  /// half, and a missing row reads as an oversight.
  ///
  /// [appSize] reads the running app's root size in logical pixels, when the
  /// caller has an app to ask. It is the only way to know which way up an iOS
  /// simulator is — see [DeviceProvenance.derived] — and its absence is why a
  /// setting can come back [DeviceProvenance.unknown] rather than wrong.
  ///
  /// A reader rather than a value because [write] calls it **again** after a
  /// rotation, to check the device actually turned. That is the one write in
  /// v1 that can report success and do nothing.
  Future<List<DeviceSetting>> read({AppSizeReader? appSize});

  /// Writes one setting and answers with that setting **re-read**.
  ///
  /// Re-read rather than echoed, and that is the whole protocol: a caller gets
  /// what the device says now instead of what it was asked for. The readback
  /// rule, expressed here rather than left to the surface drawing it.
  ///
  /// Throws [DeviceRefusal] when this target cannot do it, when the value is
  /// not one of [DeviceSetting.options], or when the write went out and the
  /// device did not move.
  Future<DeviceSetting> write(
    DeviceSettingId id,
    String value, {
    AppSizeReader? appSize,
  });
}

/// What can be set, in `ScenarioAxes`' own words.
///
/// One vocabulary and not two: these are the field names of
/// `app/lib/src/scenarios/axes.dart`, so a live assignment and a headless one
/// are spelled the same and the promotion between them is a rename rather than
/// a mapping.
///
/// [disableAnimations] is the exception and the exception is worth knowing:
/// there is no reduce-motion axis in `ScenarioAxes`, so this is the one setting
/// here that a scenario cannot express at all.
enum DeviceSettingId {
  brightness,
  textScale,
  orientation,
  language,
  boldText,
  highContrast,
  invertColors,
  disableAnimations;

  static DeviceSettingId? byName(String name) {
    for (var id in values) {
      if (id.name == name) return id;
    }
    return null;
  }
}

/// Where a value came from, which is the difference between evidence and an
/// echo.
///
/// The finding this exists for: three measured settings accept a write, return
/// it from a `defaults read`, survive a relaunch, and are never seen by the
/// app. `defaults write com.apple.Accessibility BoldTextEnabled -bool true`
/// *invented* that key — it did not exist in the domain beforehand — and
/// `defaults read` handed it straight back. A value on its own is not proof of
/// anything, so every one of them carries how it was learned.
enum DeviceProvenance {
  /// A command that **owns** the setting reported it: `simctl ui appearance`,
  /// `cmd uimode night`, `settings get`, `cmd locale get-app-locales`. This is
  /// evidence.
  answered,

  /// The only read available is the store we wrote to. An echo. Say so in the
  /// footnote; never let it pass for [answered].
  written,

  /// Read from the app's own geometry rather than from the device. Orientation
  /// on the iOS simulator is the only case: `simctl` has neither a rotate verb
  /// nor a read, and the run's root node has a width and a height.
  derived,

  /// Nothing answered. The platforms' own third state — `simctl ui` returns
  /// `unsupported` and `unknown` as values, and `settings get` on an unset key
  /// returns the *string* `null`, which is not `0`. Drawn as a dash and never
  /// as a default.
  unknown,
}

/// What the strip draws for one setting.
enum DeviceSettingState {
  /// The device answered with this value. The ordinary day.
  set,

  /// The write landed and nothing has confirmed it yet.
  asked,

  /// The device confirms the value and the running app does not carry it.
  ///
  /// Nothing fills this in v1: every disagreement measured so far is refused on
  /// the platform that has it, because half a control is worse than none. It is
  /// built and drawn because the guest extension that reads the app's own
  /// `MediaQuery` is what fills it, and the anatomy should not move when that
  /// lands.
  notObserved,

  /// No mechanism on this target. [DeviceSetting.refusal] says why.
  unavailable,
}

/// What pressing it costs, said before the click rather than discovered by it.
enum DeviceCost {
  /// Under a third of a second, live, and the app keeps its state.
  free,

  /// The Simulator has to be the front window for the write to land at all, so
  /// this takes the keyboard focus for a moment.
  takesFocus,

  /// The device accepts it and the running app will not see it until it is
  /// launched again.
  relaunchesApp,

  /// The platform tears the app down and back up to apply it. Not shipped by
  /// any v1 setting; here because the vocabulary has to be able to say it.
  restartsApp,
}

/// Whether the write reaches this app or every app on the device.
///
/// Three of the measured mechanisms are app-scoped — Android's per-app locale,
/// and macOS appearance and locale through the sandbox container — and the rest
/// change the machine for everything on it. A surface that cannot tell them
/// apart is a surface that quietly repaints somebody's phone.
enum DeviceScope { device, app }

/// One setting, as the strip draws it and an action reports it.
class DeviceSetting {
  const DeviceSetting({
    required this.id,
    required this.noun,
    this.value,
    this.display,
    this.provenance = DeviceProvenance.unknown,
    this.state = DeviceSettingState.set,
    this.cost = DeviceCost.free,
    this.scope = DeviceScope.device,
    this.options = const [],
    this.openOptions = false,
    this.clearLabel,
    this.atDefault = false,
    this.refusal,
    this.command,
    this.note,
  });

  /// A setting this target has no mechanism for.
  ///
  /// [reason] is a sentence and [command] is the by-hand line where one exists,
  /// because a refusal that teaches the next move is worth more than one that
  /// greys a control out.
  const DeviceSetting.unavailable({
    required this.id,
    required this.noun,
    required String reason,
    this.command,
  }) : value = null,
       display = null,
       provenance = DeviceProvenance.unknown,
       state = DeviceSettingState.unavailable,
       cost = DeviceCost.free,
       scope = DeviceScope.device,
       options = const [],
       openOptions = false,
       clearLabel = null,
       atDefault = false,
       note = null,
       refusal = reason;

  final DeviceSettingId id;

  /// The muted qualifier the chip puts before the value — `Theme`, `Text`,
  /// `Turn`, `Lang`.
  ///
  /// Drawn because the rendering settled it: `large`, `off` and `2` are
  /// unreadable on their own, and no 12px glyph supplies the missing noun.
  final String noun;

  /// The platform's own value, and what [DeviceSettings.write] takes back.
  final String? value;

  /// What the chip shows, when that is not [value] itself — `font_scale 1.5`
  /// for a raw `1.5`, because Android's text scale is a device setting whose
  /// effect is a curve and a bare number would read as a multiplier.
  final String? display;

  final DeviceProvenance provenance;
  final DeviceSettingState state;
  final DeviceCost cost;
  final DeviceScope scope;

  /// What can be written, in [value]'s spelling.
  final List<String> options;

  /// [options] are **suggestions rather than the whole set**, so the picker
  /// offers a field with them beside it instead of a closed row of choices.
  ///
  /// True for exactly one setting, and the platforms are why: a language is
  /// any BCP-47 tag. iOS can list the device's own preferred languages and
  /// Android cannot list anything honest at all, and in neither case is the
  /// list what may be *written*. Drawn as a closed set first, and the
  /// consequence was that the only locale you could pick on Android was the
  /// one already set.
  final bool openOptions;

  /// What an empty value means here, when it means anything — *"Device
  /// language"*.
  ///
  /// Null where clearing is not a thing the platform does: emptying iOS's
  /// `AppleLanguages` is not "use the default", it is handing the simulator a
  /// language list with nothing in it. Android's per-app locale is the one
  /// setting with a real off position, and it says so in its own words.
  final String? clearLabel;

  /// On the platform's own default, so the chip draws quiet. A strip where
  /// nothing has been touched should read as untouched.
  final bool atDefault;

  /// Set exactly when [state] is [DeviceSettingState.unavailable].
  final String? refusal;

  /// The command behind this row — the one that answered, or the one a human
  /// would run instead. Rides the picker's footnote.
  final String? command;

  /// The measured consequence worth knowing before choosing — *"2.0 is ×1.86 at
  /// 14sp and ×1.00 at 100sp"*. Rides the same footnote.
  final String? note;

  DeviceSetting copyWith({
    String? value,
    String? display,
    DeviceProvenance? provenance,
    DeviceSettingState? state,
    bool? atDefault,
  }) => DeviceSetting(
    id: id,
    noun: noun,
    value: value ?? this.value,
    display: display ?? this.display,
    provenance: provenance ?? this.provenance,
    state: state ?? this.state,
    cost: cost,
    scope: scope,
    options: options,
    openOptions: openOptions,
    clearLabel: clearLabel,
    atDefault: atDefault ?? this.atDefault,
    refusal: refusal,
    command: command,
    note: note,
  );

  Map<String, Object?> toJson() => {
    'id': id.name,
    'noun': noun,
    'value': ?value,
    if (display != null && display != value) 'display': display,
    'provenance': provenance.name,
    'state': state.name,
    if (cost != DeviceCost.free) 'cost': cost.name,
    if (scope != DeviceScope.device) 'scope': scope.name,
    if (options.isNotEmpty) 'options': options,
    if (openOptions) 'openOptions': true,
    'clearLabel': ?clearLabel,
    if (atDefault) 'atDefault': true,
    'refusal': ?refusal,
    'command': ?command,
    'note': ?note,
  };
}

/// A device write or read refusing, in a sentence written to be read.
///
/// Its own type rather than `RunRefusal` because it carries [command] — the
/// by-hand line — separately, so a surface can offer it as something to copy
/// rather than only as words inside a paragraph. [toString] folds the two back
/// together for every caller that only has room for a message.
class DeviceRefusal implements Exception {
  DeviceRefusal(this.message, {this.command});

  final String message;

  /// What a human would run instead, when there is such a thing.
  final String? command;

  @override
  String toString() => command == null ? message : '$message\n\n$command';
}

/// Reads the running app's root size in logical pixels, or null when there is
/// no app answering.
///
/// The seam between a device and the app on it, and the only place the two
/// meet in this layer: an iOS simulator will not say which way up it is, and
/// the app's own geometry does.
typedef AppSizeReader = Future<({double width, double height})?> Function();

/// How a backend spawns a process.
///
/// Injectable, and every test in `app/test/run/device/` uses that: the two
/// backends are almost entirely command construction and output parsing, and
/// both halves are worth pinning without a booted device anywhere. The shape is
/// `DevStackCore.runProcess`'s, for the same reason and to the same end.
typedef RunDeviceProcess = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> defaultRunDeviceProcess(
  String executable,
  List<String> arguments,
) => Process.run(executable, arguments);
