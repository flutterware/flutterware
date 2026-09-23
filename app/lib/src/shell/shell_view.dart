import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';

import '../address/address_scope.dart';
import '../changes/changes_screen.dart';
import '../comparison/ui/comparison_tabs.dart';
import '../capture/capture_mode.dart';
import '../capture/capture_request.dart';
import '../plugins/native_plugin.dart';
import '../ui/aside.dart';
import '../ui/badged_icon.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import '../worktrees/explorer_screen.dart';
import '../plugins/plugin_core.dart';
import '../teardown/dialog.dart';
import '../teardown/plan.dart';
import '../worktrees/facts.dart';
import 'address_bar.dart';
import 'config_load.dart';
import 'config_screen.dart';
import 'device_desk.dart';
import '../utils/fitted_app.dart';
import '../utils/hot_reload.dart';
import '../utils/value_stream_builder.dart';
import 'drive_navigator.dart';
import 'shell_controller.dart';
import 'shell_search.dart';
import 'sidebar_row.dart';
import 'worktree.dart';
import 'worktree_filter.dart';
import 'worktree_home.dart';

/// The transient "what the last reload did" line in the band.
const configLoadLineKey = Key('config-load-line');

/// The sticky config-failure banner under the band.
const configErrorBannerKey = Key('config-error-banner');

/// The sticky "this is not where you launched" banner under the band.
const launchFallbackBannerKey = Key('launch-fallback-banner');

/// The band button that opens the config screen.
const configButtonKey = Key('config-button');

/// Everything in the band that has to clear the traffic lights. Keyed so a test
/// can measure where it starts.
const bandContentKey = Key('shell.band-content');

/// The box the macOS traffic lights occupy, **in real window pixels**; band
/// content insets past it.
///
/// Real pixels, not the band's own, because the buttons belong to the window
/// rather than to the app: they are the same size at every scale [FittedApp]
/// applies. Divided by [AppScale.of] wherever it is used — reserving 78 of the
/// app's pixels while the app is at 0.7 reserves 55 of the window's, and the
/// first tab draws under the close button.
const _trafficLightInset = 78.0;
const _trafficLightHeight = 28.0;
const _bandHeight = 40.0;

/// How far tabs sit below the top of the band. Everything else in the band
/// aligns to the box this leaves, not to the band itself.
const _tabInset = 6.0;

/// How much of a tab a worktree's name may claim before it is ellipsised.
const _tabLabelMaxWidth = 180.0;

/// How wide the strip you can grab to resize the rail is. Wider than the seam
/// it sits on, because a 1px target is a 1px target.
const _railHandleWidth = 8.0;

/// The chevron that shows and hides the rail, and how far into the pane the
/// strip that offers it reaches once the rail is gone.
const _railToggleSize = 20.0;
const _railPeekWidth = 20.0;

/// Whether the aside gutter is taking room in the row this frame.
///
/// The rail's peek strip stands down when it is: the gutter's own button
/// restores both panes, and two controls a few pixels apart both offering to
/// give something back is the kind of clutter a way out cannot afford.
bool _gutterInFlow(ShellController shell) =>
    !shell.inWorktreesSpace && shell.aside.present && !shell.aside.visible;

/// The smallest window this layout lays out for: the pane's floor, plus the
/// rail the user has asked to see.
///
/// A sum, not a constant. The pane is what has a minimum — the dependencies
/// table is the thing that stops fitting — and the rail is chrome that happens
/// to sit next to it. Charging for a rail either way is what made ⌘B stop
/// short: it gave the panel 232px of room and then went on scaling the window
/// as if it had not.
///
/// [railWidth] follows the sidebar *preference*, not whether a rail is drawn
/// this frame. The worktrees space drops the rail from the layout, but the
/// minimum holding still through that is what keeps navigation from zooming
/// the window; the freed width shows up as extra room for the explorer
/// instead.
Size shellMinimumSize({required double railWidth}) =>
    Size(shellPaneMinimumSize.width + railWidth, shellPaneMinimumSize.height);

class ShellApp extends StatelessWidget {
  const ShellApp(
    this.shell, {
    super.key,
    this.captureKey,
    this.framing = const CaptureFraming(),
  });

  final ShellController shell;

  /// Marks what a window capture photographs, when one is going to happen.
  ///
  /// On `builder` rather than around [ShellView], so the boundary sits *above*
  /// the navigator and its overlay: a dialog or a menu is part of the window
  /// and a picture that silently omitted it would be wrong in a way nobody
  /// notices until the screenshot is in the README.
  final GlobalKey? captureKey;

  /// Size, density and theme for a capture. Default is "whatever this machine
  /// is", which is right for a human and wrong for anything committed.
  final CaptureFraming framing;

  @override
  Widget build(BuildContext context) {
    // Above the `MaterialApp`, so the whole window scales together and the
    // corrected MediaQuery is the one `WidgetsApp` inherits — it never
    // introduces its own. A capture sets its size *below* this, inside
    // `builder`, which is what we want: a screenshot asked for exact pixels
    // should get them rather than the window's scale factor.
    //
    // The shell is listened to *here* rather than only inside [ShellView],
    // because the minimum now depends on whether the rail is drawn. The app
    // goes through as `child`, so what a ⌘B rebuilds is this one widget and its
    // `Size` — not the `MaterialApp`, its navigator, and every route in it.
    return ListenableBuilder(
      listenable: shell,
      builder: (context, child) => FittedApp(
        // By preference, not by presence: the worktrees space takes the rail
        // out of the flow, but charging for that here would rescale the whole
        // window on every navigation across its boundary. Only ⌘B — the user
        // asking for room — may move the minimum.
        minimumSize: shellMinimumSize(
          railWidth: shell.sidebarVisible ? shell.sidebarWidth : 0,
        ),
        // A drag is its own animation; see [ShellController.sidebarResizing].
        duration: shell.sidebarResizing
            ? Duration.zero
            : const Duration(milliseconds: 150),
        child: child!,
      ),
      child: MaterialApp(
        title: 'Flutterware',
        theme: appTheme,
        // Follows the OS. The shell reads every colour through `context.colors`,
        // so both builds come from the same widgets — but a plugin panel that
        // still hardcodes its own will stay light, and look it.
        darkTheme: appDarkTheme,
        themeMode: framing.themeMode ?? ThemeMode.system,
        debugShowCheckedModeBanner: false,
        builder: captureKey == null
            ? null
            : (context, child) => framing.frame(
                context,
                CaptureMode(
                  child: RepaintBoundary(key: captureKey, child: child),
                ),
              ),
        home: DriveNavigatorScope(shell: shell, child: ShellView(shell)),
      ),
    );
  }
}

