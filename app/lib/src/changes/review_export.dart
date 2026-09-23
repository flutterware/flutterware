/// Taking the outstanding notes somewhere else.
///
/// The markdown is the artefact; the routes are two ways of moving it. The
/// clipboard and a file render the identical text — see [reviewMarkdown] — so
/// there is one format to keep readable, one to test, and no way for the thing
/// you previewed to differ from the thing that left.
///
/// Exporting changes nothing on its own. It used to be the gesture that
/// closed a batch, back when the recipient was a colleague in another window
/// and *it left* was the only fact we could honestly record. The recipient is
/// now usually an agent inside this checkout, which reads the log itself and
/// resolves what it deals with — so what leaves here goes to the reader
/// flutterware cannot reach, and whether that reader acted on it is not
/// something a clipboard write knows.
///
/// Hence [ExportResult.resolve], offered afterwards rather than assumed. It is
/// not the *Clear* button this feature has always refused: that one stood on
/// the screen as a way to empty a list, making *I dealt with these* and *I gave
/// up on these* one gesture. This one is bounded to the notes you just
/// exported, at the moment you exported them.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'review_comment.dart';

/// How the notes left.
enum ExportRoute {
  /// Onto the clipboard, to be pasted into a chat.
  copy,

  /// Written to a file the reader can be pointed at.
  file,
}

/// What the sheet did, or null if it was cancelled.
typedef ExportResult = ({ExportRoute route, bool resolve});

