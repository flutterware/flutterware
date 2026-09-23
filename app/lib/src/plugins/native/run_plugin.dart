import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/real_work.dart';
import 'package:path/path.dart' as p;

import '../../address/address_scope.dart';
import '../../run/device/device_settings.dart';
import '../../run/device_strip.dart';
import '../../run/entrypoints.dart';
import '../../run/flavors.dart';
import '../../run/handle.dart';
import '../../run/inventory.dart';
import '../../run/flag_memory.dart';
import '../../run/journal.dart';
import '../../run/knob_field.dart';
import '../../run/knobs_tab.dart';
import '../../run/network_tab.dart';
import '../../run/panels_tab.dart';
import '../../run/screen_picture.dart';
import '../../run/launch.dart';
import '../../run/launching_pane.dart';
import '../../run/logs_tab.dart';
import '../../run/refusal.dart';
import '../../run/run_files.dart';
import '../../inspect/elements_view.dart';
import '../../inspect/inspect_dock.dart';
import '../../inspect/semantics_node.dart';
import '../../inspect/semantics_view.dart';
import '../../inspect/transcript.dart';

import '../../ui/capture_button.dart';
import '../../ui/design/design.dart';
import '../../ui/menu.dart';
import '../../ui/picker.dart';
import '../../ui/split_button.dart';
import '../../ui/empty_state.dart';
import '../../ui/loading_state.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../../utils/daemon/device.dart';
import '../native_plugin.dart';
import 'run_address.dart';
import 'run_results.dart';
import 'run_core.dart';

export 'run_core.dart' show RunCore, runPluginId;

/// The GUI half of the run cockpit: a panel, and nothing else.
///
/// What is connected, what is busy, who holds it and what launching does all
/// live in [RunCore], so `fw` and an agent get the same answers from the same
/// code. This class exists because `buildPanel` returns a `Widget`.
/// How the panel draws one of a run's pictures, by the path the journal
/// gave it. The disk by default; a recording's own pictures over one.
typedef RunImage = ImageProvider Function(String path);

ImageProvider _fileImage(String path) => FileImage(File(path));

class RunPlugin extends NativePlugin<RunCore> {
  RunPlugin(super.core, {this.image = _fileImage});

  /// How a step's picture is drawn — see [RunImage].
  final RunImage image;

  /// Starting a `flutter daemon` takes seconds and a cold build takes minutes,
  /// and the panel is worth photographing for neither. Without this a window
  /// capture catches the empty state and reports it as the device list.
  ///
  /// Every branch here has to describe work that is **in flight**. A plugin is
  /// registered as a settle source for as long as its worktree session is open
  /// — not for as long as its panel is mounted — so a branch that reports busy
  /// because data is *missing* rather than *coming* holds up the capture of
  /// every other panel in the window, forever. See [RunCore.isFindingDevices]
  /// for the one that did.
  @override
  String? get busyWith {
    if (core.isFindingDevices) return 'finding devices';
    if (core.isStarting) return 'building';
    // The open pane is mid-read. Without this a capture settles on an empty
    // Screen tab saying `Reading the app…` — which is exactly what the first
    // review of this layout photographed, and it looked like the bug that had
    // just been fixed.
    if (_reading) return 'reading the app';
    return null;
  }

  var _reading = false;

  /// Told by the pane doing the reading. See [busyWith].
  void setReading(bool reading) {
    if (_reading == reading) return;
    _reading = reading;
    notifyChanged();
  }

  // **No `+` in the rail.** There was one, and it was the only way to start a
  // second run: an icon that appeared while the mouse crossed the `Run` row and
  // was invisible the rest of the time. Reported as *the buttons are absent*,
  // which is what a hover-only affordance is. `Run` now lands on the page that
  // starts one ([_RunPanel.build]), so the row itself is the door and a `+`
  // beside it would be a second one to the same place.

  /// The launch desk, always — never a run.
  ///
  /// This is the other half of the sentence above, and for a release it was
  /// missing. `_RunPanel` renders the launch form for the bare address and
  /// always has; the rail is what never handed it one, because
  /// `ShellController.selectPlugin` fills a plugin's row in with its first
  /// child and this plugin's children are its runs. So `Run` opened whichever
  /// app happened to be up, and with one launch in flight — or one failure
  /// nobody had dismissed — there was no click anywhere in the GUI that
  /// reached the form, the device desk, or the boot button for an emulator
  /// that is not a device until it is booted.
  ///
  /// A run still has a row: its own. Two kinds of row, two destinations.
  @override
  List<String> get railLanding => const [];

  @override
  Widget buildPanel(BuildContext context) => _RunPanel(this);
}

/// Runs are the subjects here rather than devices.
///
/// The panel was a list of devices with a run squeezed into each row. That
/// fitted the first slice, strained in the second, and had nowhere to put the
/// third: a screenshot, a widget tree and a log stream do not go in a table
/// row. So it follows the server panel instead — subject chips, a tab strip,
/// and a pane — which is this problem already solved once in this codebase.
///
/// Starting a run is its own page rather than a button per entry point: four to
/// ten entry points as a row of buttons is a wall, and the defines have nowhere
/// to go. See `docs/superpowers/specs/2026-07-31-run-cockpit-panel-design.md`.
class _RunPanel extends StatefulWidget {
  const _RunPanel(this.plugin);

  final RunPlugin plugin;

  @override
  State<_RunPanel> createState() => _RunPanelState();
}

class _RunPanelState extends State<_RunPanel> {
  RunCore get _core => widget.plugin.core;

  @override
  void initState() {
    super.initState();
    _core.track();
  }

  /// A config reload swaps the core under a panel that stays mounted.
  ///
  /// Rebuilding the session builds a new [RunCore]; the widget above this one
  /// keeps its position, so Flutter reuses this `State` and `initState` never
  /// runs again. Without this the new core is never tracked: `computeAll` does
  /// not run, so `entrypointsFor` stays empty and the panel says *no entry
  /// points* about a project that declares several — while an app launched
  /// from one of them is still running and still driveable. No daemon starts
  /// either, so the run vanishes from the cockpit and there is no way left to
  /// stop it. Saving `tool/flutterware.dart` was enough to get there.
  @override
  void didUpdateWidget(_RunPanel old) {
    super.didUpdateWidget(old);
    if (old.plugin != widget.plugin) _core.track();
  }

  RunPlace _resolve(BuildContext context) => runPlace(
    [for (var i = 0; i < 2; i++) AddressScope.segment(context, i) ?? '']
      ..removeWhere((s) => s.isEmpty),
  );

