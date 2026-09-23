import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
import 'package:json_annotation/json_annotation.dart';

part 'run_results.g.dart';

/// `devices` — everything this machine can run an app on, and who is already
/// running one on it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunDevicesResult implements PluginResult {
  RunDevicesResult({
    required this.devices,
    required this.live,
    this.updatedAt,
    this.age,
    this.note,
  });

  final List<RunDeviceEntry> devices;

  /// True when a `flutter daemon` is running in this process, so the list is
  /// what it saw rather than what somebody wrote down earlier.
  final bool live;

  /// When the list was taken, ISO-8601. Absent only when nothing has ever
  /// taken one.
  final String? updatedAt;

  /// [updatedAt] as a phrase — `just now`, `12m ago`. Present for the same
  /// reason the field above is: a device list without an age is a claim, and
  /// this one is a reading.
  final String? age;

  /// Said out loud when the list is empty or stale enough to explain, rather
  /// than left for the caller to infer from an empty array.
  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunDevicesResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunDeviceEntry {
  RunDeviceEntry({
    required this.id,
    required this.name,
    required this.connected,
    this.platform,
    this.sdk,
    this.emulator = false,
    this.physical = true,
    this.kind = 'physical',
    this.connection,
    this.running = const [],
  });

  /// What `flutter run -d` takes.
  final String id;

  final String name;

  /// `ios`, `android`, `macos`, `web` — the family, not the architecture.
  final String? platform;

  /// `iOS 18.5`, `Android 12 (API 31)`.
  final String? sdk;

  final bool emulator;

  /// False for the always-there targets — this desktop, the browser — which
  /// cannot be unplugged and are never contended for in the way a phone is.
  final bool physical;

  /// `physical`, `virtual` or `host` — the distinction [physical] cannot make
  /// on its own.
  ///
  /// `physical: false` covers both this Mac and a booted simulator, and they
  /// are nothing alike: one cannot be taken from you and stops when the run
  /// stops, the other is a contended slot somebody had to boot. A caller
  /// choosing words for a row needs to know which.
  final String kind;

  /// Known but not reachable right now. A wireless phone that went to sleep
  /// stays in the list and stops being launchable.
  final bool connected;

  /// `attached` for a cable or a built-in target, `wireless` over the network.
  /// Worth knowing before launching: on the same phone a hot reload measured
  /// 289ms over a cable and 1571ms over wifi.
  final String? connection;

  /// The runs currently holding this device, from any worktree. Empty means
  /// free.
  ///
  /// More than one is possible and is not an error — two apps can share a
  /// phone. It is reported rather than prevented, because launching onto a
  /// busy device is sometimes exactly what was meant.
  final List<RunHolder> running;

  Map<String, Object?> toJson() => _$RunDeviceEntryToJson(this);
}

/// One run's claim on a device, as another worktree sees it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunHolder {
  RunHolder({
    required this.worktree,
    required this.entrypoint,
    required this.since,
    this.package,
    this.entrypointName,
    this.canReload = false,
    this.canInspect = false,
  });

  /// The worktree name — `~` for the main checkout.
  final String worktree;

  /// Package-relative entry point, `lib/main.dart`.
  final String entrypoint;

  /// Its declared name, when it has one.
  final String? entrypointName;

  /// The package, relative to the worktree.
  final String? package;

  /// When the run started, ISO-8601.
  final String since;

  /// Reload and restart are still on offer — meaning both the app and the
  /// `flutter run` that launched it are alive.
  final bool canReload;

  /// The app answers on its VM service: it can be inspected and driven even
  /// if its launcher is gone.
  final bool canInspect;

  Map<String, Object?> toJson() => _$RunHolderToJson(this);
}

