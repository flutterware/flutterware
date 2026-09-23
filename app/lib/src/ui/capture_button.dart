import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/image_clipboard.dart';
import 'menu.dart';
import 'split_button.dart';

/// One picture a [CaptureButton] can take.
///
/// The button owns everything that is the same wherever a picture is offered —
/// the clipboard, the save dialog, the busy guard, the tick, the snackbar — and
/// a target is everything that is not: what to photograph and what to call it.
/// The previews panel asks a live guest for its next frame, a scenario step
/// reads a file that already exists, the run cockpit already holds the bytes;
/// all three are a [capture] closure from here.
class CaptureTarget {
  const CaptureTarget({
    required this.label,
    required this.capture,
    required this.suggestedName,
    this.onHover,
  });

  /// What the picture is of, mid-sentence: `'the preview'`,
  /// `'just "ElevatedButton"'`. Menu rows, tooltips and failure snackbars all
  /// compose around it.
  final String label;

  /// The pixels, PNG-encoded. Null is a refusal rather than an error — there
  /// is nothing on screen to be a picture of — and ends the gesture quietly.
  final Future<Uint8List?> Function() capture;

  /// What the save dialog offers to call the file.
  final String Function() suggestedName;

  /// The pointer entering or leaving this target's menu rows — for lighting
  /// the node a cropped target names, so the menu shows what it would take a
  /// picture of before anything is clicked.
  final ValueChanged<bool>? onHover;
}

/// Copy the picture, with the rest behind a chevron.
///
/// One primary action instead of the two side-by-side buttons this replaces:
/// the click (and whatever shortcut the host wires to [CaptureButtonState.copy])
/// always takes [CaptureButton.primary] — the whole frame, every time. The
/// openable part carries "Save as PNG…" and the [CaptureButton.secondary]
/// targets, each named after what it captures, so a mode the old buttons
/// switched into silently is now a menu row that says what it does.
///
/// Where copying an image is not implemented ([ImageClipboard.isSupported]),
/// saving is the primary action rather than a dead button over a live menu.
class CaptureButton extends StatefulWidget {
  const CaptureButton({
    super.key,
    required this.primary,
    this.secondary = const [],
    this.enabled = true,
    this.shortcutHint,
  });

  /// What a plain click captures.
  final CaptureTarget primary;

  /// Explicit alternatives, menu-only — today the previews panel's "just this
  /// node". Empty for surfaces with exactly one picture to offer.
  final List<CaptureTarget> secondary;

  final bool enabled;

  /// The host's copy shortcut, shown on the tooltip and the menu row —
  /// `'⌘⇧C'`. The binding itself is the host's: it is the host's shortcut,
  /// this just stops it from being a secret.
  final String? shortcutHint;

  @override
  State<CaptureButton> createState() => CaptureButtonState();
}

/// Public for the one host that wires a keyboard shortcut to [copy] — the
/// button then shows the same tick a click would, so the shortcut and the
/// click are one action rather than two that happen to agree.
class CaptureButtonState extends State<CaptureButton> {
  /// Set while a capture is in flight, so a second gesture cannot start one on
  /// top of it — the two would write the same scratch path.
  var _busy = false;

  /// Flips the icon to a tick for a moment. The bar has no room for a message,
  /// and a button that looks identical before and after is a button you press
  /// twice.
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  Future<Uint8List?> _capture(CaptureTarget target) async {
    setState(() => _busy = true);
    try {
      return await target.capture();
    } catch (e) {
      if (mounted) _complain(target, '$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Copies [target] ([CaptureButton.primary] when unnamed) to the clipboard —
  /// the host's shortcut lands here too.
  Future<void> copy([CaptureTarget? target]) async {
    if (_busy || !ImageClipboard.isSupported) return;
    var subject = target ?? widget.primary;
    var png = await _capture(subject);
    if (png == null || !mounted) return;
    try {
      await ImageClipboard.setPng(png);
      if (!mounted) return;
      _copied?.cancel();
      setState(() {});
      _copied = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) _complain(subject, '$e');
    }
  }

  Future<void> _save(CaptureTarget target) async {
    if (_busy) return;
    var png = await _capture(target);
    if (png == null || !mounted) return;
    var location = await getSaveLocation(
      suggestedName: target.suggestedName(),
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG image', extensions: ['png']),
      ],
    );
    if (location == null) return;
    try {
      await File(location.path).writeAsBytes(png);
    } catch (e) {
      if (mounted) _complain(target, '$e');
    }
  }

  /// Failures only. A capture that worked reports itself by changing the icon;
  /// one that did not has a reason, and a reason needs words.
  void _complain(CaptureTarget target, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not capture ${target.label}: $message')),
      );

  List<MenuEntry> _entries() {
    var canCopy = ImageClipboard.isSupported;
    var enabled = widget.enabled && !_busy;
    return [
      for (var (index, target) in [
        widget.primary,
        ...widget.secondary,
      ].indexed) ...[
        if (index > 0) const MenuDivider(),
        if (canCopy)
          MenuItem(
            'Copy ${target.label}',
            icon: Icons.content_copy,
            shortcut: index == 0 ? widget.shortcutHint : null,
            onSelected: enabled ? () => unawaited(copy(target)) : null,
            onHover: target.onHover,
          ),
        MenuItem(
          'Save ${target.label} as PNG…',
          icon: Icons.save_alt,
          onSelected: enabled ? () => unawaited(_save(target)) : null,
          onHover: target.onHover,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    var canCopy = ImageClipboard.isSupported;
    var enabled = widget.enabled && !_busy;
    var justCopied = _copied?.isActive ?? false;
    var hint = widget.shortcutHint;

    return FwSplitButton.icon(
      icon: justCopied
          ? Icons.check
          : canCopy
          ? Icons.content_copy
          : Icons.save_alt,
      tooltip: canCopy
          ? 'Copy ${widget.primary.label}${hint == null ? '' : ' ($hint)'}'
          : 'Save ${widget.primary.label} as PNG',
      menuTooltip: 'More ways to capture',
      onPressed: enabled
          ? () => unawaited(canCopy ? copy() : _save(widget.primary))
          : null,
      entries: _entries(),
      // Dismissal unmounts the rows under the pointer, so no exit event
      // reaches whichever target was previewing its hover.
      onMenuClose: () {
        for (var target in [widget.primary, ...widget.secondary]) {
          target.onHover?.call(false);
        }
      },
    );
  }
}