class ShellView extends StatelessWidget {
  const ShellView(this.shell, {super.key});

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // The aside as well as the shell: a fold taken in the panel below is
      // what tells the rail's peek strip to stand down, and the strip is up
      // here.
      animation: Listenable.merge([shell, shell.aside]),
      builder: (context, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
              shell.toggleSidebar,
          const SingleActivator(LogicalKeyboardKey.keyB, control: true):
              shell.toggleSidebar,
          // ⌘B, more so: the rail *and* the panel's own list. Not bound to
          // Escape as well — see the note on the one Escape binding below;
          // the gutter is the discoverable way out and this is the fast one.
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true, alt: true):
              shell.aside.toggleExpanded,
          const SingleActivator(
            LogicalKeyboardKey.keyB,
            control: true,
            alt: true,
          ): shell.aside.toggleExpanded,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              unawaited(showShellSearch(context, shell)),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              unawaited(showShellSearch(context, shell)),
          const SingleActivator(
            LogicalKeyboardKey.keyD,
            meta: true,
            shift: true,
          ): shell.selectChanges,
          const SingleActivator(
            LogicalKeyboardKey.keyD,
            control: true,
            shift: true,
          ): shell.selectChanges,
          // **Only out of the worktrees space, and only when there is somewhere
          // to go.** Escape is the most overloaded key in any window; binding it
          // to a general "back" here would steal it from every dialog and text
          // field under this widget. A changes screen for an unopened checkout
          // is the one place with no tab to click your way out of.
          if (shell.inWorktreesSpace && !shell.isExplorer)
            const SingleActivator(LogicalKeyboardKey.escape):
                shell.selectExplorer,
          // The same screen in the next checkout, and back. The bracket pair is
          // what every editor uses for cycling, and with two worktrees open it
          // is the A/B flick that makes a visual comparison possible at all.
          const SingleActivator(
            LogicalKeyboardKey.bracketRight,
            meta: true,
            shift: true,
          ): () =>
              shell.cycleWorktree(1),
          const SingleActivator(
            LogicalKeyboardKey.bracketLeft,
            meta: true,
            shift: true,
          ): () =>
              shell.cycleWorktree(-1),
          const SingleActivator(
            LogicalKeyboardKey.bracketRight,
            control: true,
            shift: true,
          ): () =>
              shell.cycleWorktree(1),
          const SingleActivator(
            LogicalKeyboardKey.bracketLeft,
            control: true,
            shift: true,
          ): () =>
              shell.cycleWorktree(-1),
        },
        // Key events dispatch from whatever holds primary focus and bubble to
        // its *ancestors*. With nothing focused that is the root scope, which
        // sits above `CallbackShortcuts` — so the bindings never see a key
        // until something inside happens to be focused. Taking focus on mount
        // puts the shell below them, which is what makes a shortcut work
        // without clicking the window first.
        child: Focus(
          autofocus: true,
          // The top of the address tree, wrapping the band as well as the
          // panel: the bar that displays the address is a consumer of it like
          // any other, and putting it outside would make it the one thing that
          // needs its own way of reading.
          child: AddressRoot(
            address: shell.addressListenable,
            onChanged: shell.go,
            child: Scaffold(
              body: Column(
                children: [
                  _Band(shell),
                  // Above the rail and the panel both, because it is a fact
                  // about the worktree rather than about whatever is mounted —
                  // and a config that failed no longer takes the panel down
                  // with it, so this is the only thing that would say so.
                  // Above the config banner, because it is the more
                  // fundamental complaint: that one is about the checkout you
                  // are looking at, this one says the checkout itself is not
                  // the one you asked for.
                  _LaunchFallbackBanner(shell),
                  _ConfigErrorBanner(shell),
                  Expanded(
                    child: Row(
                      children: [
                        // Derived rather than assigned: the rail lists *this
                        // worktree's* plugins, and nothing in the worktrees
                        // space has any — the explorer is about every checkout,
                        // and a changes screen for a checkout nobody opened has
                        // no session to list plugins from. Writing
                        // `sidebarVisible = false` on arrival would clobber a
                        // window preference the user set, and not give it back.
                        if (shell.railInFlow) _Sidebar(shell),
                        Expanded(
                          // The peek strip is over the panel rather than beside
                          // it: a column in the flow would take width from
                          // every pane for the sake of a control that is only
                          // wanted when the rail is gone. Always mounted, so
                          // showing and hiding the rail does not change the
                          // shape of the tree the panel is in.
                          child: Stack(
                            children: [
                              Positioned.fill(
                                // Above the panel and below the shell, which
                                // is the only place that can see both halves
                                // of the fold: the rail is the shell's and the
                                // list is the plugin's.
                                child: AsideScope(
                                  aside: shell.aside,
                                  child: _Panel(shell),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                child: _RailPeek(shell),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  AddressBar(shell),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The reclaimed titlebar: a tab per open worktree, then the switcher.
class _Band extends StatelessWidget {
  const _Band(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;

    // What the traffic lights cost *this* band, at whatever the app is scaled
    // to. Both are the identity at 1.0, so a window that is not scaling gets
    // exactly the layout it always had.
    var scale = AppScale.of(context);
    var lightsInset = _trafficLightInset / scale;
    // The band is tall enough for them on its own until about 0.7; below that
    // it grows downwards rather than letting the tabs rise into the buttons.
    // The extra is padding above the content, so a tab keeps the height the
    // rest of the band is measured against.
    var lightsDrop = max(0.0, _trafficLightHeight / scale - _bandHeight);

    return Container(
      height: _bandHeight + lightsDrop,
      color: colors.panel,
      child: Stack(
        children: [
          // **The seam, drawn behind the tabs rather than under them.**
          //
          // It used to be the band's own bottom border, which painted across
          // the full width — including beneath the selected tab, so the tab
          // that is *showing* the panel below had a line cutting it off from
          // it. Here a selected tab's opaque background covers the segment it
          // sits on, and the two read as one surface; an unselected tab is
          // transparent and lets the seam through, which is what makes the
          // selected one legible.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(height: 1, color: colors.line),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(left: lightsInset, top: lightsDrop),
              child: _bandContent(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bandContent(BuildContext context) {
    return Row(
      key: bandContentKey,
      children: [
        // The rail's own toggle used to be here, first thing after the traffic
        // lights. It is on the rail's seam now — see [_RailToggle] — because a
        // control in the chrome that acts on the pane below it reads as chrome
        // and gets scanned past. What is left here is what is genuinely about
        // the window: which project, and which checkouts are open.
        _ProjectFaceChip(shell),
        _ExplorerTab(shell),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var worktree in shell.openWorktrees)
                _WorktreeTab(shell, worktree),
              _SwitcherButton(shell),
            ],
          ),
        ),
        // The desk: devices, occupancy, and the jump to the worktree holding
        // a busy one. In the chrome because only the shell can switch
        // worktrees — the panel's copy of the desk can show who holds a
        // phone, but not take you there.
        DeskButton(shell),
        SearchTrigger(onTap: () => unawaited(showShellSearch(context, shell))),
        const Gap(FwSpacing.md),
        _ConfigLoadLine(shell),
        _ConfigButton(shell),
        const _HotReloadButtons(),
        const Gap(FwSpacing.md),
      ],
    );
  }
}

/// Shows and hides the plugin rail, from the edge the rail actually has.
///
/// Appears on hover — of the seam while the rail is there, of the strip where
/// the rail was once it is gone — so the resting state is a window with no
/// controls in it that are not doing anything. ⌘B does the same thing without
/// finding either.
class _RailToggle extends StatelessWidget {
  const _RailToggle(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var showing = shell.sidebarVisible;
    return Tooltip(
      message:
          '${showing ? 'Hide' : 'Show'} the sidebar '
          '(${defaultTargetPlatform == TargetPlatform.macOS ? '⌘B' : 'Ctrl+B'})',
      child: Tappable.builder(
        onTap: shell.toggleSidebar,
        builder: (context, hovered) => Container(
          width: _railToggleSize,
          height: _railToggleSize,
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          child: Icon(
            showing ? Icons.chevron_left : Icons.chevron_right,
            size: FwIconSize.sm,
            color: hovered ? colors.accent : colors.mut,
          ),
        ),
      ),
    );
  }
}

/// The selected worktree's config failure, until a load succeeds.
///
/// Not dismissible. It is a fact about a file on disk, so hiding it would
/// hide a real problem — and unlike before, there is no other symptom to notice:
/// the plugins built from the last config that loaded are all still running
/// behind it.
///
/// The shell is not where you started it.
///
/// Shown on the checkout that was opened in place of a launch directory no
/// worktree contains, and only on that one — switching tabs is a deliberate act
/// and nothing to warn about.
///
/// Not dismissible and not transient, unlike the reload line. Everything else
/// on screen is convincing: the tab is a real branch, the panels are real code,
/// and a `fw capture` minted from any of it looks exactly like the answer you
/// asked for. The only thing that makes it wrong is this sentence.
class _LaunchFallbackBanner extends StatelessWidget {
  const _LaunchFallbackBanner(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var fallback = shell.launchFallback;
    if (fallback == null || fallback.opened != shell.selected) {
      return const SizedBox.shrink();
    }

    return Container(
      key: launchFallbackBannerKey,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: colors.warning)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: FwIconSize.sm,
            color: colors.amber,
          ),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Text(
              'Not the checkout flutterware was started in — launched in '
              '${fallback.launchDirectory}, which no worktree contains.',
              style: context.type.caption.copyWith(color: colors.warningText),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Says one line and offers the screen. The compiler's own output lives on
/// `fw:///worktrees/<worktree>/config`, where the reload button and the
/// history of previous reloads are, and rendering it in two places would mean
/// maintaining it in two places.
class _ConfigErrorBanner extends StatelessWidget {
  const _ConfigErrorBanner(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var worktree = shell.selected;
    var error = worktree == null ? null : shell.errorFor(worktree);
    // Redundant while you are looking at the screen that explains it.
    if (error == null || shell.isConfigScreen) return const SizedBox.shrink();

    return Container(
      key: configErrorBannerKey,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.red.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: colors.red)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: FwIconSize.sm, color: colors.red),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Text(
              error.message.trimRight().split('\n').first,
              style: context.type.caption.copyWith(color: colors.red),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: shell.selectConfig,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Details',
              style: context.type.caption.copyWith(color: colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the last config load did, for a few seconds after it did it.
///
/// The `unchanged` case is the reason this exists. A reload that matched and
/// a reload that never happened are the same absence of feedback, and that
/// ambiguity is what makes reloading feel unreliable — so a load always says
/// something, even when the answer is "nothing moved". The duration rides along
/// so a drift from ~100ms to seconds is visible without anyone going looking.
///
/// Opening a worktree is deliberately silent: the tab appearing is already the
/// feedback, and announcing it would make every switch chatty.
class _ConfigLoadLine extends StatefulWidget {
  const _ConfigLoadLine(this.shell);

  final ShellController shell;

  @override
  State<_ConfigLoadLine> createState() => _ConfigLoadLineState();
}

class _ConfigLoadLineState extends State<_ConfigLoadLine> {
  static const _linger = Duration(seconds: 4);

  /// What is on screen, and what has already been said.
  ///
  /// Two fields for what looks like one thing. [_showing] goes back to null
  /// when the line fades, so deciding what to show from it meant every later
  /// notification — a plugin changing state, a dependency finishing a load, any
  /// save at all — found a `lastLoad` still recorded and nothing on screen, and
  /// put the same line back up for another four seconds. The band then reads as
  /// a config that re-runs on every unrelated edit, which is exactly the
  /// impression this whole surface exists to prevent. A load is announced once,
  /// keyed on the load itself.
  ConfigLoad? _showing;
  ConfigLoad? _announced;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.shell.addListener(_check);
  }

  @override
  void dispose() {
    widget.shell.removeListener(_check);
    _hide?.cancel();
    super.dispose();
  }

  void _check() {
    var worktree = widget.shell.selected;
    var load = worktree == null ? null : widget.shell.lastLoad(worktree);
    if (load == null ||
        identical(load, _announced) ||
        load.outcome == ConfigLoadOutcome.built) {
      return;
    }
    _announced = load;
    setState(() => _showing = load);
    _hide?.cancel();
    _hide = Timer(_linger, () {
      if (mounted) setState(() => _showing = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var load = _showing;
    return AnimatedOpacity(
      opacity: load == null ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: load == null
          ? const SizedBox.shrink()
          : Padding(
              key: configLoadLineKey,
              padding: const EdgeInsets.only(right: FwSpacing.sm),
              child: Text(
                '${load.summary} · ${load.duration.inMilliseconds}ms',
                style: context.type.caption.copyWith(
                  color: load.succeeded ? colors.mut : colors.red,
                ),
              ),
            ),
    );
  }
}

/// Opens `fw:///worktrees/<worktree>/config`.
///
/// This used to reload on click, which put the action in the chrome and its
/// result nowhere: a reload that rebuilt one plugin, or refused because a plugin
/// was busy, had no place to say so. Now the button is navigation and the Reload
/// button lives on the screen, next to the log of what previous reloads did.
///
/// It carries the config's state, because that is the one thing about this file
/// worth a permanent pixel in the band: a dot when the config is failing.
class _ConfigButton extends StatelessWidget {
  const _ConfigButton(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var worktree = shell.selected;
    var failing = worktree != null && shell.errorFor(worktree) != null;

    return Tooltip(
      message: failing
          ? 'This worktree’s config did not load'
          : 'Config resolved from tool/flutterware.dart',
      child: IconButton(
        key: configButtonKey,
        onPressed: worktree == null ? null : shell.selectConfig,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              Icons.tune,
              size: FwIconSize.md,
              color: shell.isConfigScreen ? colors.accent : colors.mut,
            ),
            if (failing)
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        disabledColor: colors.mut3,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Hot reload and hot restart of flutterware itself.
///
/// Only rendered when `flutter run` is driving this process — see [HotReload],
/// which is what registers the methods that make either possible. For anyone
/// who installed flutterware rather than building it, these never appear, and
/// that is correct rather than a degraded experience: there is no compiler
/// present to produce new code.
///
/// Distinct from [_ConfigButton] beside it, which opens the *worktree's config*
/// screen. That one is for using flutterware; this pair is for working on it.
class _HotReloadButtons extends StatefulWidget {
  const _HotReloadButtons();

  @override
  State<_HotReloadButtons> createState() => _HotReloadButtonsState();
}

class _HotReloadButtonsState extends State<_HotReloadButtons> {
  HotReload? _hot;

  @override
  void initState() {
    super.initState();
    // Connecting is a socket to ourselves and costs nothing when it fails,
    // which is the common case.
    unawaited(
      HotReload.connect().then((hot) {
        if (!mounted) {
          unawaited(hot?.dispose());
          return;
        }
        setState(() => _hot = hot);
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_hot?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var hot = _hot;
    if (hot == null) return const SizedBox.shrink();

    return ValueStreamBuilder<bool>(
      stream: hot.available,
      builder: (context, available, _) {
        if (!available) return const SizedBox.shrink();
        var colors = context.colors;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bandButton(
              colors: colors,
              icon: Icons.local_fire_department_outlined,
              tooltip: 'Hot reload flutterware',
              onPressed: hot.reload,
            ),
            if (hot.canRestart)
              _bandButton(
                colors: colors,
                icon: Icons.restart_alt,
                // Naming what it costs: this tears down the window drawing it.
                tooltip: 'Hot restart flutterware (the window will reappear)',
                onPressed: hot.restart,
              ),
          ],
        );
      },
    );
  }

  Widget _bandButton({
    required FwPalette colors,
    required IconData icon,
    required String tooltip,
    required Future<void> Function() onPressed,
  }) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: () => unawaited(onPressed()),
      icon: Icon(icon, size: FwIconSize.md, color: colors.mut),
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
    ),
  );
}

/// Finds the pinned explorer tab.
const explorerTabKey = ValueKey('tab:explorer');

/// The explorer, as a tab that is always open and cannot be closed.
///
/// A tab rather than a button in the right-hand cluster, and the badge is
/// why. The explorer's job is ambient — *N worktrees will not progress until
/// you do something* — and that number wants a permanent pixel. A pinned tab
/// carries it natively; a meta-cluster icon carries it badly and a menu item
/// cannot carry it at all.
///
/// The band therefore stops meaning "a tab per open worktree" and starts meaning
/// *a strip of open places, one of which is always open* — which is exactly what
/// a pinned tab means in a browser. No close button follows from that rather
/// than needing an excuse.
///
/// Not a house. `Icons.home_outlined` is the sidebar's "Overview" row —
/// *this worktree's* home — and one glyph meaning two different scopes in one
/// window is worse than an unfamiliar glyph meaning one.
class _ExplorerTab extends StatelessWidget {
  const _ExplorerTab(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) => _RebuildsWhen(
    // The badge is the one thing up here that moves on its own, so it is the
    // one thing that subscribes to the facts — and it is a count, so it
    // redraws when the count moves rather than when a probe lands.
    listenable: Listenable.merge([shell.worktreeFacts]),
    select: () => shell.worktreeFacts?.needsYou ?? 0,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    var colors = context.colors;
    // **Lit for the whole space, not only the list.** A changes screen for a
    // checkout nobody has opened is a page *in* the worktrees space — it has no
    // tab of its own, and leaving every tab dark would say the window is
    // nowhere. This is the pinned tab meaning what a pinned tab means in a
    // browser: the place, not one document in it.
    var selected = shell.inWorktreesSpace;
    var needsYou = shell.worktreeFacts?.needsYou ?? 0;
    var radius = Radius.circular(context.radii.radiusSmall);
    var edge = BorderSide(color: selected ? colors.line : Colors.transparent);

    return Tooltip(
      message: needsYou == 0
          ? 'Every checkout of this repo'
          : '$needsYou worktree${needsYou == 1 ? '' : 's'} waiting on you',
      child: Tappable(
        onTap: shell.selectExplorer,
        borderRadius: BorderRadius.only(topLeft: radius, topRight: radius),
        child: Container(
          key: explorerTabKey,
          height: _bandHeight - _tabInset,
          margin: const EdgeInsets.only(top: _tabInset, right: FwSpacing.xs),
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
          decoration: BoxDecoration(
            color: selected ? colors.bg : Colors.transparent,
            borderRadius: BorderRadius.only(topLeft: radius, topRight: radius),
            border: Border(top: edge, left: edge, right: edge),
          ),
          child: Center(
            child: BadgedIcon(
              Icons.account_tree_outlined,
              count: needsYou,
              size: FwIconSize.md,
              color: selected ? colors.accent : colors.mut,
            ),
          ),
        ),
      ),
    );
  }
}

/// The key a worktree's tab carries, so a test can point at the tab rather than
/// at a name the home screen also shows.
Key worktreeTabKey(Worktree worktree) => ValueKey('tab:${worktree.path}');

/// The open project's own launcher icon, in the window chrome.
///
/// Once per window rather than once per tab. Tabs are worktrees and a window holds
/// one repository's worktrees, so a chip on every tab would repeat the same
/// picture down the band. Here it says what this *window* is, which is the
/// question several identical windows raise.
///
/// Nothing when the project declares no identity — see [resolveProjectFace]. An
/// absent chip is the shell as it was, which is the right amount of noise for a
/// project that has not said anything. A project that *did* say something and
/// got the path wrong is a different case, and is reported on the worktree
/// instead of going quiet here.
class _ProjectFaceChip extends StatelessWidget {
  const _ProjectFaceChip(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var face = shell.selectedSession?.face;
    if (face == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: FwSpacing.xs),
      child: Tooltip(
        message: '${face.package} · ${face.icon}',
        child: ClipRRect(
          // The chip's own corner ratio, the same 0.225 the launcher icon uses.
          borderRadius: BorderRadius.circular(_faceChipSize * 0.225),
          child: Image.file(
            face.file,
            width: _faceChipSize,
            height: _faceChipSize,
            filterQuality: FilterQuality.medium,
            // A project icon that will not decode is not worth a red box in the
            // chrome; the window simply goes back to having no chip.
            errorBuilder: (context, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

const _faceChipSize = 20.0;

class _WorktreeTab extends StatelessWidget {
  _WorktreeTab(this.shell, this.worktree)
    : super(key: worktreeTabKey(worktree));

  final ShellController shell;
  final Worktree worktree;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var selected = shell.selected == worktree;
    var loading = shell.isLoading(worktree);
    var status = shell.sessionFor(worktree)?.status ?? Status.none;
    var radius = Radius.circular(context.radii.radiusSmall);
    // Always allocated, transparent when unselected: a border that appears on
    // selection changes the tab's size and shifts everything beside it.
    var edge = BorderSide(color: selected ? colors.line : Colors.transparent);

    return Tappable(
      onTap: () => shell.select(worktree),
      borderRadius: BorderRadius.only(topLeft: radius, topRight: radius),
      child: Container(
        height: _bandHeight - _tabInset,
        margin: const EdgeInsets.only(top: _tabInset, right: FwSpacing.xs),
        padding: const EdgeInsets.only(left: FwSpacing.lg, right: FwSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? colors.bg : Colors.transparent,
          borderRadius: BorderRadius.only(topLeft: radius, topRight: radius),
          border: Border(top: edge, left: edge, right: edge),
        ),
        child: Row(
          children: [
            // **Always allocated, empty when there is nothing to show** — the
            // same rule the border above follows, for the same reason and one
            // more. A glyph that arrives by *widening* the tab pushes the
            // branch name along and re-ellipsises it, so a status the tab
            // gains for a moment moves a whole line of text to announce
            // itself. And the two glyphs are different sizes, so a load that
            // ends in a status used to nudge the label a second time on the
            // way out. One box, both tenants, no motion either way.
            SizedBox.square(
              dimension: 9,
              child: Center(child: _tabGlyph(colors, loading, status)),
            ),
            const Gap(FwSpacing.sm),
            // Capped, or a branch called `feature/some-long-description` gives
            // itself a tab wide enough to push the switcher off screen. The
            // tooltip is where the whole name still lives.
            Tooltip(
              message: worktree.branch == null || worktree.title == null
                  ? worktree.displayName
                  : '${worktree.displayName}\n${worktree.branch}',
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _tabLabelMaxWidth),
                child: Text(
                  worktree.displayName,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: selected
                      ? context.type.bodyStrong
                      : context.type.bodyMuted,
                ),
              ),
            ),
            const Gap(FwSpacing.sm),
            _CloseButton(shell, worktree),
          ],
        ),
      ),
    );
  }
}

/// What sits in a tab's leading box: the loader while the worktree opens, then
/// its worst plugin status, then nothing.
Widget? _tabGlyph(FwPalette colors, bool loading, Status status) {
  if (loading) {
    return CircularProgressIndicator(strokeWidth: 1.5, color: colors.mut2);
  }
  if (status.isEmpty || status.tone == Tone.neutral) return null;
  return _Dot(toneColor(colors, status.tone));
}

/// Closing releases the worktree's plugins. A plugin that hard-blocks teardown
/// refuses, and the reasons are shown rather than the click doing nothing.
class _CloseButton extends StatelessWidget {
  const _CloseButton(this.shell, this.worktree);

  final ShellController shell;
  final Worktree worktree;

  @override
  Widget build(BuildContext context) {
    var session = shell.sessionFor(worktree);
    var blockers = [
      for (var guard in session?.guards ?? const <Guard>[])
        if (guard.level == GuardLevel.block) guard.reason,
    ];

    var colors = context.colors;
    return Tooltip(
      message: blockers.isEmpty ? 'Close worktree' : blockers.join('\n'),
      child: Tappable.builder(
        onTap: () {
          if (!shell.close(worktree)) _showBlocked(context, blockers);
        },
        builder: (context, hovered) => Icon(
          blockers.isEmpty ? Icons.close : Icons.lock_outline,
          size: FwIconSize.sm,
          color: blockers.isNotEmpty
              ? colors.amber
              : hovered
              ? colors.ink
              : colors.mut2,
        ),
      ),
    );
  }

  void _showBlocked(BuildContext context, List<String> reasons) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cannot close this worktree'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (var reason in reasons) Text('• $reason')],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// Lists every worktree git reports, split by whether it is open.
///
/// Opens on a filter field — the same one the address bar's switcher has, with
/// the same ↵-picks-the-first contract. Here the field sits at the *top*: this
/// menu grows down from the band, so the top edge is the one that stays put
/// while the list narrows below it.
class _SwitcherButton extends StatefulWidget {
  const _SwitcherButton(this.shell);

  final ShellController shell;

  @override
  State<_SwitcherButton> createState() => _SwitcherButtonState();
}

class _SwitcherButtonState extends State<_SwitcherButton> {
  final _menuController = MenuController();
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  var _query = '';

  ShellController get shell => widget.shell;

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  /// Opening the menu is the only moment this list is read, so it is also the
  /// only moment worth rescanning. Not awaited: the last known worktrees are
  /// shown immediately and git's answer folds in when it arrives.
  void _open() {
    _filter.clear();
    _query = '';
    _menuController.open();
    unawaited(shell.rescanWorktrees());
    // Once the menu has an overlay to focus into.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _filterFocus.requestFocus();
    });
  }

  /// Every name the row can be known by: the label it shows, the branch its
  /// caption may show, and the identity the address would use.
  List<(Worktree, FilterMatch?)> _filtered(List<Worktree> worktrees) {
    if (_query.trim().isEmpty) {
      return [for (var worktree in worktrees) (worktree, null)];
    }
    return [
      for (var worktree in worktrees)
        if (matchWorktreeFilter(_query, [
              worktree.displayName,
              worktree.branch,
              worktree.name,
            ])
            case var match?)
          (worktree, match),
    ];
  }

  /// The same move as tapping the first row still listed: selecting an open
  /// worktree, opening a closed one.
  void _pickFirst() {
    var first =
        _filtered(shell.openWorktrees).firstOrNull ??
        _filtered(shell.closedWorktrees).firstOrNull;
    if (first == null) return;
    _menuController.close();
    var worktree = first.$1;
    shell.isOpen(worktree)
        ? shell.select(worktree)
        : unawaited(shell.open(worktree));
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      // Aligns to the tabs' box rather than the band's, which is 6px taller.
      padding: const EdgeInsets.only(top: _tabInset),
      child: Center(
        child: MenuAnchor(
          controller: _menuController,
          alignmentOffset: const Offset(0, 4),
          style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(colors.bg),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: FwSpacing.md),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(context.radii.radius),
                side: BorderSide(color: colors.line),
              ),
            ),
          ),
          menuChildren: [
            WorktreeFilterField(
              controller: _filter,
              focusNode: _filterFocus,
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: (_) => _pickFirst(),
            ),
            _SwitcherMenu(
              shell,
              _menuController,
              open: _filtered(shell.openWorktrees),
              closed: _filtered(shell.closedWorktrees),
            ),
          ],
          builder: (context, controller, child) => Tooltip(
            message: 'Switch worktree',
            child: IconButton(
              onPressed: () => controller.isOpen ? controller.close() : _open(),
              icon: Icon(
                Icons.expand_more,
                size: FwIconSize.lg,
                color: colors.mut,
              ),
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitcherMenu extends StatelessWidget {
  const _SwitcherMenu(
    this.shell,
    this.menu, {
    required this.open,
    required this.closed,
  });

  final ShellController shell;
  final MenuController menu;
  final List<(Worktree, FilterMatch?)> open;
  final List<(Worktree, FilterMatch?)> closed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (open.isEmpty && closed.isEmpty) const NoWorktreeMatches(),
          if (open.isNotEmpty) ...[
            _MenuHeading('OPEN · ${open.length}'),
            for (var (worktree, match) in open)
              _SwitcherRow(shell, worktree, menu, match: match),
          ],
          if (closed.isNotEmpty) ...[
            const Gap(FwSpacing.md),
            _MenuHeading('NOT OPEN · ${closed.length}'),
            for (var (worktree, match) in closed)
              _SwitcherRow(shell, worktree, menu, match: match),
          ],
        ],
      ),
    );
  }
}

class _MenuHeading extends StatelessWidget {
  const _MenuHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.xl,
      vertical: FwSpacing.sm,
    ),
    child: Text(label, style: context.type.micro),
  );
}

/// The key a switcher row carries, so a test can point at the row rather than
/// at a name the tab band also shows.
Key switcherRowKey(Worktree worktree) => ValueKey('switcher:${worktree.path}');

/// How much of a switcher row the status may claim. The menu is 360 wide and
/// a worktree's name is the longest thing in it, so this is the smaller half
/// of what is left: enough for the statuses plugins actually write, and a
/// hard stop for the ones they should not.
const _switcherStatusWidth = 120.0;

class _SwitcherRow extends StatelessWidget {
  _SwitcherRow(this.shell, this.worktree, this.menu, {this.match})
    : super(key: switcherRowKey(worktree));

  final ShellController shell;
  final Worktree worktree;
  final MenuController menu;

  /// Where the filter found this row, so the run that kept it here is lit.
  final FilterMatch? match;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var isOpen = shell.isOpen(worktree);
    var status = shell.sessionFor(worktree)?.status ?? Status.none;

    return InkWell(
      onTap: () {
        // A MenuAnchor menu lives in an overlay, not on the Navigator — popping
        // the route here would unmount the whole shell.
        menu.close();
        isOpen ? shell.select(worktree) : unawaited(shell.open(worktree));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xl,
          vertical: FwSpacing.md,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              child: status.isEmpty || status.tone == Tone.neutral
                  ? null
                  : _Dot(toneColor(colors, status.tone)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  matchedName(
                    context,
                    worktree.displayName,
                    isOpen ? context.type.bodyStrong : context.type.body,
                    match: match,
                  ),
                  // Only when it adds something: with no contributed title,
                  // displayName *is* the branch, and showing it twice is noise.
                  if (worktree.title != null && worktree.branch != null)
                    matchedName(
                      context,
                      worktree.branch!,
                      context.type.caption,
                      match: match,
                      field: 1,
                    ),
                ],
              ),
            ),
            const Gap(FwSpacing.sm),
            // Worktrees that are not open hold no session, so there is nothing
            // to report about them yet — see open question 4.
            //
            // The rail's [StatusText], for the rail's reason: a status is
            // written by a plugin and a row is not the place to find out how
            // long one got. Taking its natural width, a plugin that put a log
            // line here squeezed the name column to nothing and set the
            // worktree's name one letter per line. The name is what this row
            // is *for*.
            if (isOpen)
              StatusText(status, maxWidth: _switcherStatusWidth)
            else
              Text(
                'Open',
                style: context.type.micro.copyWith(color: colors.accent),
              ),
          ],
        ),
      ),
    );
  }
}

/// The worktree's home row, then one row per plugin with the status its report
/// carries.
/// Finds the plugin rail. A plugin's label and a package's name also appear in
/// the address along the bottom, so a test about the rail has to say it means
/// the rail.
const sidebarKey = ValueKey('shell.sidebar');

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _railBody(context),
        // On the seam rather than beside it, so the rail loses no width to
        // something you can only see by looking for it. As wide as the chevron
        // it holds — the draggable part inside it is the seam alone.
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _railToggleSize,
          child: _RailHandle(shell),
        ),
      ],
    );
  }

  Widget _railBody(BuildContext context) {
    var colors = context.colors;
    var worktree = shell.selected;
    var session = shell.selectedSession;
    return Container(
      key: sidebarKey,
      width: shell.sidebarWidth,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: worktree == null
          ? null
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: FwSpacing.lg),
              children: [
                SidebarRow(
                  // Not the worktree's name: the tab above already says that,
                  // and this row is a destination, not a label.
                  label: 'Overview',
                  selected: shell.isHome,
                  onTap: shell.selectHome,
                  icon: Icons.home_outlined,
                  // The config error lives on that screen, so the row has to
                  // say so — otherwise it is invisible from any plugin panel.
                  status: shell.errorFor(worktree) == null
                      ? Status.none
                      : const Status.error('config'),
                ),
                // Above the plugin list, because it is not one: it reads git
                // rather than the project, and it is the one destination here
                // that works before a config has resolved.
                SidebarRow(
                  label: 'Changes',
                  selected: shell.isChangesScreen,
                  onTap: shell.selectChanges,
                  icon: Icons.difference_outlined,
                ),
                const Gap(FwSpacing.lg),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FwSpacing.xl,
                    0,
                    FwSpacing.xl,
                    FwSpacing.md,
                  ),
                  child: Text('PLUGINS', style: context.type.micro),
                ),
                if (session == null)
                  const _SidebarSkeleton()
                else if (session.plugins.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FwSpacing.xl,
                    ),
                    child: Text(
                      'No plugins declared.\nAdd them in tool/flutterware.dart.',
                      style: context.type.caption,
                    ),
                  )
                else
                  for (var plugin in session.plugins) _PluginRow(shell, plugin),
              ],
            ),
    );
  }
}

/// The rail's own edge: pull it to resize, and it is where the toggle lives.
///
/// The strip is always there and always drags; the chevron only appears under
/// the pointer. Tapping the strip itself does nothing — a divider that
/// collapsed the pane on a stray click would be a trap.
class _RailHandle extends StatefulWidget {
  const _RailHandle(this.shell);

  final ShellController shell;

  @override
  State<_RailHandle> createState() => _RailHandleState();
}

class _RailHandleState extends State<_RailHandle> {
  var _hovered = false;

  ShellController get shell => widget.shell;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Translucent, or this strip would eat the clicks of the rail rows it
      // overlaps — it is as wide as the chevron it has to hold, not as wide as
      // the seam.
      hitTestBehavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // The seam itself: where the resize cursor is, and the only part that
          // drags. The rest of this strip is the chevron's room.
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _railHandleWidth,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => shell.setSidebarResizing(true),
                // `delta` is in this widget's own coordinates, so it is already
                // in the app's scaled pixels — the rail follows the pointer at
                // the same rate whatever the window is doing.
                onHorizontalDragUpdate: (details) =>
                    shell.resizeSidebar(shell.sidebarWidth + details.delta.dx),
                onHorizontalDragEnd: (_) => shell.setSidebarResizing(false),
                onHorizontalDragCancel: () => shell.setSidebarResizing(false),
                // Straight back to 232, for a rail dragged somewhere silly.
                onDoubleTap: () => shell.resizeSidebar(defaultSidebarWidth),
              ),
            ),
          ),
          // Near the top rather than centred: the same place every time, and
          // the same place the peek strip puts it once the rail is gone.
          if (_hovered)
            Positioned(top: FwSpacing.lg, right: 0, child: _RailToggle(shell)),
        ],
      ),
    );
  }
}