/// `entrypoints` — the `main()`s each package can be launched from.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunEntrypointsResult implements PluginResult {
  RunEntrypointsResult({required this.packages, this.note});

  final List<RunEntrypointPackage> packages;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunEntrypointsResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunEntrypointPackage {
  RunEntrypointPackage({
    required this.path,
    required this.declared,
    this.flavors,
    this.entrypoints = const [],
  });

  /// Package path, relative to the worktree.
  final String path;

  /// True when `tool/flutterware.dart` listed these, false when they came from
  /// scanning `lib/`. Worth carrying: a scanned list is a guess that happens to
  /// be right most of the time, and a caller choosing from it should know.
  final bool declared;

  /// The flavors this package declares per platform, as written — shorthand
  /// keys unexpanded, absent when it declares none.
  ///
  /// An empty list is a declaration, not a gap: that platform has no flavors,
  /// and a launch there goes out without `--flavor` the way web always has.
  /// On a platform with a list, a launch naming anything else refuses — so
  /// this is the vocabulary a caller picks from, not a suggestion.
  final Map<String, List<String>>? flavors;

  final List<RunEntrypointEntry> entrypoints;

  Map<String, Object?> toJson() => _$RunEntrypointPackageToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunEntrypointEntry {
  RunEntrypointEntry({
    required this.path,
    required this.name,
    this.description,
    this.flavor,
    this.flavorSource,
    this.flavorByPlatform,
    this.platforms = const [],
    this.devices = const [],
    this.knobs = const [],
  });

  /// Package-relative — what `launch` takes as its `entrypoint`.
  final String path;

  final String name;

  /// What it is, in a line, when the config said. `Kiosk` and `Onboarding`
  /// cannot be told apart by their file names, and this is the field that
  /// tells them apart — for a picker and for an agent alike.
  final String? description;

  /// The `--flavor` this entry point will be built with when nobody overrides
  /// it — its own declaration, or the package's `flutter: default-flavor:`.
  ///
  /// Reported because a flavoured project **cannot be launched without one** —
  /// it is not a preference the caller may skip, and an agent that does not
  /// pass it gets a build failure rather than a default.
  final String? flavor;

  /// `entrypoint` or `pubspec` — which of the two put [flavor] there.
  ///
  /// Absent when nothing declared one. Worth a field because the two are
  /// overridden with different confidence: a pubspec default is the project's
  /// blanket answer, while an entry point's is a deliberate pairing.
  final String? flavorSource;

  /// [flavor] where the declaration varies it by platform, as written —
  /// shorthand keys (`mobile`) unexpanded, absent when it does not.
  ///
  /// A launch onto a device whose platform is in this map builds with the
  /// map's value instead of [flavor]; the platform of every connected device
  /// is in `status`. The map is echoed rather than resolved per device
  /// because three tokens of the author's word say the whole rule, where an
  /// expansion repeats it once per device.
  final Map<String, String>? flavorByPlatform;

  /// What this entry point declares it can run on, as the config wrote it —
  /// `mobile` stays `mobile`. Empty means anything.
  final List<String> platforms;

  /// The ids of the devices currently connected that [platforms] allows.
  ///
  /// The expansion done for you, against the desk as it is right now: a caller
  /// picking an entry point and a device in one go should not have to know
  /// that `desktop` means three platforms, nor which of them is plugged in.
  final List<String> devices;

  /// The knobs this entry point's `main` takes — the optional named parameters
  /// of its signature, with what the config annotated them with.
  final List<RunKnobEntry> knobs;

  Map<String, Object?> toJson() => _$RunEntrypointEntryToJson(this);
}

/// One knob an entry point's `main` takes.
///
/// Read off the signature, not from a config and not by running anything.
/// The name, the kind and the default are the parameter's own; a config can
/// only add what a signature cannot say — a label, options for a type that
/// cannot enumerate itself, or a value a project script works out.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunKnobEntry {
  RunKnobEntry({
    required this.name,
    this.label,
    this.description,
    this.kind,
    this.defaultValue,
    this.defaultSource,
    this.options = const [],
    this.problem,
    this.required = false,
  });

  /// The parameter's name — what `launch` takes as a key.
  @JsonKey(name: 'knob')
  final String name;

  final String? label;
  final String? description;

  /// `string`, `boolean`, `integer`, `number` or `picker` — how it draws.
  ///
  /// Absent when the config names a knob `main` does not take, which is the one
  /// case where there is no parameter to read a kind from.
  final String? kind;

  /// What the launch uses when nothing overrides it: a script's answer when
  /// one was computed, else the parameter's own default.
  @JsonKey(name: 'default')
  final String? defaultValue;

  /// How the default is written, when it is a reference this cannot evaluate —
  /// `ServerUrls.localPort`.
  ///
  /// Present exactly when [defaultValue] is absent and a default exists, so
  /// the two never disagree and neither ever stands in for the other. It is the
  /// answer to a form that showed a blank for a parameter with a default two
  /// lines away: the reader recognises what they wrote, and the value field
  /// stays honest about not knowing it. A project that needs the value itself
  /// declares `from:` and gets it computed.
  @JsonKey(name: 'defaultSource')
  final String? defaultSource;

  /// Everything worth offering — an enum's constants, this machine's
  /// addresses, a list a project script printed, or what the config wrote.
  final List<String> options;

  /// What is wrong with this knob, when something is: a source that could not
  /// answer, or a declaration naming a parameter that is not there.
  final String? problem;

  /// True when a launch that sets no value for this knob is refused — see
  /// [Knob.required].
  ///
  /// Absent rather than false, which is why it goes through a converter: an
  /// entry point's knobs are the longest thing in this reply and almost none of
  /// them are required, so a `"required": false` on every line would be paid
  /// for on every listing to say nothing.
  @JsonKey(toJson: _ifRequired)
  final bool required;

  static bool? _ifRequired(bool value) => value ? true : null;

  Map<String, Object?> toJson() => _$RunKnobEntryToJson(this);
}

