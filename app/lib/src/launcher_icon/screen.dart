import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutterware/plugins.dart';

import '../address/address_scope.dart';
import '../plugins/native/icon_address.dart';
import '../plugins/native/icon_core.dart';
import '../ui/design/design.dart';
import '../ui/empty_state.dart';
import '../ui/theme.dart';
import '../utils/string/plural.dart';
import 'model/role.dart';
import 'model/scan.dart';
import 'model/wiring.dart';
import 'ui/detail.dart';
import 'ui/flavor_chips.dart';
import 'ui/plate.dart';
import '../ui/loading_state.dart';
import '../ui/error_state.dart';

/// Every launcher icon a package has: a plate per role on the left, and the
/// selected one shown where it actually lives on the right.
///
/// The two halves answer different questions, which is why both are here. The
/// plates answer *what have I got, and what does each platform do to it* — the
/// source beside every shape a launcher might clip it to, the finding attached
/// to the thing it is about. The stage answers *is it any good*, which is a
/// relative judgement no thumbnail can support: too heavy beside its
/// neighbours, invisible on a dark wallpaper, unreadable at the 16px a tab
/// gives it.
///
/// Master–detail rather than a stack, following the scenarios panel: the list
/// stays visible, so opening one icon never hides where you are among the rest.
class LauncherIconScreen extends StatefulWidget {
  const LauncherIconScreen(
    this.core, {
    super.key,
    required this.package,
    this.flavor,
    this.role,
    this.mask,
    this.image = fileIconImage,
  });

  final LauncherIconCore core;
  final String package;

  /// How a file becomes a picture — off the disk unless told otherwise.
  ///
  /// The one place the screen touches a filesystem, and so the one thing a
  /// recorded scan has to bring with it: its files live wherever the recording
  /// does, and in a browser that is a URL rather than a path. Kept here rather
  /// than on the core because an `ImageProvider` is Flutter, and a core is
  /// linked into `fw`.
  final IconImage image;

  /// Which Android source set, from the address.
  final String? flavor;

  /// The role the address names, if it names one.
  final IconRole? role;

  final AdaptiveMask? mask;

  @override
  State<LauncherIconScreen> createState() => _LauncherIconScreenState();
}

class _LauncherIconScreenState extends State<LauncherIconScreen> {
  AdaptiveMask? _mask;
  IconRole? _role;
  bool _rolePicked = false;
  bool _safeZone = false;
  bool _dark = true;

  /// The address wins when it names one, so a pasted link shows what it says;
  /// otherwise the local choice does.
  AdaptiveMask get _adaptiveMask =>
      widget.mask ?? _mask ?? AdaptiveMask.squircle;

  IconRole? get _selectedRole => _rolePicked ? _role : widget.role;

  @override
  void didUpdateWidget(LauncherIconScreen old) {
    super.didUpdateWidget(old);
    if (old.role != widget.role) _rolePicked = false;
  }

  Future<void> _reload() async {
    await widget.core.reload(widget.package, flavor: widget.flavor);
    if (mounted) setState(() {});
  }

  /// Held locally *and* written to the address, so the panel works with no
  /// [AddressScope] above it — a widget test, or a dev entry point.
  void _select(IconRole? role) {
    setState(() {
      _role = role;
      _rolePicked = true;
    });
    AddressScope.maybeWrite(context)?.setParam('role', role?.id);
  }

  /// A flavor is a **different set of files**, so it is a segment rather than a
  /// local choice: the package and the flavor together decide what the core
  /// scans, and only the address reaches that far. The role goes with it —
  /// `androidMonochrome` under `main` names nothing under a flavor that never
  /// generated one, and a detail pane left pointing at it would say the flavor
  /// was empty when the panel simply arrived asking for the wrong file.
  void _selectFlavor(String? flavor) {
    AddressScope.maybeWrite(context)?.update(
      segments: iconSegments(widget.package, flavor),
      params: {'role': null},
    );
  }