/// Where the rail was, once it is hidden: a strip along the pane's left edge
/// that offers the way back when you go looking for it.
///
/// Nothing at all when there is a rail, or when the space has none to give — the
/// worktrees explorer is about every checkout and has no plugins to list, so an
/// affordance there would promise something that cannot happen.
class _RailPeek extends StatefulWidget {
  const _RailPeek(this.shell);

  final ShellController shell;

  @override
  State<_RailPeek> createState() => _RailPeekState();
}

class _RailPeekState extends State<_RailPeek> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    var shell = widget.shell;
    if (shell.sidebarVisible ||
        shell.inWorktreesSpace ||
        _gutterInFlow(shell)) {
      return const SizedBox.shrink();
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Translucent, so the panel underneath still takes every click that is
      // not the chevron's: this strip is a place to look, not a margin.
      hitTestBehavior: HitTestBehavior.translucent,
      child: SizedBox(
        width: _railPeekWidth,
        child: _hovered
            ? Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: FwSpacing.lg),
                  child: _RailToggle(shell),
                ),
              )
            : null,
      ),
    );
  }
}

/// Stands in for the plugin rows while the config is still running, so the
/// sidebar has the shape it will have rather than jumping into existence.
class _SidebarSkeleton extends StatelessWidget {
  const _SidebarSkeleton();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            height: 14,
            margin: EdgeInsets.fromLTRB(
              FwSpacing.xl,
              FwSpacing.md,
              FwSpacing.xl + i * 18.0,
              FwSpacing.md,
            ),
            decoration: BoxDecoration(
              color: colors.line,
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
          ),
      ],
    );
  }
}

