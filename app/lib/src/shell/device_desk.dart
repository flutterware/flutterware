import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../plugins/native/run_core.dart' show runPluginId;
import '../run/handle.dart';
import '../run/inventory.dart';
import '../ui/badged_icon.dart';
import '../ui/theme.dart';
import '../utils/daemon/device.dart';
import '../utils/run_dir.dart';
import 'shell_controller.dart';
import 'worktree.dart';
import '../run/run_sources.dart';

/// The desk, in the chrome: what is on this machine, what is free, and who
/// has the rest — with the one move the panel structurally cannot offer,
/// jumping to the worktree that holds a busy device.
///
/// This is the promotion the cockpit design deferred ("still to promote to
/// shell chrome with the worktree-jump"). It reads the same files every other
/// surface does — `devices.json` and the `app-*.json` ledger — rather than a
/// `RunCore`, because the chrome outlives any one worktree session and the
/// whole point of the ledger is that it needs no process to ask. No daemon is
/// started here: the list carries its age, and taking a fresh one stays the
/// Run panel's business. Booting emulators stays there too, with the daemon.
class DeskButton extends StatefulWidget {
  const DeskButton(this.shell, {super.key});

  final ShellController shell;

  /// The same seam `RunCore.runDirProvider` is: tests point it at a temp dir
  /// rather than the developer's real ledger.
  @visibleForTesting
  static String Function() runDirProvider = flutterwareRunDir;

  @override
  State<DeskButton> createState() => _DeskButtonState();
}

class _DeskButtonState extends State<DeskButton> {
  final _menuController = MenuController();

  DeviceCache? _cache;
  var _handles = <RunHandle>[];
  Timer? _refresh;

  /// Devices some run is holding right now — the number on the badge.
  ///
  /// Polled at rest, unlike everything else here, because the badge is the
  /// button's whole story while the menu is closed: *N devices are busy* is
  /// the fact that makes the desk worth opening, and a badge that only
  /// updated on open would be describing the last visit. One directory
  /// listing every few seconds, and a `setState` only when the number moves.
  var _busy = 0;
  Timer? _badgeTick;