  @override
  Widget build(BuildContext context) {
    var core = widget.core;
    var failure = core.failureFor(widget.package, flavor: widget.flavor);
    if (failure != null) {
      return ErrorState(title: 'Could not read the icons', message: failure);
    }

    var scan = core.scanFor(widget.package, flavor: widget.flavor);
    if (scan == null) {
      return const LoadingState(title: 'Reading the icons…');
    }

    if (scan.isEmpty) {
      return const EmptyState(
        icon: Icons.image_outlined,
        title: 'No launcher icons found',
        message:
            'Nothing under android/, ios/, macos/, web/, windows/ or snap/ '
            'looks like an app icon.',
      );
    }

    var selected = _selectedRole;
    var selectedScan = selected == null ? null : scan.forRole(selected);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _Plates(
            scan: scan,
            image: widget.image,
            selected: selected,
            adaptiveMask: _adaptiveMask,
            onSelect: _select,
            onReload: _reload,
            scanning: core.isScanning(widget.package, flavor: widget.flavor),
            flavor: widget.flavor,
            onFlavor: _selectFlavor,
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 380,
          child: selectedScan == null || selectedScan.isEmpty
              ? const EmptyState(
                  icon: Icons.smartphone_outlined,
                  title: 'Pick an icon',
                  message: 'Opening one shows it where it is actually seen.',
                )
              : _detail(scan, selectedScan),
        ),
      ],
    );
  }

  Widget _detail(IconScan scan, IconRoleScan role) {
    var background = _backgroundFor(scan, role.role);

    return IconDetail(
      key: ValueKey(role.role.id),
      role: role.role,
      image: _imageFor(role.largest),
      backgroundImage: _imageFor(background?.largest),
      backgroundColor: _colorOf(background?.color),
      color: role.color,
      files: [
        for (var file in role.files)
          (image: widget.image(file), size: file.width, density: file.density),
      ],
      findings: _findingsFor(scan, role.role),
      context_: _inheritedLine(scan.forRole(role.role)),
      adaptiveMask: _adaptiveMask,
      onMask: (mask) => setState(() => _mask = mask),
      showSafeZone: _safeZone,
      onSafeZone: (on) => setState(() => _safeZone = on),
      dark: _dark,
      onDark: (on) => setState(() => _dark = on),
    );
  }

  /// The adaptive background a layer is composited over, when it has one — a
  /// foreground drawn over nothing is not what a launcher shows.
  ///
  /// The **foreground only**. A themed icon throws the adaptive background away
  /// along with everything else and takes both its colours from the wallpaper,
  /// so handing it one would paint a ground Android never uses.
  IconRoleScan? _backgroundFor(IconScan scan, IconRole role) =>
      role == IconRole.androidAdaptiveForeground
      ? scan.forRole(IconRole.androidAdaptiveBackground)
      : null;

  /// Said out loud when the flavor overrides none of this role's files: what
  /// ships under it is the unflavored art, and a pane that drew it without
  /// saying so would credit the flavor with a picture it does not own.
  String? _inheritedLine(IconRoleScan? role) {
    if (widget.flavor == null || role == null || !role.allInherited) {
      return null;
    }
    return 'Not overridden by ${widget.flavor} — this is the unflavored art, '
        'which is what a build of that flavor ships.';
  }

  List<({Tone tone, String message})> _findingsFor(
    IconScan scan,
    IconRole role,
  ) => [
    for (var finding in scan.findings)
      if (finding.role == role) (tone: finding.tone, message: finding.message),
  ];

  ImageProvider? _imageFor(IconFile? file) =>
      file == null ? null : widget.image(file);
}

/// How an [IconFile] becomes a picture.
typedef IconImage = ImageProvider Function(IconFile file);

/// The live answer: the file, where the scan found it.
ImageProvider fileIconImage(IconFile file) =>
    FileImage(File(file.absolutePath));

Color? _colorOf(String? value) {
  var parsed = parseResourceColor(value);
  return parsed == null ? null : Color(parsed);
}

/// The master pane: one plate per role, grouped by the platform whose rules
/// apply.
class _Plates extends StatelessWidget {
  const _Plates({
    required this.scan,
    required this.image,
    required this.adaptiveMask,
    required this.onSelect,
    required this.onReload,
    required this.scanning,
    required this.onFlavor,
    this.selected,
    this.flavor,
  });

  final IconScan scan;
  final IconRole? selected;
  final IconImage image;
  final AdaptiveMask adaptiveMask;
  final ValueChanged<IconRole?> onSelect;
  final VoidCallback onReload;
  final bool scanning;
  final String? flavor;
  final ValueChanged<String?> onFlavor;