/// One plugin's row, and its packages when it is the selected one.
///
/// **The rail's unit of subscription.** Both halves read this plugin's report
/// and nothing else's, so listening here is what keeps a plugin's tick off
/// every other plugin — the shell no longer forwards a session's changes, and
/// a health probe reporting the same thing it reported a second ago costs one
/// row rather than the window. The two rows are one widget for that reason: a
/// child row is as much this report as the parent row is.
class _PluginRow extends StatelessWidget {
  const _PluginRow(this.shell, this.plugin);

  final ShellController shell;
  final NativePlugin plugin;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: plugin,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    var report = plugin.core.report;
    // **A row does not repeat a word the row underneath it is already saying.**
    // The rail expands the selected plugin's packages, and several plugin
    // statuses are a reduction over exactly those children — previews answers
    // with whatever its busy package answers — so a compile wrote `compiling`
    // twice, one line directly above the other, and neither said more than the
    // other did.
    //
    // On an exact match only, which is what keeps this from hiding anything: a
    // summary no single child makes — `2 packages failed discovery` — is not
    // equal to any of them and stays where it is.
    var expanded = shell.selectedPluginId == plugin.id;
    var echoed =
        expanded &&
        report.children.any((child) => child.status == report.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SidebarRow(
          label: report.label,
          selected: expanded,
          onTap: () => shell.selectPlugin(plugin.id),
          status: echoed ? Status.none : report.status,
          actions: [
            for (var command in plugin.rowCommands())
              (
                label: command.label,
                icon: command.icon,
                // The shell does the navigating, which is the point: a plugin
                // names a place and never reaches into the rail.
                onTap: () => shell.selectChild(plugin.id, command.opens),
              ),
          ],
        ),
        // Expanded only for the selected plugin: a sidebar showing every
        // package of every plugin at once is a wall, not a summary.
        if (expanded)
          for (var child in report.children)
            SidebarChildRow(
              label: child.label,
              status: child.status,
              selected: shell.selectedChildId == child.id,
              commands: plugin.childCommands(context, child.id),
              onTap: () => shell.selectChild(plugin.id, child.id),
            ),
      ],
    );
  }
}