/// `launch` — one run started, and how far it got.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunLaunchResult implements PluginResult {
  RunLaunchResult({
    required this.app,
    required this.status,
    required this.waited,
    this.progress,
    this.error,
    this.headline,
    this.logPath,
    this.note,
  });

  /// The run as the ledger now holds it — the same shape `apps` reports.
  final RunAppEntry app;

  /// `running`, `starting`, `stopped`, or `failed`.
  final String status;

  /// False when the call returned without waiting for the app to come up, so
  /// [status] is what was true a moment after spawning and nothing more.
  final bool waited;

  /// The launcher's most recent narration — `Installing and launching…`. On a
  /// wireless device this can sit still for a long time while an OS permission
  /// dialog waits for somebody to notice it.
  final String? progress;

  /// Why it failed, in the launcher's own words and in full.
  ///
  /// Multi-line on purpose. A build failure is a block — the fault, the file
  /// it is in, and usually the steps that fix it — and the one line the tool
  /// ends on (`App failed to start`) is the only part of it that says nothing.
  final String? error;

  /// [error]'s first line that names a fault, for a row with no room for the
  /// rest.
  final String? headline;

  /// Where the whole thing is, since [error] is bounded and a launcher that
  /// died in an unusual way may have put the interesting part above the cut.
  ///
  /// Present only on a failure — the handle is deleted when a launch fails, so
  /// this path is the last thing pointing at what happened.
  final String? logPath;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunLaunchResultToJson(this);
}

/// `reload` / `restart` / `stop` — one thing done to one running app.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunControlResult implements PluginResult {
  RunControlResult({
    required this.action,
    required this.run,
    required this.device,
    required this.entrypoint,
    required this.ok,
    this.ms = 0,
    this.error,
    this.note,
    this.knobs,
  });

  /// `reload`, `restart`, `stop` or `setKnobs`.
  final String action;

  /// Which run it was done to — the id `apps` reports and a selector takes.
  ///
  /// The other half of the ambiguity refusal: a caller told to pass `run`
  /// should be able to see, in the answer, that the one it named is the one
  /// that moved.
  final String run;

  final String device;
  final String entrypoint;

  final bool ok;

  /// Wall time, which is the number that decides whether this is worth doing
  /// instead of relaunching: a hot restart is about a second where a warm
  /// relaunch is ten on Android and twenty-three on a cabled iPhone.
  final int ms;

  final String? error;

  final String? note;

  /// For `setKnobs`: everything the app is now running with, not only what this
  /// call changed. A caller that set one knob and got one knob back would have
  /// to remember the rest to know what it is looking at.
  final Map<String, String>? knobs;

  @override
  Map<String, Object?> toJson() => _$RunControlResultToJson(this);
}