  @override
  void initState() {
    super.initState();
    unawaited(
      _runs.files.ready.then((_) {
        if (mounted) _readBadge();
      }),
    );
    // Nothing under a recording moves, so nothing is re-read.
    if (_runs.readOnly == null) {
      _badgeTick = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _readBadge(),
      );
    }
  }

  RunSources get _runs => widget.shell.runs;

  String get _runDir => _runs.runDir ?? DeskButton.runDirProvider();

  @override
  void dispose() {
    _refresh?.cancel();
    _badgeTick?.cancel();
    super.dispose();
  }

  void _readBadge() {
    var handles = scanRunHandles(_runDir, files: _runs.files);
    var busy = {for (var handle in handles) handle.device}.length;
    if (busy == _busy) return;
    setState(() => _busy = busy);
  }

  /// Two file reads, repeated while the menu is up so a launch or a stop in
  /// any process shows without reopening. Cheap on purpose: a directory
  /// listing and a handful of small JSON files.
  void _read() {
    var runDir = _runDir;
    setState(() {
      _cache = DeviceCache.read(runDir, files: _runs.files);
      _handles = scanRunHandles(runDir, files: _runs.files);
      _busy = {for (var handle in _handles) handle.device}.length;
    });
  }

  void _open() {
    _read();
    _menuController.open();
    _refresh?.cancel();
    if (_runs.readOnly != null) return;
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) => _read());
  }

  /// The worktree holding [handle], when this repo has it. Null for a run
  /// launched from another repo — still listed, because it is still holding
  /// the device, but there is no tab to jump to.
  Worktree? _worktreeOf(RunHandle handle) {
    for (var worktree in widget.shell.worktrees) {
      if (p.canonicalize(worktree.path) == p.canonicalize(handle.worktree)) {
        return worktree;
      }
    }
    return null;
  }

  /// Straight to the run's own page, in the worktree that can drive it.
  /// [ShellController.go] opens the worktree first when it is closed.
  void _jump(Worktree worktree, RunHandle handle) {
    _menuController.close();
    widget.shell.go(
      Address(
        worktree: worktree.name,
        plugin: runPluginId,
        segments: [handle.key],
      ),
    );
  }

  /// The Run panel of whichever worktree is open — the page with the launch
  /// form, the emulators and the boot control on it.
  ///
  /// **This menu can only read.** It has no `RunCore` and starts no daemon by
  /// design, so it can tell you a device is free and cannot offer to use it.
  /// Until this row existed it did not say where the offer lived either, and
  /// the two surfaces read as unrelated lists of the same machines.
  void _openRunPanel(Worktree worktree) {
    _menuController.close();
    widget.shell.go(Address(worktree: worktree.name, plugin: runPluginId));
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MenuAnchor(
      controller: _menuController,
      onClose: () => _refresh?.cancel(),
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
      menuChildren: [_menu(context)],
      builder: (context, controller, child) => Tooltip(
        message: _busy == 0
            ? 'Devices on this machine, and who is using them'
            : '$_busy device${_busy == 1 ? '' : 's'} in use',
        child: IconButton(
          onPressed: () => controller.isOpen ? controller.close() : _open(),
          icon: BadgedIcon(
            Icons.devices_outlined,
            count: _busy,
            size: FwIconSize.md,
            color: colors.mut,
          ),
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    var colors = context.colors;
    var devices = (_cache?.devices ?? const <DaemonDevice>[]).toList()
      ..sort(compareDevices);
    // A run on a device the cache has never seen — a stale list, or a device
    // that has since been unplugged — is still holding it, so it still rows.
    var listed = {for (var device in devices) device.id};
    var unlisted = [
      for (var handle in _handles)
        if (!listed.contains(handle.device)) handle,
    ];

    return SizedBox(
      width: 340,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xl,
              vertical: FwSpacing.sm,
            ),
            child: Row(
              children: [
                Text('ON THIS MACHINE', style: context.type.micro),
                const Gap(FwSpacing.sm),
                if (_cache case var cache?)
                  Text(
                    cache.ageDescription,
                    style: context.type.micro.copyWith(color: colors.mut3),
                  ),
              ],
            ),
          ),
          if (devices.isEmpty && unlisted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.xl,
                vertical: FwSpacing.md,
              ),
              child: Text(
                'No device list has been taken on this machine yet. '
                'A worktree’s Run panel takes one when it opens.',
                style: context.type.caption,
              ),
            ),
          for (var device in devices) _deviceRow(context, device),
          for (var handle in unlisted) _unlistedRow(context, handle),
          // Where the offers are. This list can say a phone is free and cannot
          // hand it to you; the panel can boot an emulator, take a fresh
          // reading and start an app on one. Two surfaces over the same
          // machines read as unrelated until one of them points at the other.
          if (widget.shell.selected case var worktree?) ...[
            const Gap(FwSpacing.sm),
            Divider(height: 1, color: colors.line),
            const Gap(FwSpacing.sm),
            InkWell(
              onTap: () => _openRunPanel(worktree),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.xl,
                  vertical: FwSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      size: FwIconSize.sm,
                      color: colors.accent,
                    ),
                    const Gap(FwSpacing.sm),
                    // The offer takes the slack and the name is capped, which
                    // is the only arrangement of the two that survives both
                    // ways round. An `Expanded` label beside an unbounded name
                    // let a branch called
                    // `claude/missing-run-creation-buttons-121458` truncate the
                    // sentence to `Start …` and keep its own name whole; an
                    // unbounded label overflowed the 340px menu by 93px the
                    // moment the text got wider than this Mac's UI font, which
                    // is every widget test and any large text scale.
                    Expanded(
                      child: Text(
                        'Start one, or boot an emulator',
                        style: context.type.bodySmall.copyWith(
                          color: colors.accent,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Gap(FwSpacing.sm),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(
                        worktree.displayName,
                        style: context.type.micro.copyWith(color: colors.mut2),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deviceRow(BuildContext context, DaemonDevice device) {
    var holder = _handles
        .where((handle) => handle.device == device.id)
        .firstOrNull;
    return _DeskRow(
      icon: _iconFor(device),
      label: device.displayName,
      status: _statusOf(device, holder),
      holder: holder,
      worktree: holder == null ? null : _worktreeOf(holder),
      onJump: _jump,
    );
  }

  /// A row for a run whose device the cached list does not carry.
  Widget _unlistedRow(BuildContext context, RunHandle handle) => _DeskRow(
    icon: Icons.smartphone_outlined,
    label: handle.deviceLabel,
    status: '${handle.runLabel} · ${handle.worktreeName}',
    holder: handle,
    worktree: _worktreeOf(handle),
    onJump: _jump,
  );

  /// The panel desk's vocabulary, unchanged: a host is never `free`, because
  /// it was never anybody's to take.
  static String _statusOf(DaemonDevice device, RunHandle? holder) {
    if (!device.isConnected) return 'not connected';
    if (holder == null) {
      return device.kind == MachineKind.host ? 'not running' : 'free';
    }
    return device.kind == MachineKind.host
        ? 'running ${holder.runLabel} · ${holder.worktreeName}'
        : '${holder.runLabel} · ${holder.worktreeName}';
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

class _DeskRow extends StatelessWidget {
  const _DeskRow({
    required this.icon,
    required this.label,
    required this.status,
    required this.holder,
    required this.worktree,
    required this.onJump,
  });

  final IconData icon;
  final String label;
  final String status;

  /// The run occupying the device, when one is.
  final RunHandle? holder;

  /// Where the jump goes — null when the device is free, or when the holder
  /// belongs to a repo this shell has never heard of.
  final Worktree? worktree;

  final void Function(Worktree worktree, RunHandle handle) onJump;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var jumpable = holder != null && worktree != null;
    var row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(icon, size: FwIconSize.sm, color: colors.mut2),
          const Gap(FwSpacing.sm),
          Flexible(
            flex: 0,
            child: Text(
              label,
              style: context.type.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Text(
              status,
              style: context.type.caption.copyWith(
                color: jumpable ? colors.accent : colors.mut2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (jumpable) ...[
            const Gap(FwSpacing.sm),
            Icon(
              Icons.arrow_forward,
              size: FwIconSize.xs,
              color: colors.accent,
            ),
          ],
        ],
      ),
    );
    if (!jumpable) return row;
    return Tooltip(
      message: 'Go to ${worktree!.displayName}',
      child: InkWell(onTap: () => onJump(worktree!, holder!), child: row),
    );
  }
}