  ImageProvider? _imageFor(IconFile? file) => file == null ? null : image(file);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        _Header(
          scan: scan,
          selected: flavor,
          scanning: scanning,
          onReload: onReload,
          onFlavor: onFlavor,
        ),
        const Gap(FwSpacing.xxl),
        for (var platform in scan.platforms) ...[
          Text(platform.label, style: context.type.sectionLabel),
          const Gap(FwSpacing.lg),
          for (var role in scan.forPlatform(platform))
            if (role.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: FwSpacing.lg),
                child: IconPlate(
                  key: ValueKey(role.role.id),
                  role: role.role,
                  image: _imageFor(role.largest),
                  color: role.color,
                  backgroundImage: _imageFor(
                    role.role == IconRole.androidAdaptiveForeground ||
                            role.role == IconRole.androidMonochrome
                        ? scan
                              .forRole(IconRole.androidAdaptiveBackground)
                              ?.largest
                        : null,
                  ),
                  backgroundColor: _colorOf(
                    role.role == IconRole.androidAdaptiveForeground ||
                            role.role == IconRole.androidMonochrome
                        ? scan
                              .forRole(IconRole.androidAdaptiveBackground)
                              ?.color
                        : null,
                  ),
                  adaptiveMask: adaptiveMask,
                  detail: _detailLine(role),
                  findings: [
                    for (var finding in scan.findings)
                      if (finding.role == role.role)
                        (tone: finding.tone, message: finding.message),
                  ],
                  selected: role.role == selected,
                  onTap: () =>
                      onSelect(role.role == selected ? null : role.role),
                ),
              ),
          const Gap(FwSpacing.lg),
        ],
      ],
    );
  }

  /// Sizes and how many, in one line.
  String? _detailLine(IconRoleScan role) {
    var largest = role.largest;
    if (largest == null) return null;
    if (largest.icoFrames.isNotEmpty) {
      return '${largest.icoFrames.length} frames · '
          '${largest.icoFrames.first} → ${largest.icoFrames.last}px';
    }
    if (largest.width == null) {
      return '${role.files.length} files${_from(role)}';
    }
    var size = '${largest.width}×${largest.height}';
    return (role.files.length == 1
            ? size
            : '$size · ${role.files.length} ${role.role.platform == IconPlatform.android ? 'densities' : 'sizes'}') +
        _from(role);
  }

  /// Which of these files the flavor does not actually replace.
  ///
  /// Said in the platform-neutral word because the set being inherited from is
  /// `android/app/src/main/res/` on one side and `AppIcon.appiconset` on the
  /// other; the pane beside the list names the one that applies.
  ///
  /// On the plate rather than only in the pane beside it, because the question
  /// a flavor is opened with is *which of these did we actually fork* — and
  /// that is a comparison across the list, which only the list can answer.
  String _from(IconRoleScan role) {
    if (flavor == null) return '';
    var inherited = role.files.where((file) => file.inherited).length;
    if (inherited == 0) return '';
    return inherited == role.files.length
        ? ' · not overridden'
        : ' · $inherited not overridden';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.scan,
    required this.onReload,
    required this.onFlavor,
    this.selected,
    this.scanning = false,
  });

  final IconScan scan;
  final VoidCallback onReload;
  final String? selected;
  final bool scanning;
  final ValueChanged<String?> onFlavor;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    var colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // The package path is the one thing here that has no bound — a
            // nested package is as long as its directories. It yields first,
            // so the count beside it stays whole.
            Flexible(
              child: Text(
                scan.packagePath == '.' ? 'root' : scan.packagePath,
                style: type.heading,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(FwSpacing.md),
            Text(
              '${scan.fileCount} ${plural(scan.fileCount, 'file')}',
              style: type.caption.copyWith(color: colors.mut),
            ),
            const Spacer(),
            // The files are written by something outside this process — a
            // generator in another terminal, a designer dropping a PNG in — so
            // there has to be a way to look again without reopening the panel.
            IconButton(
              onPressed: scanning ? null : onReload,
              iconSize: FwIconSize.md,
              visualDensity: VisualDensity.compact,
              tooltip: 'Read the icons again',
              icon: scanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (scan.ios == IosCatalog.iconComposer ||
            scan.ios == IosCatalog.both) ...[
          const Gap(FwSpacing.sm),
          Text(
            scan.ios == IosCatalog.both
                ? 'An Icon Composer bundle and a classic asset catalog are both '
                      'present — Xcode uses one, decided by the target settings.'
                : 'iOS icons come from the Icon Composer bundle '
                      '${scan.iconBundles.join(', ')}; Xcode generates every '
                      'size at build time, so there are no per-size PNGs to '
                      'show.',
            style: type.caption.copyWith(color: colors.mut),
          ),
        ],
        if (scan.flavors.isNotEmpty) ...[
          const Gap(FwSpacing.lg),
          FlavorChips(
            flavors: scan.flavors,
            selected: selected,
            onSelect: onFlavor,
          ),
        ],
      ],
    );
  }
}