  /// The run this key names, from anybody's worktree.
  ///
  /// By key rather than by identity, because the handle object is replaced on
  /// every probe. Unscoped on purpose: the read-only page exists precisely so
  /// a tool that knows about another checkout's run will say so.
  ///
  /// **It no longer falls back to your first run.** It did, and that is what
  /// left the plugin without a page of its own: `Run` in the rail meant
  /// *whichever run sorts first*, so the one place that could have offered a
  /// device list, an emulator to boot and a launch form was unreachable for as
  /// long as anything was running. An address naming a run that has since
  /// stopped now lands on the same page a fresh worktree lands on.
  RunHandle? _byKey(List<RunHandle> handles, String key) {
    for (var handle in handles) {
      if (handle.key == key) return handle;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) {
        var handles = _core.handles;
        var place = _resolve(context);
        var key = place.isNew ? null : place.runKey;
        // **The live run wins over a failure wearing its key.** A run's key is
        // its entry point, device and flavor, so relaunching what just failed
        // produces a handle and a failure record with the *same* key — and
        // reading the failure first made both rail rows open the obituary
        // while the app they were about was up and driveable, with no way to
        // reach it but Dismiss. A failure is what is left when nothing is
        // running under that name; it is never the more current of the two.
        var shown = key == null ? null : _byKey(handles, key);
        var failed = key == null || shown != null
            ? null
            : _core.failureFor(key);

        // No chip row. The runs are the rail's child rows and were being drawn
        // twice — the mockup had both, and building it made the duplication
        // plain. Which is also why nothing named a run was added back when this
        // page became the plugin's landing: the rail is the list.
        return switch ((failed, shown)) {
          (var failure?, _) => _FailedRunPage(
            core: _core,
            failure: failure,
            onDismiss: () {
              _core.dismissFailure(failure.key);
              // Back to the plugin's own page, which is where the rail's `Run`
              // row goes — the bare address rather than `/new`, so dismissing
              // lands you exactly where clicking `Run` would.
              if (mounted) AddressScope.write(context).setSegments(const []);
            },
          ),
          (_, var handle?) => _RunView(
            core: _core,
            image: widget.plugin.image,
            handle: handle,
            view: place.view,
            onControl: _control,
            onReading: widget.plugin.setReading,
          ),
          _ => _NewRunPage(core: _core, onLaunched: _goTo),
        };
      },
    );
  }

  void _goTo(RunHandle handle) {
    if (!mounted) return;
    AddressScope.write(context).setSegments(runSegments(handle.key));
  }

  Future<void> _control(String action, RunHandle handle) async {
    try {
      await _core.control(action, handle);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

/// One run: its tabs, its header, and whichever pane is open.
class _RunView extends StatefulWidget {
  const _RunView({
    required this.core,
    required this.image,
    required this.handle,
    required this.view,
    required this.onControl,
    required this.onReading,
  });

  final RunCore core;
  final RunImage image;
  final RunHandle handle;
  final RunViewKind view;
  final void Function(String action, RunHandle handle) onControl;

  /// Passed up to the plugin so `busyWith` can hold a capture until the pane
  /// has something worth photographing.
  final ValueChanged<bool> onReading;

  @override
  State<_RunView> createState() => _RunViewState();
}

class _RunViewState extends State<_RunView> {
  /// Lets the strip's refresh reach the open pane without lifting the pane's
  /// read into this widget. The strip belongs to the page and the reading
  /// belongs to the pane; this is the one wire between them.
  final _screen = GlobalKey<_ScreenTabState>();

  /// The device strip's, for the same reason: refresh means *read it all
  /// again*, and on the Screen view the device is half of what is on screen.
  final _device = GlobalKey<_DeviceStripHostState>();

  /// Stops this run and opens the launch form holding what it was launched
  /// with.
  ///
  /// The move somebody makes when the build log has just told them the flavor
  /// was wrong, or a knob was. Without it that is stop, find the form, and
  /// re-answer five fields from memory — and until the rail landed on the form
  /// again, *find the form* was itself impossible.
  ///
  /// The priming goes through [RunCore.lastLaunch] because that is what the
  /// form already reads on open. A run with no package recorded — one launched
  /// before the field existed — simply arrives at an unprimed form rather than
  /// at a half-filled one.
  void _stopAndEdit() {
    var core = widget.core;
    var handle = widget.handle;
    if (handle.package case var package?) {
      core.lastLaunch = (
        device: handle.device,
        package: package,
        entrypoint: handle.entrypoint,
        flavor: handle.flavor,
        // **What was chosen, not what was resolved.** A handle records the
        // knobs the app was *built with*, which includes everything a `from:`
        // worked out for a field the user never touched. Handing that straight
        // to the form types every derived value in as a deliberate override —
        // the SDK path stops tracking whichever flutterware launched you, and
        // a per-worktree port freezes to the one this run happened to get.
        knobs: core.chosenKnobs(package, _entryOf(core, handle), handle.knobs),
      );
    }
    widget.onControl('stop', handle);
    // Immediately, rather than waiting for the ledger to lose the handle: the
    // point of this button is to be somewhere else.
    AddressScope.write(context).setSegments(const []);
  }

  /// The entry point [handle] names, as this config declares it.
  ///
  /// Needed because a knob is a fact about a `main()`'s signature, so deciding
  /// which of a handle's recorded values were *chosen* means knowing which
  /// parameters that entry point has. A path that the config no longer
  /// declares — an entry point renamed since the launch — answers with a bare
  /// reference, whose empty knob list makes [RunCore.chosenKnobs] keep
  /// everything. That is the old behaviour, for the one case where there is
  /// nothing better to go on.
  EntrypointRef _entryOf(RunCore core, RunHandle handle) {
    var package = handle.package;
    if (package != null) {
      for (var entry in core.entrypointsFor(package)) {
        if (entry.path == handle.entrypoint) return entry;
      }
    }
    return EntrypointRef(
      path: handle.entrypoint,
      name: handle.entrypoint,
      declared: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    var core = widget.core;
    var handle = widget.handle;
    var view = widget.view;
    var probe = core.probeOf(handle);
    var log = core.logOf(handle);
    var mine = handle.worktreeName == core.host.worktree.name;
    var state = _RunState.of(
      probe: probe,
      log: log,
      mine: mine,
      handle: handle,
    );
    // Which pane the switch below will pick, decided once: the header drops
    // the capability pill when the pane underneath it is already saying the
    // same words. Same rule the rail follows for a plugin whose status is a
    // reduction over its children — a row does not repeat what the row under
    // it is saying, and `Running Xcode build...` twice, an inch apart, was
    // exactly that.
    var launching =
        !state.canInspect &&
        view != RunViewKind.steps &&
        view != RunViewKind.logs;

    // **Header first, then the tabs.** The design drew them the other way and
    // it read wrong once built: the run is the subject and the tabs are views
    // *of* it, so putting the strip on top made the page look like it belonged
    // to the tab rather than to the app you launched. Reload and stop act on
    // the run whichever pane is open, which is the same argument.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RunHeader(
          handle: handle,
          state: state,
          mine: mine,
          echoedBelow: launching,
          onControl: widget.onControl,
        ),
        _ViewTabs(
          runKey: handle.key,
          view: view,
          enabled: state.canInspect,
          busy:
              view == RunViewKind.screen &&
              (_screen.currentState?.isReading ?? false),
          onRefresh: view == RunViewKind.screen && state.canInspect
              ? () {
                  _screen.currentState?.read();
                  _device.currentState?.read();
                }
              : null,
          capture: view == RunViewKind.screen && state.canInspect
              ? CaptureButton(
                  primary: CaptureTarget(
                    label: 'the screenshot',
                    // The pane's last reading, resolved at click time — a
                    // null is the pane saying it has nothing yet, which ends
                    // the gesture quietly like any other empty capture.
                    capture: () async => _screen.currentState?.imageBytes,
                    suggestedName: () =>
                        '${handle.runLabel.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}'
                        '-screen.png',
                  ),
                )
              : null,
        ),
        const Divider(height: 1),
        // **Over the picture, not on a tab of its own.** A tab strip is
        // exclusive: opening a *Device* tab would close *Screen*, which is a
        // control writing to a page you are not on — the second dev-stack
        // study's finding 12. Here the result of pressing one is in the frame
        // underneath it.
        //
        // Outside the `switch` below, so it survives `!canInspect`: a device
        // answers while a build is running and after an app has died, which
        // makes this the second exception to the tab strip's disable after
        // Steps. What goes unknown in that window is the one setting derived
        // from the app's own geometry, and it says so.
        if (view == RunViewKind.screen)
          _DeviceStripHost(
            key: _device,
            core: core,
            handle: handle,
            canInspect: state.canInspect,
          ),
        Expanded(
          child: switch (view) {
            // The journal and the launcher log are files: they answer while
            // the app builds and after it dies, which is exactly when a
            // post-mortem review wants them — and, for the log, the only
            // window in which anybody is asking what the build is doing.
            // Above the guard for that reason; see [_ViewTabs._fileBacked].
            RunViewKind.steps => _StepsTab(
              handle: handle,
              files: core.files,
              image: widget.image,
            ),
            RunViewKind.logs => LogsTab(core: core, handle: handle),
            _ when !state.canInspect => LaunchingPane(
              core: core,
              handle: handle,
              stage: state.label,
              // Only once something has asked the run. With no probe, a handle
              // that has not answered is as likely to be an app that has been
              // up for hours as a build in flight, and the pane must not turn
              // that into a claim about a build running late.
              elapsed: probe == null
                  ? null
                  : clock.now().difference(handle.startedAt),
              platform: core.platformOf(handle.device),
              onStopAndEdit: mine ? _stopAndEdit : null,
            ),
            RunViewKind.screen => _ScreenTab(
              key: _screen,
              core: core,
              handle: handle,
              clock: core.screenClockOf(handle),
              onReadingChanged: () {
                setState(() {});
                widget.onReading(_screen.currentState?.isReading ?? false);
              },
            ),
            RunViewKind.network => NetworkTab(
              // Keyed by run, like the App tab: a different run behind the
              // same tab is a different app to attach to.
              key: ValueKey(handle.key),
              handle: handle,
              connect: switch (core.readOnly) {
                var why? => (_) => Future.error(RunRefusal(why)),
                null => null,
              },
            ),
            RunViewKind.knobs => _knobsTab(core, handle),
            RunViewKind.panels => PanelsTab(
              // Keyed by run: attaching is per app, and a different run behind
              // the same tab is a different app to attach to.
              key: ValueKey(handle.key),
              handle: handle,
              channels: core.sources.channels,
              memory: FlagMemory(core.runDir, files: core.files),
            ),
          },
        ),
      ],
    );
  }
}

/// Capability, not liveness.
///
/// The S-L1 finding, made visible. Hot reload is registered by the `flutter
/// run` and dies with it; the tree and the screenshots belong to the app and
/// outlive it. A header saying only "running" would hide exactly the difference
/// the buttons beside it are about to demonstrate.
class _RunState {
  const _RunState({
    required this.label,
    required this.canInspect,
    required this.canReload,
    required this.tone,
  });

  factory _RunState.of({
    required RunProbe? probe,
    required LaunchLog? log,
    required bool mine,
    required RunHandle handle,
  }) {
    if (probe == null) {
      return _RunState(
        // Never *not probed yet*, which is a fact about us. This is the
        // headline of the launching pane, and the reader is asking about their
        // app: with no log to go on, the honest answer about a handle that
        // exists and has not answered is the same word an empty log gives.
        label: log?.summary ?? 'starting',
        canInspect: false,
        canReload: false,
        tone: _Tone.quiet,
      );
    }
    if (!probe.canInspect) {
      return _RunState(
        label: log?.stage ?? log?.summary ?? 'building',
        canInspect: false,
        canReload: false,
        tone: _Tone.quiet,
      );
    }
    if (!probe.launcher) {
      return const _RunState(
        // Not "stopped": the app is up and fully inspectable. What is gone is
        // the process that could have reloaded it.
        label: 'no launcher — cannot reload',
        canInspect: true,
        canReload: false,
        tone: _Tone.warn,
      );
    }
    if (!mine) {
      return _RunState(
        label: 'held by ${handle.worktreeName}',
        canInspect: true,
        canReload: false,
        tone: _Tone.quiet,
      );
    }
    return const _RunState(
      label: 'reloadable',
      canInspect: true,
      canReload: true,
      tone: _Tone.good,
    );
  }

  final String label;
  final bool canInspect;
  final bool canReload;
  final _Tone tone;
}

enum _Tone { good, warn, quiet }

class _RunHeader extends StatelessWidget {
  const _RunHeader({
    required this.handle,
    required this.state,
    required this.mine,
    required this.onControl,
    this.echoedBelow = false,
  });

  final RunHandle handle;
  final _RunState state;
  final bool mine;
  final void Function(String action, RunHandle handle) onControl;

