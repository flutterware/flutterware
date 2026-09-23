import 'package:material_ui/material_ui.dart';

import '../../capture/capture_mode.dart';
import '../../ui/action_button.dart';
import '../../ui/menu.dart';
import '../../ui/panel_header.dart';
import '../../utils/string/plural.dart';
import '../../ui/theme.dart';
import '../model/surface.dart';

/// Whether anything on disk was made from the config, said in one phrase.
///
/// Three states rather than a bool, because "never run" and "run, then the
/// config moved" want different words *and* different colours — and the panel
/// spent a while saying the second as though it were an ordinary count.
enum SplashGeneratedState {
  /// `create` has never run in this package.
  never,

  /// Generated, and the config has not moved since.
  current,

  /// Generated, then the config was edited. What ships is the old splash.
  stale;

  String label(int files) => switch (this) {
    never => 'Never generated',
    current => '${counted(files, 'file')} generated',
    stale => 'Generated, then edited',
  };
}

/// The top of the panel: what is being looked at, and the two things you can do
/// to it.
///
/// A view — every value arrives as data and every action leaves as a callback.
///
/// The package is the title rather than the config file. The rail already says
/// "Splash screen", so repeating the subject here would spend the largest type
/// on the one thing the reader already knows. What varies is which package and
/// which flavor, so those are what the eye lands on; the file it was read from
/// is provenance and sits in the subtitle with the clock.
class SplashPanelHeader extends StatelessWidget {
  const SplashPanelHeader({
    super.key,
    required this.package,
    required this.configPath,
    required this.state,
    required this.fileCount,
    this.fromPubspec = false,
    this.scannedAt,
    this.flavors = const [],
    this.selectedFlavor,
    this.onFlavor,
    this.size,
    this.onSize,
    this.onReload,
  });

  final String package;
  final String configPath;
  final bool fromPubspec;

  final SplashGeneratedState state;
  final int fileCount;

  /// When the panel last read the disk. Printed as a wall clock rather than
  /// "2 minutes ago", which would need a ticker to stay true — and a staleness
  /// display that is itself stale is worse than none.
  final DateTime? scannedAt;

  final List<String> flavors;
  final String? selectedFlavor;
  final ValueChanged<String?>? onFlavor;

  /// How big a screen every cell is drawn at. Null is each surface's own
  /// default.
  final SplashScreenSize? size;
  final ValueChanged<SplashScreenSize?>? onSize;

  /// Awaited, so the button can hold a running state and then say whether the
  /// re-read worked — see [FwActionButton].
  final Future<void> Function()? onReload;

  @override
  Widget build(BuildContext context) {
    return FwPanelHeader(
      package,
      badge: _StatusPill(state: state, files: fileCount),
      subtitle: [
        configPath,
        if (fromPubspec) 'from the pubspec section',
        if (scannedAt != null && !CaptureMode.isCapturing(context))
          'read at ${_clock(scannedAt!)}',
      ],
      below: flavors.isEmpty
          ? null
          : _Flavors(
              flavors: flavors,
              selected: selectedFlavor,
              onSelect: onFlavor,
            ),
      toolbar: _Toolbar(size: size, onSize: onSize, onReload: onReload),
    );
  }
}

String _two(int value) => '$value'.padLeft(2, '0');

String _clock(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

/// The generation state, as a pill rather than as text floating at the far
/// right of the title row — which is where it was, and which on a wide window
/// left it stranded a screen away from the thing it describes.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state, required this.files});

  final SplashGeneratedState state;
  final int files;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (fg, bg) = switch (state) {
      SplashGeneratedState.stale => (
        colors.amber,
        colors.amber.withValues(alpha: 0.12),
      ),
      SplashGeneratedState.current => (colors.accent, colors.accentSoft),
      SplashGeneratedState.never => (colors.mut, colors.panel2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        state.label(files),
        style: context.type.micro.copyWith(color: fg),
      ),
    );
  }
}