/// `apps` — every run announcing itself under the run dir, probed.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunAppsResult implements PluginResult {
  RunAppsResult({required this.apps, this.swept = 0, this.note});

  final List<RunAppEntry> apps;

  /// Handles deleted during this call because nothing answered them. Reported
  /// rather than done quietly: a run vanishing is a thing that happened, and a
  /// list that silently shrinks is how a phone appears to free itself.
  final int swept;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunAppsResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunAppEntry {
  RunAppEntry({
    required this.run,
    required this.device,
    required this.worktree,
    required this.entrypoint,
    required this.since,
    required this.app,
    required this.launcher,
    this.deviceName,
    this.package,
    this.entrypointName,
    this.defines = const {},
    this.vmService,
    this.log,
    this.error,
    this.mine = false,
  });

  /// What names this launch — what a selector passes as `run`, and what its
  /// handle, log and journal are called on disk.
  ///
  /// Reported because the ambiguity refusal tells a caller to pass one, and a
  /// refusal naming an argument they cannot look up is a dead end. The last
  /// resort by design — a device and an entry point read better — but two
  /// Studios launched from one checkout onto one device differ in nothing
  /// else, not even the address they share.
  final String run;

  final String device;
  final String? deviceName;

  /// The worktree name — `~` for the main checkout.
  final String worktree;

  /// True when that worktree is the one this call was made from. The cockpit
  /// shows other people's runs on purpose, so which are yours has to be a
  /// field rather than an assumption.
  final bool mine;

  final String? package;
  final String entrypoint;
  final String? entrypointName;

  /// The dart-defines it was built with. Part of the identity of what is
  /// running: changing one costs a rebuild, so two runs of the same entry
  /// point with different defines are not the same thing.
  final Map<String, String> defines;

  /// When it started, ISO-8601.
  final String since;

  /// The app answered on its VM service — it can be inspected and driven.
  final bool app;

  /// The `flutter run` that launched it is still alive, which is what makes
  /// reload and restart available: those are registered by the tool, not by
  /// the app, and they go away with it.
  final bool launcher;

  final String? vmService;

  /// Where the launcher's output is being written, for a client that arrived
  /// after the interesting part scrolled past.
  final String? log;

  /// Why the app did not answer, when it did not — a live launcher with a
  /// silent app is a real state, and the reason is the only lead.
  final String? error;

  Map<String, Object?> toJson() => _$RunAppEntryToJson(this);
}

/// `screenshot` — a picture of one running app.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunScreenshotResult implements PluginResult {
  RunScreenshotResult({
    required this.device,
    required this.entrypoint,
    required this.path,
    required this.bytes,
    required this.ms,
    this.note,
  });

  final String device;
  final String entrypoint;

  /// Where the PNG was written.
  ///
  /// A path rather than the bytes: a screenshot is tens of kilobytes of base64
  /// on a wire that also carries the rest of the answer, and every consumer —
  /// a terminal, an MCP client, the panel — wants a file in the end anyway.
  final String path;

  final int bytes;
  final int ms;

  /// Stated when the picture may be incomplete — a run with platform views in
  /// it, which Flutter's layer tree cannot photograph.
  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunScreenshotResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunLogEntry {
  RunLogEntry({required this.source, required this.text, this.error = false});

  /// `app` for what the app printed, `tool` for what `flutter run` said about
  /// itself. A launcher log interleaves them and they answer different
  /// questions.
  final String source;

  final String text;

  /// The launcher marked it as an error. Never inferred from the text.
  final bool error;

  Map<String, Object?> toJson() => _$RunLogEntryToJson(this);
}

/// `emulators` — everything this machine could boot, booted or not.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunEmulatorsResult implements PluginResult {
  RunEmulatorsResult({required this.emulators, this.note});

  final List<RunEmulatorEntry> emulators;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunEmulatorsResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunEmulatorEntry {
  RunEmulatorEntry({
    required this.id,
    required this.name,
    this.booted,
    this.platform,
  });

  /// What `bootEmulator` takes.
  final String id;

  final String name;

  /// `ios` or `android`.
  final String? platform;

  /// True when it is already up, false when it is not — and **null when the
  /// question has no answer for this row**.
  ///
  /// Null is the iOS case, and it is not a gap in the lookup. The daemon lists
  /// exactly one iOS entry, `apple_ios_simulator`, which is not a machine but a
  /// door: booting it opens the Simulator, which can already be running several
  /// devices under names of their own (`iPhone 16e`). Nothing links the two, so
  /// "is it booted" is a question about a thing that does not exist. Measured —
  /// reporting `false` there meant claiming an offline simulator while
  /// `devices` listed a booted one two lines away.
  ///
  /// Android does answer it: a device carries the `emulatorId` it was booted
  /// from.
  final bool? booted;

  Map<String, Object?> toJson() => _$RunEmulatorEntryToJson(this);
}