  /// The open pane is already saying what the pill would say, so the pill goes.
  ///
  /// True for the launching pane, whose whole headline is the stage. It is
  /// false on Steps and Logs, where the pane is a file and says nothing about
  /// the run — which is precisely when the pill is the only thing that does.
  final bool echoedBelow;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var meta = [
      for (var define in handle.defines.entries)
        '${define.key}=${define.value}',
      'started ${describeAge(clock.now().difference(handle.startedAt))}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.lg,
        FwSpacing.md,
        FwSpacing.md,
        FwSpacing.md,
      ),
      color: context.colors.panel2,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${handle.runLabel} → ${handle.deviceLabel}',
                        style: context.type.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Capability, as a pill rather than a caption — but only
                    // when it is news. "reloadable" is the normal state and
                    // the enabled buttons already say it; the pill appears
                    // when something is missing.
                    if (state.tone != _Tone.good && !echoedBelow) ...[
                      const Gap(FwSpacing.sm),
                      _CapabilityPill(state: state),
                    ],
                    if (!mine) ...[
                      const Gap(FwSpacing.sm),
                      _Tag(handle.worktreeName),
                    ],
                  ],
                ),
                const Gap(2),
                Text(
                  meta,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.caption.copyWith(color: colors.mut2),
                ),
              ],
            ),
          ),
          const Gap(FwSpacing.md),
          // Another worktree's run is shown read-only: it is useful to see, and
          // a tool that knew and would not say would be worse. Driving it is
          // its owner's business.
          if (mine)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FwSplitButton(
                  label: 'Hot reload',
                  icon: Icons.local_fire_department_rounded,
                  onPressed: state.canReload
                      ? () => onControl('reload', handle)
                      : null,
                  entries: [
                    MenuItem(
                      'Hot restart',
                      icon: Icons.restart_alt,
                      onSelected: state.canReload
                          ? () => onControl('restart', handle)
                          : null,
                    ),
                  ],
                ),
                const Gap(FwSpacing.xs),
                _Action(
                  'Stop',
                  Icons.stop_rounded,
                  enabled: true,
                  danger: true,
                  onPressed: () => onControl('stop', handle),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// What the run can still be told to do, in three words and a colour.
///
/// Capability, not liveness — the S-L1 finding made loud. An app whose
/// `flutter run` died keeps its tree and its screenshots and loses hot reload,
/// and the row has to say which of those you have before you press anything.
class _CapabilityPill extends StatelessWidget {
  const _CapabilityPill({required this.state});

  final _RunState state;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = switch (state.tone) {
      _Tone.good => colors.grn,
      _Tone.warn => colors.amber,
      _Tone.quiet => colors.mut2,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        state.label,
        style: context.type.micro.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The Knobs tab: what this run's `main` was called with, editable.
///
/// One lookup rather than one per field — [RunCore.knobEntriesFor] parses the
/// entry point's signature once and answers with the knobs *or* the reason it
/// cannot know them, which are different things and drawn differently.
Widget _knobsTab(RunCore core, RunHandle handle) {
  var offered = core.knobEntriesFor(handle);
  return KnobsTab(
    handle: handle,
    knobs: offered.knobs,
    unknown: offered.unknown,
    onApply: (values) => core.applyKnobs(handle, values),
    interfaceOf: core.hostInterfaceOf,
  );
}

/// Screen | Logs, written into the address.
///
/// The strip is the extension point. `Network` and `Data` are devbar
/// plugins reporting into the cockpit later, so it has to accept tabs this
/// build does not know about — which is why the address carries a tab *name*
/// and reading an unknown one falls back to the screen.
///
/// [InspectTabStrip] rather than a row of buttons: it is what ui_catalog and
/// scenarios already draw above a widget tree, and three surfaces showing the
/// same thing should not be two designs.
class _ViewTabs extends StatelessWidget {
  const _ViewTabs({
    required this.runKey,
    required this.view,
    required this.enabled,
    this.busy = false,
    this.onRefresh,
    this.capture,
  });

  final String runKey;
  final RunViewKind view;

  /// The open pane's capture button, when it shows a picture worth exporting.
  final Widget? capture;

  /// False while the app has nothing to read. The tabs stay visible and go
  /// grey — hiding them would move the page's furniture around every time a
  /// build started, and drawing them normally is what made a building cockpit
  /// read as a broken one.
  ///
  /// It does not reach [_fileBacked]. Those two panes are files.
  final bool enabled;

  /// A reading is in flight; the spinner stands where the button was.
  final bool busy;

  /// Re-reads whatever the open pane shows. Null for a pane that has nothing
  /// to re-read — the log is read from the file on every build.
  final VoidCallback? onRefresh;

  /// The panes that are a file on disk rather than a question put to the app.
  ///
  /// The journal and the launcher log are both written from before there is an
  /// app and survive the one they describe, so neither has any reason to wait
  /// for a VM service — and the log is the *only* thing that can say what a
  /// cold build is doing or why it never finished. It spent a release behind
  /// the same disable as the screenshot: the file grew from byte zero and the
  /// page offered its path as text.
  static const _fileBacked = {'steps', 'logs'};

  static const _tabs = [
    (id: 'screen', label: 'Screen'),
    (id: 'steps', label: 'Steps'),
    (id: 'logs', label: 'Logs'),
    (id: 'network', label: 'Network'),
    (id: 'panels', label: 'App'),
    (id: 'knobs', label: 'Knobs'),
  ];

  @override
  Widget build(BuildContext context) {
    return InspectTabStrip(
      tabs: [
        for (var tab in _tabs)
          InspectDockTab(
            id: tab.id,
            label: tab.label,
            enabled: enabled || _fileBacked.contains(tab.id),
            // Said, because a grey *Screen* beside a live *Logs* is otherwise
            // two guesses: a build in flight, or a run this build cannot read.
            disabledReason: 'waiting for the app — the log is live',
            body: _unused,
          ),
      ],
      current: view.name,
      // No guard here. The strip refuses a disabled tab itself, and a caller
      // that swallowed the tap on top of a strip that drew it alive is how the
      // page came to have five controls that did nothing.
      onSelect: (id) {
        AddressScope.write(context).setSegments(
          runSegments(runKey, view: RunViewKind.byName(id) ?? view),
        );
      },
      // Where the dock puts it, so re-reading is in the same place on all
      // three surfaces. It had a row of its own, which held one icon and a
      // caption and floated between the header and the panes.
      trailing: [
        ?capture,
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: FwSpacing.sm),
            child: SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (onRefresh case var refresh?)
          InspectStripButton(
            icon: Icons.refresh,
            tooltip: 'Read it all again',
            onTap: refresh,
          ),
      ],
    );
  }

  /// The strip reads ids, labels and badges and never builds a body — the run
  /// page keeps its panes, because only one of them is cheap to rebuild.
  static Widget _unused(BuildContext context) => const SizedBox.shrink();
}

/// The device strip, with the reads and the writes behind it.
///
/// The Screen half of the split the launcher-icon research named: [DeviceStrip]
/// takes a list and two callbacks and reads nothing, and this holds the backend
/// and owns the busy state. Every ability it has is [RunCore]'s — the same two
/// methods `run/device` and `run/setDevice` call — so the panel adds nothing an
/// agent or the CLI cannot do.
class _DeviceStripHost extends StatefulWidget {
  const _DeviceStripHost({
    super.key,
    required this.core,
    required this.handle,
    required this.canInspect,
  });

  final RunCore core;
  final RunHandle handle;

  /// Whether the app is answering yet.
  ///
  /// Not an enable flag — the device answers either way, which is why this
  /// strip sits outside the tab strip's disable. It is a *read trigger*: the
  /// one setting whose value is derived from the app's own geometry cannot be
  /// known until there is an app, and the strip mounts while the build is
  /// still running.
  final bool canInspect;

  @override
  State<_DeviceStripHost> createState() => _DeviceStripHostState();
}

class _DeviceStripHostState extends State<_DeviceStripHost> {
  List<DeviceSetting> _settings = const [];

  /// What the strip has to say that no chip can hold — in v1, the refusal from
  /// a target with no backend, which names what would work instead.
  String? _notice;

  var _reading = false;
  final _busy = <DeviceSettingId>{};

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(_DeviceStripHost old) {
    super.didUpdateWidget(old);
    // A different run in the same slot is a different device, not a stale
    // reading of this one.
    if (old.handle.key != widget.handle.key) {
      _settings = const [];
      _notice = null;
      _busy.clear();
      unawaited(_read());
      return;
    }
    // **The app started answering, so one of these has an answer now.** The
    // strip mounts while the build is still running — that is the point of it
    // being outside the disable — and at that moment `orientation` on an iOS
    // simulator is honestly unknown, because it is read from the running app's
    // width and height and there is no running app. Left there, the chip went
    // on saying `—` beside a tree reporting 402×874. Measured on a real
    // simulator, 2026-08-24.
    if (widget.canInspect && !old.canInspect) unawaited(_read());
  }

  /// Public so the tab strip's refresh can reach it, the way it reaches the
  /// picture beside it.
  Future<void> read() => _read();

  Future<void> _read() async {
    // Assigned rather than `setState`, because this is reached from `initState`
    // and `didUpdateWidget`, both of which run inside a build.
    _reading = true;
    try {
      var settings = await widget.core.readDeviceSettings(widget.handle);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _notice = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      // A refusal is the strip's whole content on a target with no backend, and
      // it is drawn rather than hidden: a control that vanishes reads as an
      // oversight, and the sentence names the mechanism that would work.
      setState(() {
        _settings = const [];
        _notice = '$e';
      });
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _set(DeviceSettingId id, String value) async {
    setState(() => _busy.add(id));
    try {
      var written = await widget.core.writeDeviceSetting(
        widget.handle,
        id,
        value,
      );
      if (!mounted) return;
      // Spliced rather than followed by a second full read, and the reason is
      // that the reply already **is** the read: `writeDeviceSetting` answers
      // with that setting re-read from the command that owns it. A second pass
      // over the other seven would be seven subprocesses asking about settings
      // this write cannot have touched.
      setState(() {
        _settings = [
          for (var setting in _settings)
            if (setting.id == id) written else setting,
        ];
        _notice = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _notice = '$e');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => DeviceStrip(
    settings: _settings,
    notice: _notice,
    reading: _reading,
    busy: _busy,
    // Null only where there is nothing to write to. A dead app is not that:
    // the device answers either way, which is the whole reason this sits
    // outside the tab strip's disable.
    onSet: _settings.isEmpty ? null : _set,
  );
}

/// The picture and the widget tree, side by side — the design's Screen tab.
///
/// One reading rather than two. Both come off a single `getRootWidgetTree` in
/// one object group, which is what merging `inspect` into one action allowed: a
/// live app animates and takes in data between calls, so two reads would put a
/// tree beside a picture of a different frame.
///
/// It is not a live mirror, and the UI shows that. Each capture is a render and
/// a PNG — 66ms on this Mac, 42 on a simulator — so polling would run
/// continuously for a screen that is mostly not being watched. A button is the
/// right shape until a mirror is worth the cost.
class _ScreenTab extends StatefulWidget {
  const _ScreenTab({
    super.key,
    required this.core,
    required this.handle,
    required this.clock,
    required this.onReadingChanged,
  });

  final RunCore core;
  final RunHandle handle;

  /// What the cockpit knows about the app moving — see
  /// [RunCore.screenClockOf]. Read here rather than in the pane so that a
  /// rebuild is the only wire: the page already rebuilds on every core
  /// notification, and `didUpdateWidget` is where a pane is told what changed.
  final (int moved, int byCockpit) clock;

  /// So the strip above can swap its refresh button for a spinner. The pane
  /// owns the reading; the page only needs to know one is happening.
  final VoidCallback onReadingChanged;

  @override
  State<_ScreenTab> createState() => _ScreenTabState();
}

class _ScreenTabState extends State<_ScreenTab> {
  Uint8List? _image;

  /// The same picture, decoded — see [_Picture] for why the pane is handed a
  /// frame rather than the bytes it came in.
  ui.Image? _picture;
  var _undecodable = false;
  InspectTree? _tree;

  /// Whether [_tree] came from the app's own walk — see
  /// [InspectRead.fromGuest]. It decides what an empty field in the detail
  /// pane is allowed to mean, which is why it is carried rather than guessed
  /// at from whether some node happens to have a box.
  var _fromGuest = false;
  String? _error;
  var _loading = false;

  /// When the reading on screen was taken, and what the cockpit's `moved`
  /// count stood at then. Together they are the caption: how old the picture
  /// is, and whether anything has reported a change it does not show.
  DateTime? _readAt;
  var _readAtMoved = 0;

  /// The dock's open tab, and whether it is folded away.
  ///
  /// Held here rather than in the address: which reading of the screen is open
  /// is a posture rather than a place, and putting it in the URL would make
  /// the back button undo a glance.
  var _tab = 'elements';
  var _collapsed = false;

  bool get isReading => _loading;

  /// The last reading's picture, for the strip's capture button — bytes the
  /// pane already holds, so exporting one costs no round trip to the app.
  Uint8List? get imageBytes => _image;

  /// What the tree hovers, for the box drawn over the picture.
  ///
  /// Only a guest tree can be drawn. The service extension carries no
  /// position at all — `getLayoutExplorerNode` gives size and constraints,
  /// `parentData` is `<none>` — so a run the cockpit merely attached to has
  /// no rect to draw and the picture stays a picture. Nothing here tests for
  /// that: a node with no `layout` paints nothing, which is the same answer
  /// arrived at without a second flag to keep in step.
  final _highlight = ValueNotifier<String?>(null);

  /// The Semantics tab's own hover, and its reading-order switch.
  ///
  /// Separate from [_highlight] because they are hovers of different trees:
  /// a widget's box comes off [InspectLayout], an utterance's off the
  /// semantics node's own rect, and one notifier holding either would have to
  /// say which every time it was read.
  final _semanticsHighlight = ValueNotifier<SemanticsSnapshotNode?>(null);
  final _focusOrder = ValueNotifier<bool>(false);

  SemanticsSnapshotNode? _semantics;
  SemanticsTranscript? _transcript;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(_ScreenTab old) {
    super.didUpdateWidget(old);
    // A different run in the same tab is a different subject, not a stale
    // picture of this one.
    if (old.handle.key != widget.handle.key) {
      _image = null;
      _picture?.dispose();
      _picture = null;
      _undecodable = false;
      _tree = null;
      _fromGuest = false;
      _semantics = null;
      _transcript = null;
      _semanticsHighlight.value = null;
      _error = null;
      _readAt = null;
      _readAtMoved = 0;
      _read();
      return;
    }
    // **What the cockpit did, the cockpit shows.** A hot reload, a restart or
    // a drive step is the user asking for the app to be different; leaving a
    // picture of the old one up is the pane disagreeing with the button that
    // was just pressed.
    //
    // A human's own taps deliberately do *not* land here. They arrive through
    // the beat poller at up to one batch a second, and re-reading on each
    // would be a render and a full tree walk per tap — polling, wearing a
    // finger. Those move `moved` alone, and the caption says so.
    if (widget.clock.$2 != old.clock.$2 && !_loading) _read();
  }

  @override
  void dispose() {
    _picture?.dispose();
    _highlight.dispose();
    _semanticsHighlight.dispose();
    _focusOrder.dispose();
    super.dispose();
  }

  /// Public so the tab strip's refresh can reach it — see [_RunViewState].
  Future<void> read() => _read();

  Future<void> _read() async {
    // Assigned rather than `setState`, because this is reached from `initState`
    // and `didUpdateWidget` — both inside a build. [_tellThePage] schedules the
    // rebuild that shows it, one frame later, which is what a spinner is for.
    _loading = true;
    _tellThePage();
    try {
      // **Semantics in the same reading, not when the tab opens.** One read
      // is what makes the boxes over the picture exact — a semantics tree
      // fetched later would describe a frame the picture is not of — and it
      // is what makes switching tabs free rather than a second round trip
      // through the app.
      var read = await widget.core.inspectRead(widget.handle, semantics: true);
      // Decoded here rather than in the pane, so that the frame and the caption
      // describing it land in the same build. The picture already on screen is
      // held until this one is ready — a re-read should not blank the pane it
      // is refreshing.
      var picture = await _decodePicture(read.image);
      if (!mounted) {
        picture?.dispose();
        return;
      }
      setState(() {
        _picture?.dispose();
        _image = read.image;
        _picture = picture;
        _undecodable = read.image != null && picture == null;
        _tree = read.tree;
        _fromGuest = read.fromGuest;
        // Typed here rather than in the reading, because the reading is
        // linked by `fw` and the MCP server and a `Rect` is `dart:ui`.
        _semantics = switch (read.semantics?.root) {
          var root? => SemanticsSnapshotNode.fromJson(root),
          _ => null,
        };
        // Derived once per reading rather than per build: the tab badge wants
        // the finding count whether or not the tab is open, and the view would
        // otherwise walk the tree again to get it.
        _transcript = _semantics == null
            ? null
            : SemanticsTranscript.of(_semantics!);
        _semanticsHighlight.value = null;
        _error = null;
        _readAt = clock.now();
        // The count as it stands *now*, not as it stood when the read was
        // asked for: a tap that arrived while the picture was being taken is
        // a tap the picture may well show.
        _readAtMoved = widget.clock.$1;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _tellThePage();
      }
    }
  }

  /// After the frame, never inside it. The page above draws the spinner in
  /// its tab strip, so this is a `setState` on an *ancestor* — and [_read] is
  /// reached from `initState` and `didUpdateWidget`, both of which run while
  /// that ancestor is building. In debug the framework throws there, which
  /// aborted the read before it started and left the pane saying `Reading the
  /// app…` for ever.
  ///
  /// It survived review because `capture` builds the GUI in **release**, where
  /// the assertion is compiled out and the same call merely schedules a
  /// rebuild. A screenshot is not a test of this class of bug.
  void _tellThePage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReadingChanged();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) return _Failed(error);
    // One state for one thing. The dock draws a grip and a strip for a tree
    // that is not there yet, which reads as furniture waiting for a panel
    // rather than as a pane that is busy — so until the first reading lands
    // there is nothing here but the sentence saying so.
    if (_loading && _image == null && _tree == null) {
      return const LoadingState(
        title: 'Reading the app…',
        message: 'Its widget tree, and a picture of what it is showing.',
      );
    }
    // **The picture on top, the tree docked under it** — what previews and the
    // scenarios step page draw, and now the third surface drawing it.
    //
    // What it costs is worth writing down, because it was measured and it is
    // real: at 872×737 the dock draws a desktop app at 475×384 where a
    // third-of-the-width column managed 280×227, and pays for it in tree —
    // about eleven rows at the dock's resting height against thirty-two beside
    // a column. The grip is the answer to that: the dock resizes and
    // collapses, so the trade is the reader's to make per task, where a fixed
    // column was nobody's.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: RunScreenPicture(
              picture: _picture,
              undecodable: _undecodable,
              loading: _loading,
              highlight: _highlight,
              tree: _tree,
              canvas: RunScreenPicture.canvasOf(_tree),
              semanticsHighlight: _semanticsHighlight,
              focusOrder: _focusOrder,
              // Only while the Semantics tab is the one showing — its toggle
              // is the only way to turn the numbers off, so they must not
              // outlive it.
              focusNodes: _tab == 'semantics'
                  ? _transcript?.utterances.map((u) => u.node).toList()
                  : null,
              readAt: _readAt,
              movedSince: widget.clock.$1 != _readAtMoved,
            ),
          ),
          InspectDock(
            available: constraints.maxHeight,
            current: _tab,
            collapsed: _collapsed,
            onChanged: (current, collapsed) => setState(() {
              _tab = current;
              _collapsed = collapsed;
            }),
            // No refresh of its own: the page's strip already carries one and
            // it re-reads both halves. Two buttons for one reading would be
            // two claims about what a reading is.
            tabs: [
              InspectDockTab(
                id: 'elements',
                label: 'Elements',
                body: (context) => _elements(),
              ),
              InspectDockTab(
                id: 'semantics',
                label: 'Semantics',
                badge: _transcript?.findingCount ?? 0,
                body: (context) => SemanticsView(
                  root: _semantics,
                  transcript: _transcript,
                  highlight: _semanticsHighlight,
                  focusOrder: _focusOrder,
                  // Three absences, and they are not the same news. A run the
                  // cockpit merely attached to has no guest to ask; a run that
                  // has one is holding a `SemanticsHandle` for its whole life,
                  // so an empty tree there is the app's own answer.
                  placeholder: _loading
                      ? 'Reading the app…'
                      : !_fromGuest
                      ? 'This run has no flutterware guest in it, and the '
                            'service extension has no semantics to give. '
                            'Launch it through flutterware to read them.'
                      : 'The app has published no semantics tree.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The tree and its detail pane, side by side — the dock's one tab.
  Widget _elements() => ElementsView(
    root: _tree?.root,
    placeholder: _loading
        ? 'Reading the app…'
        : 'The app has not built a frame yet.',
    highlight: _highlight,
    // Paths are shortened against the worktree, and live in the detail pane
    // rather than on every row — which is what the shared view does and what
    // the run panel's own tree did not.
    displayRoot: widget.core.host.worktree.path,
    // Per read, because this pane has two sources. The VM service hands out
    // structure and creation locations and nothing else; the guest walks the
    // app's own elements, so on a run launched through flutterware a node with
    // no box really has none. Said here rather than inferred from empty fields.
    readsWidgets: _fromGuest,
  );
}

/// Bytes to a frame, or null.
///
/// Absence is a null and never an exception, which is the contract the
/// comparison side's shot decoding already settled on: a picture that will not
/// decode is a thing the pane has to *say*, and a throw here would report it as
/// a failed read instead.
Future<ui.Image?> _decodePicture(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    // Announced, because the decode lands on the engine's own threads and
    // schedules no frame: a scenario of this pane would otherwise photograph
    // `Reading the app…` over a picture that was a few milliseconds away.
    return await RealWork.track(() async {
      var codec = await ui.instantiateImageCodec(bytes);
      var frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    }(), label: "the run's screenshot");
  } on Object {
    return null;
  }
}

/// The run's journal, reviewable: what the tools did to this app, step by
/// step, each with its screenshot.
///
/// The human half of co-driving. An agent taps, types, reloads and observes
/// from CLI or MCP; its steps land here with their pictures, so "then I look
/// and confirm" is a scroll rather than an act of faith. A file like the log,
/// polled like the log, and readable while the app builds and after it dies.
class _StepsTab extends StatefulWidget {
  const _StepsTab({
    required this.handle,
    required this.files,
    required this.image,
  });

  final RunHandle handle;

  /// Where the journal and its pictures are read from.
  final RunFiles files;
  final RunImage image;

  @override
  State<_StepsTab> createState() => _StepsTabState();
}

class _StepsTabState extends State<_StepsTab> {
  var _entries = const <JournalEntry>[];

  /// Which step is open. Null follows the newest as more arrive — the state
  /// the tab opens in, and returns to when you select the last row.
  int? _selected;

  StreamSubscription<void>? _refresh;

  void _watch() {
    unawaited(_refresh?.cancel());
    var path = journalPathFor(widget.handle);
    _refresh = path == null
        ? null
        : widget.files.changes(path).listen((_) => _reread());
  }

  @override
  void initState() {
    super.initState();
    _reread();
    _watch();
  }

  @override
  void didUpdateWidget(_StepsTab old) {
    super.didUpdateWidget(old);
    if (old.handle.key != widget.handle.key) {
      _selected = null;
      _watch();
      _reread();
    }
  }

  @override
  void dispose() {
    unawaited(_refresh?.cancel());
    super.dispose();
  }

  /// Not in `build`, for the same reason the log tab says: the journal is a
  /// file, and the panel rebuilds far more often than the file changes.
  void _reread() {
    if (!mounted) return;
    var entries = readJournal(widget.handle, tail: 500, files: widget.files);
    setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    var entries = _entries;
    if (entries.isEmpty) {
      return const _Hint(
        'Nothing has driven this run yet. Steps land here when an agent — '
        'or fw — taps, types, reloads or observes.',
      );
    }
    var selected = (_selected ?? entries.length - 1).clamp(
      0,
      entries.length - 1,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          // `reverse` pins the newest step, which is the one anybody opening
          // the journal came to see — the log tab's argument, unchanged.
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              var index = entries.length - 1 - i;
              return _StepRow(
                files: widget.files,
                image: widget.image,
                entry: entries[index],
                ordinal: index + 1,
                selected: index == selected,
                onTap: () => setState(
                  () => _selected = index == entries.length - 1 ? null : index,
                ),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _StepDetail(
            files: widget.files,
            image: widget.image,
            entry: entries[selected],
          ),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.files,
    required this.image,
    required this.entry,
    required this.ordinal,
    required this.selected,
    required this.onTap,
  });

  final RunFiles files;
  final RunImage image;
  final JournalEntry entry;
  final int ordinal;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var caption = [
      ?entry.actor,
      // Which tree the step addressed belongs in the caption, not a detail
      // pane: a native tap and a widget tap look identical in a thumbnail,
      // and "the agent went below the widget tree" is usually the
      // interesting part of a review rather than a footnote.
      ?entry.layer,
      _clock(entry.at),
      if ((entry.attempts ?? 1) > 1) '${entry.attempts} tries',
      if (entry.settled == false) 'did not settle',
    ].join(' · ');
    return Tappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.xs,
        ),
        color: selected ? colors.accentSoft : null,
        child: Row(
          children: [
            _thumbnail(context),
            const Gap(FwSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$ordinal · ${stepSentence(entry)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodySmall.copyWith(
                      color: entry.error != null ? colors.red : colors.ink,
                    ),
                  ),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.micro.copyWith(color: colors.mut3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(BuildContext context) {
    var path = entry.screenshot;
    if (path != null && files.exists(path)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(context.radii.micro),
        child: Image(
          image: ResizeImage.resizeIfNeeded(88, null, image(path)),
          width: 44,
          height: 32,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return SizedBox(
      width: 44,
      height: 32,
      child: Icon(
        _verbIcon(entry.verb),
        size: FwIconSize.lg,
        color: context.colors.mut2,
      ),
    );
  }
}

/// The step's face: the screenshot big, the facts above it, the refusal in
/// red when there was one, and the text projection when there is no picture.
class _StepDetail extends StatefulWidget {
  const _StepDetail({
    required this.files,
    required this.image,
    required this.entry,
  });

  final RunFiles files;
  final RunImage image;
  final JournalEntry entry;

  @override
  State<_StepDetail> createState() => _StepDetailState();
}

class _StepDetailState extends State<_StepDetail> {
  List<String>? _texts;
  String? _textsPath;

  /// Reads the step's texts artifact once per step — the step-page's rule:
  /// the file is already on disk and small, so a synchronous read from the
  /// lifecycle, never a spinner.
  void _loadTexts() {
    var path = widget.entry.texts;
    if (path == _textsPath) return;
    _textsPath = path;
    _texts = null;
    if (path == null) return;
    try {
      _texts = (jsonDecode(widget.files.readString(path) ?? '') as List)
          .cast<String>();
    } on Object {
      _texts = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _loadTexts();
    var entry = widget.entry;
    var colors = context.colors;
    var facts = [
      if (entry.actor case var actor?) 'by $actor',
      if (entry.layer case var layer?) 'through the $layer layer',
      if (entry.reconciled case var count? when count > 0)
        '$count of its own taps came back as human input, and were dropped',
      if ((entry.attempts ?? 1) > 1) '${entry.attempts} tries',
      if (entry.settleMs case var ms?) 'settled in ${ms}ms',
      if (entry.settled == false) 'still animating when observed',
      if (entry.lifecycle case var lifecycle? when lifecycle != 'resumed')
        lifecycle,
      if (entry.logLines case var lines? when lines > 0)
        '$lines log line${lines == 1 ? '' : 's'}',
      if (entry.errorCount case var count? when count > 0)
        '$count error${count == 1 ? '' : 's'}',
    ];
    var screenshot = entry.screenshot;
    var hasShot = screenshot != null && widget.files.exists(screenshot);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            FwSpacing.md,
            FwSpacing.lg,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(stepSentence(entry), style: context.type.body),
                  ),
                  if (hasShot)
                    CaptureButton(
                      primary: CaptureTarget(
                        label: "the step's screenshot",
                        capture: () async =>
                            widget.files.readBytes(screenshot) ?? Uint8List(0),
                        // The journal already names the file after the step;
                        // a save keeps that identity.
                        suggestedName: () => p.basename(screenshot),
                      ),
                    ),
                ],
              ),
              if (facts.isNotEmpty) ...[
                const Gap(FwSpacing.xxs),
                Text(
                  facts.join(' · '),
                  style: context.type.caption.copyWith(color: colors.mut2),
                ),
              ],
              if (entry.error case var error?) ...[
                const Gap(FwSpacing.sm),
                SelectableText(
                  error,
                  style: context.type.bodySmall.copyWith(color: colors.red),
                ),
              ],
            ],
          ),
        ),
        const Gap(FwSpacing.md),
        Expanded(
          child: hasShot
              ? Container(
                  color: colors.bg,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(FwSpacing.md),
                  child: Image(
                    image: widget.image(screenshot),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                )
              : _texts == null
              ? const _Hint('This step kept no picture.')
              : ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FwSpacing.lg,
                    vertical: FwSpacing.sm,
                  ),
                  children: [
                    for (var text in _texts!)
                      if (text.isNotEmpty)
                        SelectableText(text, style: context.type.mono),
                  ],
                ),
        ),
      ],
    );
  }
}

/// `tap "Pay"` — the one spelling the errors, the journal and the strip
/// share.
String stepSentence(JournalEntry entry) =>
    entry.target == null ? entry.verb : '${entry.verb} ${entry.target}';

IconData _verbIcon(String verb) => switch (verb) {
  'tap' ||
  'doubleTap' ||
  'longPress' ||
  'secondaryTap' => Icons.touch_app_outlined,
  'hover' || 'unhover' => Icons.mouse_outlined,
  'drag' => Icons.swipe_outlined,
  'scroll' || 'scrollTo' => Icons.swap_vert,
  'enterText' => Icons.keyboard_outlined,
  'key' => Icons.keyboard_alt_outlined,
  'back' => Icons.arrow_back,
  'wait' => Icons.hourglass_empty,
  'observe' => Icons.visibility_outlined,
  'navigate' => Icons.route_outlined,
  'reload' => Icons.local_fire_department_outlined,
  'restart' => Icons.restart_alt,
  'stop' => Icons.stop_outlined,
  'launch' => Icons.play_arrow_outlined,
  _ => Icons.circle_outlined,
};

/// `14:03:59` from an ISO timestamp, local time — enough to line steps up
/// against the log.
String _clock(String iso) {
  var time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}';
}

/// Pick an entry point, pick a device it can run on, fill its defines, start.
///
/// One column, in that order, and it opens filled in with whatever ran last —
/// so running the same thing again is opening the page and pressing Start.
/// An earlier draft had a two-column workspace with a recents row; it was
/// harder to follow than the four steps it was decorating.
///
/// The entry point comes first, and the fields below depend on it. It was
/// second, under the device, which had the dependency backwards: an entry point
/// declaring `platforms: [mobile]` decides which devices are offerable and
/// what flavor is pre-filled, so choosing it after them meant choosing them
/// twice. Flavor and defines were already downstream of it; the device list is
/// the third thing that was pretending not to be.
class _NewRunPage extends StatefulWidget {
  const _NewRunPage({required this.core, required this.onLaunched});

  final RunCore core;
  final void Function(RunHandle) onLaunched;

  @override
  State<_NewRunPage> createState() => _NewRunPageState();
}

class _NewRunPageState extends State<_NewRunPage> {
  String? _device;
  ({String package, EntrypointRef entry})? _entry;
  final _flavor = TextEditingController();

  /// True once the user has taken the flavor off what the project declares.
  ///
  /// The field is collapsed to a line of text until then, because the answer is
  /// nearly always already written down — in the entry point, or in the
  /// package's `flutter: default-flavor:` — and an empty box beside it invited
  /// filling in something the project had settled two files away.
  var _overridingFlavor = false;
  var _launching = false;

  /// What the form has been told to pass `main`, by parameter name. Absent
  /// means "left alone", which is not the same as empty — the parameter's own
  /// default then applies and nothing is written into the wrapper.
  final _knobs = <String, String>{};
  String? _error;

  RunCore get _core => widget.core;

  List<({String package, EntrypointRef entry})> get _entries => [
    for (var package in _core.packages)
      for (var entry in _core.entrypointsFor(package))
        (package: package, entry: entry),
  ];

  @override
  void dispose() {
    _flavor.dispose();
    super.dispose();
  }

  /// Fills the form from the last launch, and from the first plausible choice
  /// when there has not been one.
  void _prime() {
    var entries = _entries;
    if (entries.isEmpty) return;
    var last = _core.lastLaunch;
    if (_entry == null) {
      var restored = entries
          .where(
            (e) =>
                e.package == last?.package && e.entry.path == last?.entrypoint,
          )
          .firstOrNull;
      _entry = restored ?? entries.first;
      // Only when it really is last time's entry point. The knobs and the
      // flavor of a run belong to the `main()` they were typed for, and
      // restoring them onto whatever entry point happened to sort first put a
      // stale flavor on an unrelated build.
      _rebuildKnobs(restored != null ? last?.knobs ?? const {} : const {});
      // The device before the flavor, because the flavor can depend on it —
      // an entry point pairing `kioskLocal` with `mobile` pre-fills
      // differently for a phone than for this machine.
      _device ??= _pickDevice(preferred: last?.device);
      _resetFlavor(used: restored != null ? last?.flavor : null);
    }
    _device ??= _pickDevice(preferred: last?.device);
  }

  /// The declared flavor, unless [used] records an override.
  ///
  /// Matching the declaration is not an override, so a run launched without
  /// touching the field reopens the page collapsed rather than expanded on a
  /// value it would have used anyway.
  void _resetFlavor({String? used}) {
    var declared = _declaredFlavor.flavor;
    _overridingFlavor = used != null && used.isNotEmpty && used != declared;
    _flavor.text = (_overridingFlavor ? used : declared) ?? '';
  }

  ({String? flavor, FlavorSource source}) get _declaredFlavor {
    var choice = _entry;
    return choice == null
        ? (flavor: null, source: FlavorSource.none)
        : _core.flavorFor(choice.package, choice.entry, device: _device);
  }

  /// The device to select: the one asked for when this entry point allows it,
  /// otherwise the first connected one that it does.
  String? _pickDevice({String? preferred}) {
    var choice = _entry;
    if (choice == null) return null;
    var allowed = _core.devicesFor(choice.entry);
    if (allowed.any((device) => device.id == preferred)) return preferred;
    return allowed
            .where((device) => device.isConnected)
            .map((device) => device.id)
            .firstOrNull ??
        allowed.firstOrNull?.id;
  }

  /// Why the device list is shorter than the desk, when it is.
  ///
  /// Said rather than left to be noticed: a picker that has quietly dropped
  /// the machine you were about to choose is indistinguishable from a tool
  /// that has not found it yet.
  String? get _restriction {
    var platforms = _entry?.entry.platforms ?? const [];
    if (platforms.isEmpty) return null;
    return '${_entry!.entry.name} runs on '
        '${[for (var platform in platforms) platform.name].join(', ')}';
  }

  /// Seeds each field with what the *last launch chose*, and nothing else.
  ///
  /// A default is shown as a hint, not as text. The field's content is what
  /// gets sent, and `launch` fills in the defaults itself — so pre-filling one
  /// here would send it back as an explicit choice, which is how the panel and
  /// the action used to disagree about the same launch. An empty field now
  /// means "whatever the default is", which is also what it looks like.
  /// The caller decides whether [values] belong here: a knob set for one entry
  /// point means nothing on another, because they are different signatures.
  /// [_prime] passes an empty map for exactly that case.
  void _rebuildKnobs(Map<String, String> values) {
    _knobs
      ..clear()
      ..addAll(values);
  }

  /// The knobs this entry point's `main` takes, as the cockpit and the
  /// `entrypoints` action both see them. Through the core for the same reason
  /// a control only the panel had would be one an agent could not see.
  List<RunKnobEntry> get _offeredKnobs {
    var choice = _entry;
    return choice == null
        ? const []
        : _core.knobEntriesOf(choice.package, choice.entry);
  }

  /// Why Start is off, when a knob is the reason.
  ///
  /// Asked of the core rather than worked out from [_offeredKnobs], so the
  /// button and the `launch` it calls cannot disagree: a form that let this be
  /// pressed would spend a build finding out what the same rule already knows.
  String? get _knobsProblem {
    var choice = _entry;
    return choice == null
        ? null
        : _core.requiredKnobsProblem(choice.package, choice.entry, _knobs);
  }

  @override
  Widget build(BuildContext context) {
    _prime();
    var entries = _entries;
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.play_circle_outline,
        title: 'No entry points',
        message:
            'Declare them in tool/flutterware.dart, or put a main() in '
            'the package’s lib/.',
      );
    }
    var allowed = _entry == null
        ? _core.devices
        : _core.devicesFor(_entry!.entry);
    var device = allowed.where((d) => d.id == _device).firstOrNull;
    // Read once for the button and the sentence beside it: two readings could
    // grey out Start and then explain nothing.
    var blocked = _knobsProblem;
    // A column, not the window. Fields stretched across a desktop panel put
    // the label and the caret a hand's width apart, and the form is a short
    // sequence of decisions rather than a table.
    // The scroller is the whole pane; the cap sits inside it. The other way
    // round — a ListView *inside* the 560 cap — parks the scroll gutter 560px
    // from the left, which on a wide window reads as a divider down the middle
    // of the page rather than as the edge of a list.
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New run', style: context.type.heading),
                const Gap(FwSpacing.lg),
                _Field(
                  label: 'Entry point',
                  child: _EntrypointPicker(
                    entries: entries,
                    selected: _entry,
                    onChanged: (choice) => setState(() {
                      _entry = choice;
                      _rebuildKnobs(const {});
                      _resetFlavor();
                      // Everything below is downstream, and the device most
                      // visibly so: switching to a mobile-only entry point while
                      // this Mac is selected has to move off it, not leave a
                      // selection the Start button would refuse.
                      _device = _pickDevice(preferred: _device);
                    }),
                  ),
                ),
                const Gap(FwSpacing.lg),
                _Field(
                  label: 'Device',
                  hint: _restriction,
                  child: _DevicePicker(
                    devices: allowed,
                    selected: _device,
                    restricted: _entry?.entry.platforms.isNotEmpty ?? false,
                    onChanged: (id) => setState(() {
                      _device = id;
                      // The declared flavor can differ per device; a value the
                      // user typed over it stays theirs.
                      if (!_overridingFlavor) _resetFlavor();
                    }),
                  ),
                ),
                // Always present, not only when something declared one: whether
                // this project has flavors is not something the cockpit knows, and
                // a flavoured project cannot be launched at all without the right
                // word here.
                const Gap(FwSpacing.lg),
                _Field(
                  label: 'Flavor',
                  hint: _overridingFlavor
                      ? 'just this run; empty passes no --flavor at all'
                      : null,
                  child: _FlavorField(
                    declared: _declaredFlavor,
                    vocabulary: _entry == null
                        ? null
                        : _core.flavorVocabularyFor(_entry!.package, _device),
                    controller: _flavor,
                    overriding: _overridingFlavor,
                    onOverride: () => setState(() => _overridingFlavor = true),
                    onRevert: () => setState(_resetFlavor),
                    onPicked: (choice) => setState(() => _flavor.text = choice),
                  ),
                ),
                if (_offeredKnobs.isNotEmpty) ...[
                  const Gap(FwSpacing.lg),
                  _Field(
                    label: 'Knobs',
                    hint: 'passed to main — changing one is a hot restart',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var knob in _offeredKnobs) ...[
                          KnobField(
                            knob: knob,
                            value: _knobs[knob.name],
                            interfaceOf: _core.hostInterfaceOf,
                            onChanged: (value) => setState(() {
                              if (value == null) {
                                _knobs.remove(knob.name);
                              } else {
                                _knobs[knob.name] = value;
                              }
                            }),
                          ),
                          const Gap(FwSpacing.md),
                        ],
                      ],
                    ),
                  ),
                ],
                const Gap(FwSpacing.lg),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _launching || device == null || blocked != null
                          ? null
                          : _start,
                      child: Text(_launching ? 'Starting…' : 'Start'),
                    ),
                    const Gap(FwSpacing.md),
                    // Said before the click, not explained after it: every wireless
                    // launch in the spike stalled on an OS dialog while the tool
                    // reported only `Installing and launching…`.
                    if (blocked case var reason?)
                      Flexible(
                        child: Text(
                          reason,
                          style: context.type.caption.copyWith(
                            color: context.colors.amber,
                          ),
                        ),
                      )
                    else if (device != null && device.isWireless)
                      Flexible(
                        child: Text(
                          'wireless — expect a slow install, and a permission prompt '
                          'on this Mac',
                          style: context.type.caption.copyWith(
                            color: context.colors.amber,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_error case var error?) ...[
                  const Gap(FwSpacing.md),
                  Text(
                    error,
                    style: context.type.caption.copyWith(
                      color: context.colors.red,
                    ),
                  ),
                ],
                // The desk also lives in the shell's chrome, where it can jump
                // you to the worktree holding a busy device — but that copy can
                // only read, so this is the one that boots anything.
                //
                // **Ungated.** It used to appear only while this worktree had
                // no runs, on the reasoning that a busy desk is what an idle
                // worktree wants to know about. What that actually did was make
                // booting an emulator impossible for anyone with an app
                // already running: an unbooted AVD is not a device, so it is
                // not in the picker above, and this was the only control in the
                // GUI that could start one. One run and the second device was
                // unreachable.
                const Gap(FwSpacing.xl),
                Divider(height: 1, color: context.colors.line),
                const Gap(FwSpacing.lg),
                _Desk(
                  // Named so a test can say *this Mac is on the desk and
                  // nowhere else on this page*, which is the claim about the
                  // picker's platform filter. The desk lists the whole machine
                  // by design, so a bare `findsNothing` cannot make it.
                  key: deskKey,
                  core: _core,
                  canRun: (device) =>
                      device.isConnected &&
                      device.id != _device &&
                      allowed.any((offered) => offered.id == device.id),
                  onPickDevice: (id) => setState(() {
                    _device = id;
                    // Same as choosing it in the picker, because it is the same
                    // choice: a declared flavor can differ per device, and a
                    // value the user typed over it stays theirs.
                    if (!_overridingFlavor) _resetFlavor();
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// What the fields above say, in the shape a launch takes them.
  ///
  /// One reading rather than one per button. The matrix launches the same app
  /// Start does, and it read the *declared* flavor and no knobs while Start
  /// read the form — so a flavor typed into the field, or a knob the entry
  /// point needs, was honoured by one button and silently dropped by the
  /// other.
  ({String? flavor, Map<String, String> knobs}) get _choices => (
    flavor: _flavor.text.trim().isEmpty ? null : _flavor.text.trim(),
    knobs: {..._knobs},
  );

  Future<void> _start() async {
    var choice = _entry;
    var device = _device;
    if (choice == null || device == null) return;
    var (:flavor, :knobs) = _choices;
    setState(() {
      _launching = true;
      _error = null;
    });
    try {
      var handle = await _core.launch(
        device: device,
        package: choice.package,
        entry: choice.entry,
        flavor: flavor,
        knobs: knobs,
      );
      _core.lastLaunch = (
        device: device,
        package: choice.package,
        entrypoint: choice.entry.path,
        flavor: flavor,
        knobs: knobs,
      );
      widget.onLaunched(handle);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not launch: $e');
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({
    required this.devices,
    required this.selected,
    required this.onChanged,
    this.restricted = false,
  });

  final List<DaemonDevice> devices;
  final String? selected;
  final ValueChanged<String> onChanged;

  /// Whether [devices] is the desk filtered by an entry point's declaration.
  ///
  /// Only the empty state needs it, and it needs it badly: "starting a flutter
  /// daemon takes a few seconds" is wrong for a desk that is full of machines
  /// this entry point said it cannot use.
  final bool restricted;

  @override
  Widget build(BuildContext context) => FwPicker<String>(
    choices: [
      for (var device in devices)
        FwChoice(
          value: device.id,
          label: device.displayName,
          detail: _detail(device),
          // The same green the rail uses for a live run. A phone that went to
          // sleep is still listed and is not launchable, and the row should say
          // so before the click rather than the build after it.
          dotColor: device.isConnected
              ? context.colors.grn
              : context.colors.mut3,
          enabled: device.isConnected,
        ),
    ],
    selected: selected,
    onChanged: onChanged,
    empty: restricted
        ? 'Nothing connected that this entry point can run on. Boot one from '
              'the desk below, or widen its platforms in tool/flutterware.dart.'
        : 'No devices yet. Starting a flutter daemon takes a few seconds.',
  );

  static String _detail(DaemonDevice device) => [
    ?device.platformType,
    ?device.sdk,
    if (device.kind == MachineKind.virtual) 'simulator',
    if (device.isWireless) 'wireless',
    if (!device.isConnected) 'not connected',
  ].join(' · ');
}

/// A picker rather than a row of buttons.
///
/// Four to ten entry points as buttons is a wall; as a picker it is a line.
/// The description is what makes it usable: `Kiosk` and `Onboarding` cannot be
/// told apart by their file names.
class _EntrypointPicker extends StatelessWidget {
  const _EntrypointPicker({
    required this.entries,
    required this.selected,
    required this.onChanged,
  });

  final List<({String package, EntrypointRef entry})> entries;
  final ({String package, EntrypointRef entry})? selected;
  final ValueChanged<({String package, EntrypointRef entry})> onChanged;

  @override
  Widget build(BuildContext context) => FwPicker<String>(
    choices: [
      for (var choice in entries)
        FwChoice(
          value: _idOf(choice),
          label: choice.entry.name,
          // The description when the config wrote one, the path when it did
          // not. Never both — the path is what a description exists to replace.
          detail: choice.entry.description ?? choice.entry.path,
        ),
    ],
    selected: selected == null ? null : _idOf(selected!),
    onChanged: (id) {
      for (var choice in entries) {
        if (_idOf(choice) == id) {
          onChanged(choice);
          return;
        }
      }
    },
    empty: 'No entry points.',
  );

  static String _idOf(({String package, EntrypointRef entry}) choice) =>
      '${choice.package}|${choice.entry.path}';
}

/// Names the desk for a test that has to tell it apart from the picker above
/// it. See where it is passed.
@visibleForTesting
const deskKey = ValueKey('run.desk');

/// What is on this machine, and who has it.
///
/// The desk also lives beside the worktree tabs, because a busy device should
/// take you to the worktree holding it and only the shell can switch worktrees.
/// **This is the copy that can act**: the chrome has no `RunCore` and starts no
/// daemon, so booting, refreshing and launching are here.
class _Desk extends StatefulWidget {
  const _Desk({
    super.key,
    required this.core,
    required this.canRun,
    required this.onPickDevice,
  });

  final RunCore core;

  /// Whether the form above would accept this device: connected, not already
  /// the one chosen, and among what the entry point declares it runs on.
  ///
  /// Held by another run is deliberately not a reason to withhold the offer —
  /// a phone can carry two apps, and the picker above does not withhold it
  /// either. A desk that refused what the field beside it accepts would be the
  /// two disagreeing about the same launch.
  final bool Function(DaemonDevice device) canRun;

  /// Where **Run here** goes: the form above, not a route.
  ///
  /// A free device is an answer to the Device field, so pressing it fills that
  /// field rather than navigating — the entry point, the flavor and the knobs
  /// are already chosen up there, and a jump would ask for them again.
  final ValueChanged<String> onPickDevice;

  @override
  State<_Desk> createState() => _DeskState();
}

class _DeskState extends State<_Desk> {
  /// Which emulator is being booted, so its row can show it and a second press
  /// cannot start a second boot of one machine.
  final _booting = <String>{};

  var _refreshing = false;

  RunCore get core => widget.core;

  @override
  void initState() {
    super.initState();
    // A second round trip, asked for only when the desk is actually on screen.
    unawaited(core.loadEmulators());
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await core.refreshDesk();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read the devices: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _boot(DaemonEmulator emulator) async {
    setState(() => _booting.add(emulator.id));
    try {
      await core.bootEmulator(emulator.id);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not boot ${emulator.displayName}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _booting.remove(emulator.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // Only the ones not already up. `isEmulatorBooted` answers null for the
    // daemon's single iOS entry, which is a door to the Simulator rather than a
    // machine — that row stays, because opening the Simulator is useful whether
    // or not something is already in it.
    var offline = [
      for (var emulator in core.emulators)
        if (isEmulatorBooted(emulator, core.devices) != true) emulator,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('On this machine', style: context.type.fieldLabel),
            const Gap(FwSpacing.sm),
            Text(
              _refreshing
                  ? 'reading…'
                  : core.isLive
                  ? 'live'
                  : 'cached',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
            const Spacer(),
            _DeskLink(
              label: 'Refresh',
              icon: Icons.refresh,
              onTap: _refreshing ? null : _refresh,
            ),
          ],
        ),
        const Gap(FwSpacing.xs),
        for (var device in core.devices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(_iconFor(device), size: FwIconSize.sm, color: colors.mut2),
                const Gap(FwSpacing.sm),
                Flexible(
                  flex: 0,
                  child: Text(
                    device.displayName,
                    style: context.type.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Gap(FwSpacing.sm),
                // `Expanded` rather than `Flexible` beside a `Spacer`: two
                // flex children share what is left evenly, so a long status
                // would ellipsise at half the row with the other half empty.
                Expanded(
                  child: Text(
                    _status(device, core),
                    style: context.type.caption.copyWith(color: colors.mut2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // **Only where it would work.** The field this fills is the
                // form's, and the form only offers what the chosen entry point
                // declares it runs on — so a row offering to run a
                // desktop-only entry point on a phone would be offering the
                // Start button's own refusal.
                if (widget.canRun(device))
                  _DeskLink(
                    label: 'Run here',
                    onTap: () => widget.onPickDevice(device.id),
                  ),
              ],
            ),
          ),
        for (var emulator in offline)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(
                  Icons.phone_iphone_outlined,
                  size: FwIconSize.sm,
                  color: colors.mut3,
                ),
                const Gap(FwSpacing.sm),
                Flexible(
                  flex: 0,
                  child: Text(
                    emulator.displayName,
                    style: context.type.bodySmall.copyWith(color: colors.mut2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Gap(FwSpacing.sm),
                Expanded(
                  child: Text(
                    'offline',
                    style: context.type.caption.copyWith(color: colors.mut2),
                  ),
                ),
                if (_booting.contains(emulator.id))
                  Text(
                    'starting…',
                    style: context.type.caption.copyWith(color: colors.mut2),
                  )
                else
                  _DeskLink(
                    // The iOS row opens the Simulator; an AVD row boots one
                    // machine. Different verbs because they are different acts.
                    label: emulator.platformType == 'ios' ? 'open' : 'boot',
                    onTap: () => _boot(emulator),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// The three kinds, said in their own words — a host is never `free`,
  /// because it was never anybody's to take.
  static String _status(DaemonDevice device, RunCore core) {
    var holders = [
      for (var handle in core.handles)
        if (handle.device == device.id) handle,
    ];
    if (!device.isConnected) return 'not connected';
    if (holders.isEmpty) {
      return device.kind == MachineKind.host ? 'not running' : 'free';
    }
    var first = holders.first;
    return device.kind == MachineKind.host
        ? 'running ${first.runLabel}'
        : '${first.runLabel} · ${first.worktreeName}';
  }

  static IconData _iconFor(DaemonDevice device) => switch (device.kind) {
    MachineKind.host =>
      device.platformType == 'web'
          ? Icons.language_outlined
          : Icons.desktop_windows_outlined,
    MachineKind.virtual => Icons.phone_iphone_outlined,
    MachineKind.physical => Icons.smartphone_outlined,
  };
}

/// The desk's one control shape: a word at the row's right edge.
///
/// A word rather than a button because a desk row is a fact with an offer on
/// the end of it, and five bordered buttons down the right of a list would
/// read as the list being a form. Disabled goes muted rather than vanishing —
/// a Refresh that disappears while it refreshes is a control you cannot find
/// twice.
class _DeskLink extends StatelessWidget {
  const _DeskLink({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = onTap == null ? colors.mut3 : colors.accent;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case var icon?) ...[
              Icon(icon, size: FwIconSize.xs, color: color),
              const Gap(FwSpacing.xs),
            ],
            Text(label, style: context.type.caption.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// The `--flavor`: a line of text until it needs changing.
///
/// A text box was the wrong shape for a field that is right before you look at
/// it. The project has almost always said which flavor this entry point builds
/// with — in `Entrypoint(flavor:)`, or in its pubspec's `default-flavor` — so
/// the ordinary job here is *reading* one word and moving on, and an empty box
/// beside a declared value invites retyping it.
///
/// Overriding stays one click away, because the case that needs it is real:
/// running the one entry point under a second flavor without declaring it
/// twice. Where the package declares its flavors ([vocabulary]), overriding is
/// picking off that list rather than typing — the launch would refuse an
/// unlisted word anyway, and a picker shows that before the attempt. A platform
/// declared flavorless collapses the field to that one fact.
class _FlavorField extends StatelessWidget {
  const _FlavorField({
    required this.declared,
    required this.vocabulary,
    required this.controller,
    required this.overriding,
    required this.onOverride,
    required this.onRevert,
    required this.onPicked,
  });

  final ({String? flavor, FlavorSource source}) declared;

  /// The declared flavors for the selected device's platform — null where the
  /// package declares nothing, empty where it declares "none here".
  final List<String>? vocabulary;

  final TextEditingController controller;
  final bool overriding;
  final VoidCallback onOverride;
  final VoidCallback onRevert;

  /// A pick from the vocabulary — the dropdown writes through this rather
  /// than into [controller] directly so the page can rebuild around it.
  final void Function(String) onPicked;

  @override
  Widget build(BuildContext context) {
    if (vocabulary?.isEmpty == true) {
      // Nothing to read, nothing to override: the declaration says this
      // platform has no flavors, and the launch drops the flag the way web
      // does. An Override button here could only produce a refused launch.
      return Text(
        'none — the platform declares no flavors',
        style: context.type.caption.copyWith(color: context.colors.mut3),
      );
    }
    if (overriding) {
      var options = vocabulary;
      return Row(
        children: [
          // Capped to a knob value's width, so this is the same control as a
          // knob's — a flavor is one word, and 500px of box for `dev` reads
          // as a mistake.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: KnobField.controlWidth,
              ),
              // The declared list where there is one — same control as an
              // enum knob's, and only values the list actually holds: a picker
              // shows `Choose…` for a value the list does not hold rather than
              // pretending the script's computed flavor is one of them.
              child: options == null
                  ? TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'dev, staging…',
                      ),
                    )
                  : FwPicker<String>(
                      choices: [
                        for (var option in options)
                          FwChoice(value: option, label: option),
                      ],
                      selected: options.contains(controller.text)
                          ? controller.text
                          : null,
                      onChanged: onPicked,
                    ),
            ),
          ),
          const Gap(FwSpacing.xs),
          TextButton(
            onPressed: onRevert,
            child: Text(
              declared.flavor == null ? 'Clear' : 'Use ${declared.flavor}',
              style: context.type.caption,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(
          declared.flavor ?? 'none',
          style: declared.flavor == null
              ? context.type.bodySmall.copyWith(color: context.colors.mut3)
              : context.type.bodySmall,
        ),
        const Gap(FwSpacing.sm),
        Flexible(
          child: Text(switch (declared.source) {
            FlavorSource.entrypoint => 'from the entry point',
            FlavorSource.pubspec => 'from the pubspec’s default-flavor',
            // Not "the project has none": a project can have flavors and
            // simply not have written this down, and that is exactly the
            // case where the build is about to fail for a reason the
            // cockpit could not have known.
            FlavorSource.none => 'nothing declares one — none is passed',
          }, style: context.type.caption.copyWith(color: context.colors.mut3)),
        ),
        const Gap(FwSpacing.xs),
        TextButton(
          onPressed: onOverride,
          child: Text('Override', style: context.type.caption),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.hint});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(label, style: context.type.fieldLabel),
          if (hint != null) ...[
            const Gap(FwSpacing.sm),
            Flexible(
              child: Text(
                hint!,
                style: context.type.caption.copyWith(
                  color: context.colors.mut3,
                ),
              ),
            ),
          ],
        ],
      ),
      const Gap(FwSpacing.xs),
      child,
    ],
  );
}

/// Where a run's page goes when the run never started.
///
/// Left-aligned, monospaced and scrollable rather than the centred one-liner
/// [_Failed] uses, because what goes here is a build failure: a fault, the file
/// it is in, and often the numbered steps that fix it. Centring that turns
/// instructions into a shrug.
/// A launch that never came up: what went wrong, and the log it went wrong in.
///
/// The reason on top and the whole log underneath, which is the shape the
/// building state already has — and for the same argument, applied to the state
/// that needs it more. This page used to end at the reason: the extracted block
/// of trailing lines, and then the log's *path*, printed as selectable text for
/// somebody to carry to a terminal. A build failure is the one moment anybody
/// wants to scroll the whole thing, and it was the one page that would not let
/// them.
///
/// The block stays, capped, above the log rather than instead of it. It is the
/// tool's own account of the fault — the head of the trailing block, not its
/// tail, because a tool states the fault first and summarises last — and
/// nothing in it is lost by the cap, since the same lines are in the pane
/// below with an `Errors` filter over them.
class _FailedRunPage extends StatelessWidget {
  const _FailedRunPage({
    required this.core,
    required this.failure,
    required this.onDismiss,
  });

  final RunCore core;
  final RunFailure failure;
  final VoidCallback onDismiss;

  /// Enough for the fault and a couple of lines of context. Past that this is
  /// a log, and there is one of those directly below.
  static const _reasonHeight = 168.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(FwSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: FwIconSize.md, color: colors.red),
              const Gap(FwSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failure.headline ?? 'The run did not start',
                      style: context.type.bodyStrong.copyWith(
                        color: colors.red,
                      ),
                    ),
                    const Gap(FwSpacing.xs),
                    Text(
                      '${failure.runLabel} on ${failure.deviceLabel} — '
                      'never started, so nothing is holding the device.',
                      style: context.type.bodyMuted,
                    ),
                  ],
                ),
              ),
              const Gap(FwSpacing.sm),
              TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            ],
          ),
        ),
        const Divider(height: 1),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _reasonHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(FwSpacing.md),
            child: SelectableText(
              failure.message,
              style: context.type.mono.copyWith(color: colors.mut),
            ),
          ),
        ),
        const Divider(height: 1),
        // The path is no longer printed here. It is in the log pane's own menu,
        // beside the lines it names — which is where somebody who wants to open
        // it in a terminal is already looking.
        Expanded(
          child: LogsTab.ofFailure(
            key: ValueKey(failure.key),
            core: core,
            logPath: failure.logPath,
            subject: failure.key,
          ),
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: SelectableText(
        message,
        textAlign: TextAlign.center,
        style: context.type.caption.copyWith(color: context.colors.red),
      ),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: context.type.bodyMuted,
      ),
    ),
  );
}

/// A control on the run's header — icon and word, not a bare glyph.
class _Action extends StatelessWidget {
  const _Action(
    this.label,
    this.icon, {
    required this.enabled,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final bool danger;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var fg = !enabled
        ? colors.mut3
        : danger
        ? colors.red
        : colors.accent;
    return Padding(
      padding: const EdgeInsets.only(left: FwSpacing.xs),
      child: Tappable(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.sm,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            border: Border.all(color: colors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: FwIconSize.sm, color: fg),
              const Gap(FwSpacing.xs),
              Text(label, style: context.type.bodySmall.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(label, style: context.type.micro.copyWith(color: colors.mut)),
    );
  }
}