/// Mounts the selected plugin's panel — the one place a native plugin is
/// unrestricted Flutter — or the worktree's home screen.
class _Panel extends StatelessWidget {
  const _Panel(this.shell);

  final ShellController shell;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var worktree = shell.selected;
    var session = shell.selectedSession;

    // **Resolved before the session check, which is the whole point.** The
    // changes screen reads git, so it draws for a checkout that has no tab and
    // no config — and going through `addressedWorktree` rather than `selected`
    // is what makes that possible, since `selected` only knows the open ones.
    var changesFor = shell.isChangesScreen ? shell.addressedWorktree : null;

    Widget body;
    if (shell.isExplorer) {
      body = _Explorer(shell);
    } else if (changesFor != null) {
      // **Three renderings of one delta, and the file diff is the first of
      // them.** `ComparisonTabs` owns the strip and the two halves that need a
      // session; the files tab is handed in, because it is a screen of its own
      // with its own master, detail and index tabs — and because it renders for
      // a checkout nobody has opened, which the other two cannot.
      // A recording hands the screen its sources; a checkout is read as it
      // always was. Nothing is watched over a recording — there is no
      // working tree to watch, and no review file to.
      var sources = shell.changes;
      body = ComparisonTabs(
        key: ValueKey('changes::${changesFor.path}'),
        shell: shell,
        worktree: changesFor,
        environmentFor: sources?.comparison,
        files: (context, withinTabs) => ChangesScreen(
          key: ValueKey(changesFor.path),
          worktree: changesFor,
          showTitle: !withinTabs,
          isOpen: shell.isOpen(changesFor),
          repoRoot: shell.repoRoot,
          initialPath: _changesFilePath(shell),
          onPathChanged: (path) => shell.selectChangesFile(changesFor, path),
          gitMoved: shell.gitMoved,
          load: sources?.load,
          contents: sources?.contents,
          reviewStore: sources?.reviewStore(changesFor.path),
          live: sources == null,
        ),
      );
    } else if (worktree == null) {
      body = const _Message(title: 'No worktree open');
    } else if (session == null) {
      body = _Loading(worktree.displayName);
    } else if (shell.isConfigScreen) {
      body = ConfigScreen(shell, worktree);
    } else {
      var plugin = shell.selectedPluginId == null
          ? null
          : session.pluginById(shell.selectedPluginId!);
      body = plugin == null
          ? _RebuildsWhen(
              listenable: Listenable.merge([shell.worktreeFacts]),
              // The two facts this screen draws, of the one checkout it is
              // about. Not the agent, which it deliberately does not carry —
              // and the agent is the fact that moves every couple of seconds.
              select: () {
                var facts =
                    shell.worktreeFacts?.factsFor(worktree) ??
                    const WorktreeFacts();
                return (facts.git, facts.forge);
              },
              builder: (context, _) => WorktreeHome(
                worktree,
                // Keyed by checkout so switching worktrees resets the run watch
                // rather than leaving one screen's timer reading another's
                // ledger.
                key: ValueKey('home::${worktree.path}'),
                session: session,
                onOpenPlugin: shell.selectPlugin,
                facts:
                    shell.worktreeFacts?.factsFor(worktree) ??
                    const WorktreeFacts(),
                onRefreshFacts: () => unawaited(shell.refreshWorktreeFacts()),
                onOpenChanges: () => shell.selectChanges(worktree),
              ),
            )
          : KeyedSubtree(
              // Rebuild the panel from scratch when the worktree or the plugin
              // changes; panels hold their own state and must not leak it
              // across worktrees. Nothing below the plugin is in the key —
              // moving within a plugin should update the panel, not remount it,
              // or a compile loop would be torn down and restarted for a click
              // in its own tree.
              key: ValueKey('${session.worktree.path}::${plugin.id}'),
              // The plugin's own level of the address tree. The panel reads
              // what it needs from here; the shell does not read past the
              // plugin segment and does not pass what it has not read.
              child: AddressScope(child: plugin.buildPanel(context)),
            );
    }