/// `bootEmulator` — starting one, and what came up.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunBootResult implements PluginResult {
  RunBootResult({
    required this.emulator,
    required this.started,
    required this.ms,
    this.device,
    this.deviceName,
    this.note,
  });

  final String emulator;

  /// The daemon accepted the launch. Says nothing about whether it came up.
  final bool started;

  /// The device id it appeared as, once it did. Null when the wait ran out,
  /// which is not the same as a failure — see [note].
  final String? device;
  final String? deviceName;

  final int ms;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunBootResultToJson(this);
}

/// `inspect` — one reading of one run.
///
/// One action rather than three, and the reason is the app moves. A tree
/// read by one call and a picture taken by the next are two moments of a live
/// app — two readings that happen to agree, or quietly do not. Everything here
/// comes off a single connection, and the tree and the picture off a single
/// inspector group. The catalog reached the same conclusion first; see
/// `ui_catalog_core.dart`'s `inspect`.
///
/// Answers something even when the app is not up. A cold build is minutes
/// during which nothing can be asked of the app — and is exactly when the logs
/// are the only thing worth reading. So [up] is a field rather than an error.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunInspectResult implements PluginResult {
  RunInspectResult({
    required this.device,
    required this.entrypoint,
    required this.up,
    required this.reloadable,
    this.worktree,
    this.mine,
    this.tree,
    this.nodes,
    this.summary,
    this.screenshot,
    this.logs,
    this.logLines,
    this.errors,
    this.progress,
    this.log,
    this.nativeLog,
    this.note,
  });

  final String device;
  final String entrypoint;

  /// The worktree holding it, and whether that is the one asking. A run from
  /// another checkout is readable and not drivable.
  final String? worktree;
  final bool? mine;

  /// The app answered its VM service, so the tree and the picture are
  /// available. False during a build, and after a crash.
  final bool up;

  /// The `flutter run` that launched it is alive, so it can still be reloaded.
  /// Independent of [up]: an app outlives its launcher and keeps everything
  /// except reload.
  final bool reloadable;

  /// The launcher's most recent progress line, when it is still building —
  /// the only narration a ninety-second build has.
  final String? progress;

  /// The widget tree, when asked for.
  final Map<String, Object?>? tree;

  /// How many nodes it has, so a caller can tell an empty answer from a small
  /// one without walking it.
  final int? nodes;

  /// False when the whole tree was asked for rather than the summary. Worth
  /// reporting: a one-screen app is 25 summary nodes and 517 full ones.
  final bool? summary;

  /// Where the PNG was written, when one was asked for.
  ///
  /// A path rather than the bytes: a picture is tens of kilobytes of base64 on
  /// a wire carrying the rest of this answer, and every consumer wants a file
  /// in the end.
  final String? screenshot;

  /// Log lines, when asked for.
  final List<RunLogEntry>? logs;

  /// How many lines matched before [logs] was cut to the tail.
  final int? logLines;

  /// Lines the launcher marked as errors. Reported by default, because with no
  /// other flag "did it break" is the question worth asking first.
  final List<RunLogEntry>? errors;

  /// The launcher's log file, for anyone who would rather tail it themselves.
  final String? log;

  /// The command the `native` lines came from, verbatim.
  ///
  /// Reported because the read it describes is one flutterware performs on the
  /// caller's behalf against a source it does not own, and an answer that
  /// cannot be re-run by hand cannot be checked. Absent when the
  /// platform log was not asked for, or when this device has none to read.
  final String? nativeLog;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunInspectResultToJson(this);
}