/// Asks how the notes should go, shows what will leave, and does it.
///
/// Returns null when nothing left — cancelled, or a save the user backed out
/// of. The caller acts only on a non-null answer, so an abandoned save cannot
/// silently resolve six notes that never went anywhere.
Future<ExportResult?> showExportSheet(
  BuildContext context, {
  required String markdown,
  required int count,
  required String worktree,
  String? base,
}) => showDialog<ExportResult>(
  context: context,
  builder: (context) => _ExportSheet(
    markdown: markdown,
    count: count,
    worktree: worktree,
    base: base,
  ),
);

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({
    required this.markdown,
    required this.count,
    required this.worktree,
    this.base,
  });

  final String markdown;
  final int count;
  final String worktree;
  final String? base;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  var _route = ExportRoute.copy;
  var _busy = false;

  /// Whether to tick the exported notes off on the way out.
  ///
  /// Off by default, because the common reader is the agent in this
  /// checkout, which resolves what it deals with and says what it did — and
  /// pre-resolving would throw that answer away before it was written. You turn
  /// it on for the case it is for: a reader that will never report back.
  var _resolve = false;

  /// What went wrong, shown in place.
  ///
  /// An export that fails silently is the worst outcome here: the sheet would
  /// simply sit there, and the obvious reading of that is *the button does not
  /// work*. A disk that is full and a clipboard channel that is not answering
  /// are both things the person in front of it can act on.
  String? _failure;

  Future<void> _go() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      switch (_route) {
        case ExportRoute.copy:
          await Clipboard.setData(ClipboardData(text: widget.markdown));
          if (mounted) {
            Navigator.of(context)
                .pop((route: ExportRoute.copy, resolve: _resolve));
          }
        case ExportRoute.file:
          var location = await getSaveLocation(
            suggestedName: _suggestedName(widget.worktree),
            acceptedTypeGroups: const [
              XTypeGroup(label: 'Markdown', extensions: ['md']),
            ],
          );
          // Backing out of the picker is backing out of the export. Resolving
          // here would tick off notes that went nowhere.
          if (location == null) {
            if (mounted) setState(() => _busy = false);
            return;
          }
          await File(location.path).writeAsString(widget.markdown);
          if (mounted) {
            Navigator.of(context)
                .pop((route: ExportRoute.file, resolve: _resolve));
          }
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // [AlertDialog], like the teardown and web-export dialogs: this was a bare
    // [Dialog] with a hand-built title block and a hand-built action row, so
    // the app's three dialogs sat at three corner radii with three button
    // treatments.
    return AlertDialog(
      backgroundColor: colors.bg,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export ${widget.count} '
            '${widget.count == 1 ? 'comment' : 'comments'}',
            style: context.type.heading,
          ),
          const Gap(FwSpacing.xxs),
          Text(
            [
              widget.worktree,
              if (widget.base case var it?) 'against $it',
            ].join('  ·  '),
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Channel(
              on: _route == ExportRoute.copy,
              title: 'Copy as markdown',
              body: 'Paste it straight into a chat.',
              onTap: () => setState(() => _route = ExportRoute.copy),
            ),
            const Gap(FwSpacing.md),
            _Channel(
              on: _route == ExportRoute.file,
              title: 'Save to a file…',
              body:
                  'Point a reader at the path. Save it outside the checkout '
                  'unless you want it showing up as an untracked row on this '
                  'very screen.',
              onTap: () => setState(() => _route = ExportRoute.file),
            ),
            const Gap(FwSpacing.xl),
            const _Label('What leaves'),
            const Gap(FwSpacing.sm),
            // **What leaves, shown before it leaves.** A handoff you cannot
            // preview is one you re-check by pasting it somewhere else first.
            //
            // **Flexible, then capped** — not capped alone. A flat 300 px is a
            // height the dialog does not have in a 600 px window, and the
            // overflow it caused was the preview pushing the buttons off the
            // bottom: the one part of the sheet that may not go missing.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  decoration: BoxDecoration(
                    color: colors.panel2,
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusSmall,
                    ),
                    border: Border.all(color: colors.line),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      widget.markdown,
                      style: context.type.mono.copyWith(
                        color: colors.mut,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Gap(FwSpacing.lg),
            // **A choice, not a promise.** The line here used to say what the
            // handoff was about to do to the list; there is nothing to say now,
            // because exporting does nothing to it unless you ask.
            Tappable.builder(
              onTap: () => setState(() => _resolve = !_resolve),
              builder: (context, hovered) => Row(
                children: [
                  Icon(
                    _resolve
                        ? Icons.check_box_outlined
                        : Icons.check_box_outline_blank,
                    size: FwIconSize.md,
                    color: _resolve
                        ? colors.accent
                        : hovered
                        ? colors.mut
                        : colors.mut3,
                  ),
                  const Gap(FwSpacing.sm),
                  Flexible(
                    child: Text(
                      'Resolve them too — no reply comes back',
                      style: context.type.caption.copyWith(
                        color: _resolve ? colors.ink : colors.mut2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_failure case var failure?) ...[
              const Gap(FwSpacing.sm),
              Text(
                failure,
                style: context.type.caption.copyWith(color: colors.red),
              ),
            ],
          ],
        ),
      ),
      actions: [
        Tappable.builder(
          onTap: () => Navigator.of(context).pop(),
          builder: (context, hovered) => Padding(
            padding: const EdgeInsets.all(FwSpacing.sm),
            child: Text(
              'Cancel',
              style: context.type.caption.copyWith(
                color: hovered ? colors.ink : colors.mut2,
              ),
            ),
          ),
        ),
        const Gap(FwSpacing.md),
        // The house primary — the same one the composer and the Review footer
        // wear. This was the last solid accent fill in the feature, which made
        // the loudest object on the screen the confirmation of an action you
        // had already chosen.
        Tappable.builder(
          onTap: _busy ? null : () => unawaited(_go()),
          builder: (context, hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xl,
              vertical: FwSpacing.md,
            ),
            decoration: BoxDecoration(
              color: _busy
                  ? null
                  : hovered
                  ? colors.accentSoft2
                  : colors.accentSoft,
              borderRadius: BorderRadius.circular(context.radii.radius),
              border: Border.all(color: _busy ? colors.line : colors.accent),
            ),
            child: Text(
              _busy ? 'Exporting…' : 'Export',
              style: context.type.caption.copyWith(
                color: _busy ? colors.mut3 : colors.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A heading inside the sheet. Uppercase `fieldLabel`, the app's section voice.
class _Label extends StatelessWidget {
  const _Label(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label.toUpperCase(),
    style: context.type.fieldLabel.copyWith(color: context.colors.mut),
  );
}

/// One of the two ways the notes can leave.
///
/// A card, not a band. The chosen one was a full-bleed accent stripe across
/// the dialog and the other was bare text on the background, so the two options
/// did not look like two of anything — only the radio glyph said they were a
/// pair. Bordered and inset, they are the same object in two states, which is
/// what a choice looks like.
class _Channel extends StatelessWidget {
  const _Channel({
    required this.on,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final bool on;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: on ? colors.accentSoft : null,
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: on ? colors.accent : colors.line),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.lg,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: FwIconSize.md,
                color: on ? colors.accent : colors.mut3,
              ),
            ),
            const Gap(FwSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.type.bodySmall.copyWith(
                      color: on ? colors.accent : colors.ink,
                    ),
                  ),
                  const Gap(FwSpacing.xxs),
                  Text(
                    body,
                    style: context.type.caption.copyWith(color: colors.mut2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `review-<worktree>.md`, with anything a filesystem would object to replaced.
String _suggestedName(String worktree) {
  var cleaned = worktree.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return 'review-${cleaned.isEmpty ? 'changes' : cleaned}.md';
}