    return Container(color: colors.bg, child: body);
  }
}

/// The file the address names, with the tab segment taken off the front.
///
/// `changes/files/app/lib/foo.dart` and `changes/app/lib/foo.dart` both mean
/// the same file: the first is what the tabs write now, the second is what this
/// screen's addresses looked like before there were any, and both still have to
/// resolve. Anything under another tab names nothing here.
String? _changesFilePath(ShellController shell) {
  var segments = shell.address.segments;
  if (segments.isEmpty) return null;
  if (comparisonTabIds.contains(segments.first)) {
    if (segments.first != filesTabId) return null;
    segments = segments.skip(1).toList();
  }
  return segments.isEmpty ? null : segments.join('/');
}

/// Mounts the explorer, and refreshes it on the way in.
///
/// Becoming visible is one of the three refresh triggers, and this is where
/// it lives — a screen appearing is the only moment that knows it happened.
/// Not a timer: with the branch diffs cached by their commits, arriving costs
/// the per-worktree `git status` and nothing else.
/// Subscribes to [listenable] and rebuilds only when [select] answers
/// differently.
///
/// For the two places that listen to the worktree facts and draw a slice of
/// them. The facts are live by design — an agent appending to its session file
/// moves one checkout's activity every couple of seconds, and the watchers
/// floor that at one refresh every two seconds — so every listener heard about
/// it at 2 Hz for as long as anybody anywhere was working. The explorer wants
/// exactly that. The pinned tab's badge is a count, and the home screen
/// deliberately carries no agent facts at all; for those two the notification
/// is noise.
///
/// [select] is compared with `==`. The facts model has no value equality — a
/// `Fact` carries the moment it was computed, which moves on every probe — so
/// the selectors here return the `Fact` objects themselves and lean on the
/// partial probes building with `copyWith`: a sweep that only re-read the
/// agents hands back the very same `git` and `forge` instances. Answering
/// "changed" when nothing did costs one rebuild; nothing here can answer
/// "same" about something that moved.
class _RebuildsWhen<T> extends StatefulWidget {
  const _RebuildsWhen({
    required this.listenable,
    required this.select,
    required this.builder,
  });

  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_RebuildsWhen<T>> createState() => _RebuildsWhenState<T>();
}