/// `act` / `observe` / `navigate` — one drive transaction against a running
/// app, and the observation that closes it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunActResult implements PluginResult, ProducesArtifacts {
  RunActResult({
    required this.device,
    required this.entrypoint,
    required this.verb,
    required this.ok,
    this.screenshotArtifact,
    this.worktree,
    this.target,
    this.error,
    this.failure,
    this.attempts,
    this.elapsedMs,
    this.settled,
    this.settleMs,
    this.frames,
    this.framesEnabled,
    this.lifecycle,
    this.human,
    this.texts,
    this.capture,
    this.lens,
    this.screen,
    this.tree,
    this.nodes,
    this.find,
    this.at,
    this.styles,
    this.screenshot,
    this.logs,
    this.errors,
    this.journal,
    this.next,
    this.note,
    this.layer,
    this.coordinateSpace,
    this.screenshotScale,
    this.screenshotOrigin,
    this.nativeTree,
    this.reconciled,
  });

  final String device;
  final String entrypoint;
  final String? worktree;

  final String verb;

  /// The target as the guest described it — the same spelling the refusal
  /// and the journal use.
  final String? target;

  /// The verb landed. False means it was refused — and the observation
  /// fields below still describe the screen the refusal happened on.
  final bool ok;

  /// The refusal, written to say what to do next.
  final String? error;

  /// Which way it was refused: `notFound`, `multiple`, `covered`,
  /// `offscreen`.
  final String? failure;

  /// Resolve attempts the actionability retry ladder spent; 1 when the first
  /// try reached the target. A route transition costs a handful.
  final int? attempts;

  /// The whole transaction: retries + act + settle.
  final int? elapsedMs;

  /// False means the settle budget ran out with the app still animating — a
  /// spinner, an infinite animation. Reported, never thrown.
  ///
  /// True means nothing is painting, not that the screen is done. The
  /// settle waits on scheduled frames, tickers and image decodes; a pending
  /// network fetch or file read schedules none of those, so a screen that is
  /// still fetching its data reports `settled: true, frames: 0` while it says
  /// "Loading…". Measured on this GUI's own Changes screen, where the navigate
  /// settled instantly and the pane read "Reading…" for another two seconds.
  /// The reply's [texts] are the honest test of whether the content arrived;
  /// `wait` and observe again when they say it has not.
  final bool? settled;

  final int? settleMs;

  /// Frames the app drew during the settle. Zero with [settled] false is an
  /// app that had something to draw and was never given the frame — the
  /// [note] says why.
  final int? frames;

  /// False when the platform has the window hidden or occluded: every frame
  /// was forced, and what a human sees on screen may lag what these fields
  /// describe.
  final bool? framesEnabled;

  final String? lifecycle;

  /// What the human did in the app since the previous step — `tap "Pay"`,
  /// oldest first. Recorded by the guest, journaled as `actor: human`; the
  /// co-driving premise made legible instead of a silently moved screen.
  final List<String>? human;

  /// Every Text and text field on screen after the settle — the projection an
  /// agent reasons about next to the picture.
  final List<String>? texts;

  /// This moment, on disk: `fw:///worktrees/<wt>/flutterware.run/<run>/steps/<stamp>`.
  ///
  /// Every step leaves the same four legs a scenario step leaves — the
  /// picture, the tree, the semantics, the texts — beside a
  /// `<stamp>.capture.json` naming them, whatever this reply chose to
  /// return. That is what makes a second question about a step possible:
  /// the reply is a projection of the capture, not the only copy of it.
  final String? capture;

  /// Which preset shaped this reply — `act`, `look`, `design`, `raw`, with
  /// `(pinned)` when it came from the run rather than from this call.
  ///
  /// Said on every reply on purpose. A pinned lens is state a human or a
  /// co-driving agent may have set, and a reply shaped by something invisible
  /// is the one failure this feature could plausibly cause.
  final String? lens;

  /// The screen: what is on it, what can be acted on, and how it is laid out.
  ///
  /// The default reply, and the thing to read before anything else. About
  /// a twentieth of the tree's tokens, and it answers more — a tree cannot say
  /// which control is disabled or which tab is the current one. Pass
  /// `screen: false` to drop it.
  final Screen? screen;

  /// The widget tree, when asked for — scoped by `treeRoot`, `treeDepth` and
  /// `treeNoise`, and written in the compact spelling (`InspectTree.toJson`'s
  /// `compact`): ids relative to the parent, sources indexed into `files`.
  ///
  /// The heaviest thing in this reply by an order of magnitude. `find`, `at`
  /// and `styles` answer most of what people read a whole tree for, at a
  /// hundredth of the cost.
  final Map<String, Object?>? tree;

  /// Nodes matching `find`, capped — the count is on the wire so a truncated
  /// answer says so.
  final List<Map<String, Object?>>? find;

  /// The chain of nodes under `at`, outermost first and innermost last.
  ///
  /// The chain rather than the hit, because the thing under a point is usually
  /// a `Text` and the thing you meant is the button — or the `Row` three
  /// levels out whose `crossAxisAlignment` is the actual answer.
  final List<Map<String, Object?>>? at;

  /// Every distinct text style on screen, most-used first, when `styles`
  /// asked. The type ramp and the palette in one table.
  final List<InspectStyle>? styles;

  /// How many nodes the tree has *as reported* — after the noise filter and
  /// any depth cut, so it counts what came back rather than what exists.
  final int? nodes;

  /// Where the step's PNG was written — under the run's journal directory,
  /// one file per step.
  final String? screenshot;

  /// What the app printed during this step — since the previous act call,
  /// not since launch.
  final List<RunLogEntry>? logs;

  /// Framework errors this step produced or repeated.
  final List<RunLogEntry>? errors;

  /// The run's journal file this step was appended to — and the index of
  /// every capture this run has taken.
  ///
  /// Worth reading directly, if you can read files. It is JSON-lines, one
  /// object per step, each carrying that step's `capture` address and the
  /// absolute path of its picture, tree, semantics and texts. So "what did
  /// step 7 look like" and "which step changed this" are a file read away
  /// rather than a round trip.
  ///
  /// Two of the legs repay that and two do not: the `.png` and the
  /// `.capture.json` manifest are small and are the point. The `.tree.json` is
  /// **~120 KB of raw nodes** — reading it whole is the 19,500-token mistake
  /// `screen`, `find`, `at` and `styles` exist to avoid. Ask for those instead
  /// and let the host do the narrowing.
  final String? journal;

  /// One line naming what else can be asked of this same capture.
  ///
  /// The same rule the refusals follow: a schema read once at connection time
  /// is not where anyone looks on step forty, so the reply that could have
  /// answered more says what it could have answered. About twenty tokens, and
  /// the same sentence previews and scenarios end their replies with.
  final String? next;

  final String? note;

  /// Which tree this step addressed — absent for the drive layer, `native`
  /// when it went through the platform's own accessibility tree.
  final String? layer;

  /// Native steps only: the space [nativeTree]'s bounds and `{"at": …}` speak
  /// — `px` on Android, window points elsewhere.
  final String? coordinateSpace;

  /// Native steps only: how many screenshot pixels one coordinate unit is.
  /// Divide a point read off the picture by this before passing it to
  /// `{"at": …}`.
  final double? screenshotScale;

  /// Native steps only, and only when the picture is a crop: where its
  /// top-left corner sits, as `x,y` in [coordinateSpace].
  ///
  /// macOS photographs this app's own windows rather than the desktop, so the
  /// picture starts where they do. Add this to a point read off it — after
  /// dividing by [screenshotScale] — to get a coordinate `{"at": …}` speaks.
  /// Absent means the picture and the tree share an origin.
  final String? screenshotOrigin;

  /// Native steps only, and only when asked for: the platform's view tree.
  final Map<String, Object?>? nativeTree;

  /// Native steps only: human entries dropped as this step's own echo — the
  /// guest cannot tell an injected tap from a finger, so the agent's own tap
  /// would otherwise be journaled twice.
  final int? reconciled;

  /// The step's PNG as a job artifact, so a surface that renders images —
  /// MCP first — shows the moment rather than a path. The JSON keeps the
  /// path either way.
  @JsonKey(includeToJson: false)
  final Artifact? screenshotArtifact;

  @override
  @JsonKey(includeToJson: false)
  List<Artifact> get artifacts => [?screenshotArtifact];

  @override
  Map<String, Object?> toJson() => _$RunActResultToJson(this);
}