/// The controls, on their own rule below the title.
///
/// Borrowed from the asset inspector: a bordered strip and real bordered
/// buttons, rather than the accent-coloured text links this panel used to call
/// controls.
///
/// The size switcher is here rather than on the inspector, because it moves
/// all eight cells and belongs over all eight. It could not, while the axis was
/// a device id: a device names a platform with it, so a chosen iPhone redrew two
/// tiles and quietly ignored six. A size class names none — see
/// [SplashScreenSize].
///
/// Nothing here writes to the project. There was a
/// `Run flutter_native_splash:create` button for a while. It threw away
/// everything that would have made it trustworthy — `generate` returns the
/// generator's own stdout and stderr precisely because they name the file it
/// choked on, and the button discarded all of it, so a failed run looked like a
/// quiet re-scan. And running the generator belongs to whoever edited the
/// config: in the loop this panel is for, that is an agent, which calls the
/// action and gets `ok`, `exitCode` and `output` back as data — a better
/// surface than any dialog. What is left of this panel never touches your
/// repo.
class _Toolbar extends StatelessWidget {
  const _Toolbar({this.size, this.onSize, this.onReload});

  final SplashScreenSize? size;
  final ValueChanged<SplashScreenSize?>? onSize;
  final Future<void> Function()? onReload;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xxl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          if (onSize != null) _SizePicker(size: size, onSelect: onSize!),
          const Spacer(),
          if (onReload != null)
            FwActionButton(
              label: 'Reload',
              tooltip: 'Read the config and its images again',
              onPressed: onReload,
            ),
        ],
      ),
    );
  }
}

/// How big a screen every cell is drawn at.
///
/// Four classes and a default, rather than nineteen devices: this control has to
/// mean something on all four surfaces at once, and only a class does. Each
/// surface resolves it to its own hardware, so picking "Small phone" gives the
/// Android row a 360×640 with a gesture bar and the iOS row a 375×667 with a
/// notch — which is the comparison somebody asking for a small phone wants.
class _SizePicker extends StatelessWidget {
  const _SizePicker({required this.size, required this.onSelect});

  final SplashScreenSize? size;
  final ValueChanged<SplashScreenSize?> onSelect;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Screen', style: context.type.micro),
        const Gap(FwSpacing.md),
        Menu(
          entries: [
            MenuItem(
              // Not "None": every cell is drawn at *some* size, and what the
              // default means is per surface — a tall Android phone, an
              // iPhone 16, a browser viewport.
              'Each platform’s default',
              onSelected: () => onSelect(null),
            ),
            const MenuDivider(),
            for (var candidate in SplashScreenSize.values)
              MenuItem(candidate.label, onSelected: () => onSelect(candidate)),
          ],
          builder: (context, controller) => InkWell(
            onTap: controller.toggle,
            borderRadius: BorderRadius.circular(context.radii.radius),
            child: Container(
              padding: const EdgeInsets.only(
                left: FwSpacing.lg,
                right: FwSpacing.md,
                top: FwSpacing.xs,
                bottom: FwSpacing.xs,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(context.radii.radius),
                border: Border.all(color: colors.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    size?.label ?? 'Default',
                    style: context.type.caption.copyWith(color: colors.ink),
                  ),
                  const Gap(FwSpacing.xs),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: FwIconSize.sm,
                    color: colors.mut2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Which `flutter_native_splash-<flavor>.yaml` is being read.
///
/// Selectable now rather than a read-only badge: a project with flavors has one
/// config per flavor and the panel could only ever show whichever the address
/// happened to name.
class _Flavors extends StatelessWidget {
  const _Flavors({required this.flavors, this.selected, this.onSelect});

  final List<String> flavors;
  final String? selected;
  final ValueChanged<String?>? onSelect;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Wrap(
      spacing: FwSpacing.sm,
      runSpacing: FwSpacing.sm,
      children: [
        for (var (label, value) in [
          ('default', null),
          for (var flavor in flavors) (flavor, flavor),
        ])
          InkWell(
            onTap: onSelect == null ? null : () => onSelect!(value),
            borderRadius: BorderRadius.circular(context.radii.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: value == selected ? colors.accentSoft : null,
                borderRadius: BorderRadius.circular(context.radii.pill),
                border: Border.all(
                  color: value == selected ? colors.accent : colors.line,
                ),
              ),
              child: Text(
                label,
                style: context.type.caption.copyWith(
                  color: value == selected ? colors.accent : colors.mut,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