class _RebuildsWhenState<T> extends State<_RebuildsWhen<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select();
    widget.listenable.addListener(_check);
  }

  @override
  void didUpdateWidget(_RebuildsWhen<T> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_check);
      widget.listenable.addListener(_check);
    }
    // Whatever moved above this widget may have changed what [select] closes
    // over — a different checkout, a replaced controller. Read it again so the
    // next notification is compared against what is actually on screen.
    _value = widget.select();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_check);
    super.dispose();
  }

  void _check() {
    var next = widget.select();
    if (next == _value) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

class _Explorer extends StatefulWidget {
  const _Explorer(this.shell);

  final ShellController shell;

  @override
  State<_Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends State<_Explorer> {
  var _sort = ExplorerSort.activity;
  var _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(widget.shell.refreshWorktreeFacts());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The screen the facts are *for*. It redraws when a probe lands and
    // nothing else in the window does.
    listenable: Listenable.merge([widget.shell.worktreeFacts]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    var shell = widget.shell;
    var facts = shell.worktreeFacts;
    return WorktreeExplorerView(
      entries: [
        for (var worktree in shell.worktrees)
          ExplorerEntry(
            worktree: worktree,
            facts: facts?.factsFor(worktree) ?? const WorktreeFacts(),
            isOpen: shell.isOpen(worktree),
          ),
      ],
      now: DateTime.now(),
      query: _query,
      sort: _sort,
      refreshedAt: facts?.refreshedAt,
      isRefreshing: facts?.isRefreshing ?? false,
      currentWorktreePath: shell.selected?.path,
      onQueryChanged: (value) => setState(() => _query = value),
      onSortChanged: (value) => setState(() => _sort = value),
      onRefresh: () => unawaited(shell.refreshWorktreeFacts(force: true)),
      // **Only the Open button opens.** Tapping a row expands it instead —
      // opening costs a config subprocess and a tab, and this screen exists so
      // you can decide before spending that.
      onOpen: (entry) => unawaited(shell.open(entry.worktree)),
      onRemove: (entry) => unawaited(_remove(entry)),
      // …and reading what it changed opens nothing. That is the whole reason
      // the changes screen is shell-owned rather than a plugin.
      onOpenChanges: (entry) => shell.selectChanges(entry.worktree),
      repoRoot: shell.repoRoot,
    );
  }

  /// Removing a checkout: **ask first, and prepare behind the dialog.**
  ///
  /// The explorer's design left open how a closed worktree gets a checklist —
  /// plugin steps need a session, and a closed worktree has none. It is opened,
  /// and two things about *how* were bugs worth writing down:
  ///
  /// - **In the background.** `open` navigates, so opening from here unmounted
  ///   the explorer mid-flow and the dialog never appeared — the press looked
  ///   like it had simply switched worktrees. `openInBackground` gives the
  ///   worktree a tab and a running config and leaves the address alone.
  /// - **Behind the dialog.** Opening, refreshing the facts and warming every
  ///   plugin takes seconds, and doing it before `showDialog` meant a press
  ///   with no acknowledgement at all. The dialog goes up first and waits.
  ///
  /// The facts are refreshed rather than read: `TeardownStep.enabled`,
  /// `checked` and `detail` are values on a cached report, so a stale one would
  /// offer to tear down a stack that went down five minutes ago — and the
  /// warning about uncommitted work has to be this moment's count, not this
  /// morning's.
  Future<void> _remove(ExplorerEntry entry) async {
    var shell = widget.shell;
    var worktree = entry.worktree;

    var removed = await showTeardownDialog(
      context,
      prepare: () async {
        await shell.openInBackground(worktree);
        await shell.refreshWorktreeFacts(force: true);
        var session = shell.sessionFor(worktree);
        // The same warm-up `fw status` does. A report is a pure read of cached
        // state, so a plugin nothing has mounted this session would contribute
        // "not computed" to a checklist that is about to delete a directory.
        await computeAllCores(session?.session.cores ?? const <PluginCore>[]);
        return TeardownPreparation(
          TeardownPlan.build(
            worktree: worktree.displayName,
            path: worktree.path,
            branch: worktree.branch,
            isMain: worktree.isMain,
            facts:
                shell.worktreeFacts?.factsFor(worktree) ??
                const WorktreeFacts(),
            reports: session?.reports ?? const [],
            sessionOpen: session != null,
          ),
          session,
        );
      },
      // Git runs in the primary checkout: the worktree's own directory is what
      // is being removed, and `git worktree remove` cannot be run from inside
      // it.
      repositoryRoot: shell.worktrees
          .firstWhere((w) => w.isMain, orElse: () => worktree)
          .path,
    );
    if (!mounted || !removed) return;
    // Re-read from git rather than editing the list: `rescanWorktrees` closes
    // whatever disappeared, so the tab goes because the directory did.
    await shell.rescanWorktrees();
  }
}

/// What an opening worktree shows while its config runs. The tab is already
/// there; this is the rest of the window catching up.
class _Loading extends StatelessWidget {
  const _Loading(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const Gap(FwSpacing.lg),
        Text('Reading $name’s config…', style: context.type.caption),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxxl),
      child: Text(
        title,
        style: context.type.heading.copyWith(color: context.colors.mut2),
      ),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