/// `panels` — what the running app says it offers, from its own devbar
/// plugins.
///
/// The descriptors travel raw. They are already published JSON — the same
/// `PanelDescriptor.toJson` the cockpit decodes — and re-modelling them here
/// would be a second model of the app's declaration, kept in step by hand.
/// `panel_client.dart` refuses that for the same reason.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunPanelsResult implements PluginResult {
  RunPanelsResult({
    required this.device,
    required this.entrypoint,
    required this.panels,
    this.events = const {},
    this.note,
  });

  final String device;
  final String entrypoint;

  /// One `PanelDescriptor` per panel: its knobs with their live values, its
  /// actions with their parameters, its states and its feeds.
  final List<Map<String, Object?>> panels;

  /// Recent feed events, keyed `<panel>/<feed>` — the same channel name the
  /// descriptor gives. Oldest first, capped by the `events` argument.
  final Map<String, List<Map<String, Object?>>> events;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunPanelsResultToJson(this);
}

/// One call against one panel: an action run, a knob set, a state read.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunPanelResult implements PluginResult {
  RunPanelResult({
    required this.device,
    required this.entrypoint,
    required this.panel,
    required this.result,
    this.knobs,
    this.note,
  });

  final String device;
  final String entrypoint;
  final String panel;

  /// What the app answered. For an action, whatever its handler returned; for
  /// a state, the snapshot.
  final Map<String, Object?> result;

  /// The panel's knobs **after** the call — what the app now holds, which is
  /// not always what was asked for: an app may clamp a value or refuse it.
  /// Only on `panelKnob`.
  final List<Map<String, Object?>>? knobs;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunPanelResultToJson(this);
}

/// `network` — the app's HTTP traffic, read from the VM's http profile.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunNetworkResult implements PluginResult {
  RunNetworkResult({
    required this.device,
    required this.entrypoint,
    required this.requests,
    required this.cursor,
    this.note,
  });

  final String device;
  final String entrypoint;

  /// One row per request, oldest first. `status` is absent while a request is
  /// in flight; the same id comes back updated once it completes.
  final List<Map<String, Object?>> requests;

  /// Pass back as `since` to read only what changed after this reply.
  final int cursor;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunNetworkResultToJson(this);
}

/// `device` and `setDevice` — the device this run is on, as something that can
/// be written to.
///
/// One type for both actions, because a write answers with the setting it
/// **re-read** afterwards rather than with an echo of what it was asked: the
/// reply shape is the same, and a write's [settings] simply holds the one row.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunDeviceResult implements PluginResult {
  RunDeviceResult({
    required this.device,
    required this.entrypoint,
    required this.platform,
    required this.settings,
    this.note,
  });

  final String device;
  final String entrypoint;

  /// `ios-simulator` or `android` — which mechanism answered, in the same
  /// spelling the native layer uses.
  final String platform;

  /// One row per setting, refusals included.
  ///
  /// A refused setting is a row and not an absence: *"Android accepts
  /// high_text_contrast_enabled and no Flutter app sees it"* is the useful
  /// half, and a missing row reads as an oversight. Each row carries its
  /// `provenance` — whether a command that owns the setting answered, or the
  /// value is an echo of the store it was written to — because a value on its
  /// own is not evidence.
  final List<Map<String, Object?>> settings;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunDeviceResultToJson(this);
}

/// `networkRequest` — one request in full: headers, bodies, timing events.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunNetworkRequestResult implements PluginResult {
  RunNetworkRequestResult({
    required this.device,
    required this.entrypoint,
    required this.request,
    this.note,
  });

  final String device;
  final String entrypoint;

  final Map<String, Object?> request;

  final String? note;

  @override
  Map<String, Object?> toJson() => _$RunNetworkRequestResultToJson(this);
}

/// `lens` — reading or pinning how much of an observation comes back.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class RunLensResult implements PluginResult {
  RunLensResult({
    required this.device,
    required this.entrypoint,
    required this.lens,
    required this.pinned,
    this.was,
    required this.lenses,
  });

  final String device;
  final String entrypoint;

  /// What is in force now.
  final String lens;

  /// Whether that is a pin on this run, or just the default.
  final bool pinned;

  /// What it was before this call changed it — absent when nothing changed,
  /// so a caller can tell "I set it" from "it was already".
  final String? was;

  /// Every lens and what it contains, so the choice needs no second call.
  final List<Map<String, Object?>> lenses;

  @override
  Map<String, Object?> toJson() => _$RunLensResultToJson(this);
}
