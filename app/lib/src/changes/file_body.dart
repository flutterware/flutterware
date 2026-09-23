/// The bodies a diff cannot draw: an image (alone or against its base), a
/// markdown file rendered, an SVG previewed, an untracked file's own lines.
///
/// Every widget here takes bytes or strings and callbacks — loading is
/// [FileContentBuilder]'s job and deciding *which* body opens is the
/// screen's. The one shared manner: every reason a body cannot be drawn is
/// said in place, in words, because a pane that opens to silence reads as a
/// bug in the viewer.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/markdown_style.dart';
import '../ui/selectable_line.dart';
import '../ui/syntax.dart';
import '../ui/theme.dart';
import 'change_set.dart';
import 'diff_view.dart';
import 'file_contents.dart';
import 'patch_index.dart';

/// Loads one side's content and keeps the last answer while the next loads —
/// stale-then-fresh, the same policy as the screen that hosts it.
///
/// [signature] is the identity of the answer: when it changes, [load] runs
/// again. The new side's signature carries the probe's `readAt`, which is how
/// an in-place overwrite still reaches the screen even when the patch did not
/// move: the watcher fires, the probe stamps a new time, and the re-stat picks
/// up the new mtime.
class FileContentBuilder extends StatefulWidget {
  const FileContentBuilder({
    required this.signature,
    required this.load,
    required this.builder,
    super.key,
  });

  final Object signature;
  final Future<FileContent> Function() load;
  final Widget Function(BuildContext context, FileContent content) builder;

  @override
  State<FileContentBuilder> createState() => _FileContentBuilderState();
}

class _FileContentBuilderState extends State<FileContentBuilder> {
  FileContent? _content;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(FileContentBuilder old) {
    super.didUpdateWidget(old);
    if (old.signature != widget.signature) _reload();
  }

  void _reload() {
    var asked = widget.signature;
    unawaited(
      widget.load().then((content) {
        // A stale completion must not overwrite a fresher one: the signature
        // it answered may not be the signature the widget is now about.
        if (mounted && asked == widget.signature) {
          setState(() => _content = content);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) => switch (_content) {
    // The first frame of the first load. Nothing to be stale with, and a
    // spinner for a local read would flash more than it informs.
    null => const SizedBox.shrink(),
    var it => widget.builder(context, it),
  };
}

/// Why a body is not drawn, in the same voice as the diff's own notices.
class FileBodyNotice extends StatelessWidget {
  const FileBodyNotice(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(FwSpacing.xxl),
    child: Text(
      message,
      style: context.type.bodySmall.copyWith(color: context.colors.mut2),
    ),
  );
}

/// `640×480` needs the header, not the pixels: width and height without a
/// full decode, via the codec's own descriptor.
Future<(int, int)?> imageDimensions(Uint8List bytes) async {
  try {
    var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      var descriptor = await ui.ImageDescriptor.encoded(buffer);
      var size = (descriptor.width, descriptor.height);
      descriptor.dispose();
      return size;
    } finally {
      buffer.dispose();
    }
  } on Object {
    // Undecodable bytes: the cell's errorBuilder is already saying so.
    return null;
  }
}

/// `817 B`, `12.4 KB`, `3.1 MB` — the spelling every caption here uses.
String bytesLabel(int length) {
  if (length < 1024) return '$length B';
  if (length < 1024 * 1024) return '${(length / 1024).toStringAsFixed(1)} KB';
  return '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// An image's body: the working-tree side, the base side, or both.
///
/// Which sides exist is the status. Added and untracked have no base;
/// deleted has no working tree; modified and renamed have both and draw them
/// side by side — each captioned with its dimensions and byte size, which for
/// two versions of one asset is usually the whole answer.
class ImageChangeBody extends StatelessWidget {
  const ImageChangeBody({
    required this.store,
    required this.path,
    required this.status,
    this.oldPath,
    this.baseRevision,
    this.refreshedAt,
    this.leading = const [],
    super.key,
  });

  final FileContentStore store;
  final String path;
  final ChangeStatus status;

  /// Where the base side lives when this is a rename — the diff's other name.
  final String? oldPath;

  /// The revision the delta is measured from, or null when none resolved — in
  /// which case there is no base side to show and none is claimed.
  final String? baseRevision;

  /// When the probe last read the worktree; changing it re-stats the disk.
  final DateTime? refreshedAt;

  /// Comment threads and the composer, drawn above the pixels.
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    var revision = baseRevision;
    var showOld = status != ChangeStatus.added && revision != null;
    var showNew = status != ChangeStatus.deleted;

    Widget base() => FileContentBuilder(
      signature: ('base', revision, oldPath ?? path),
      load: () => store.atRevision(
        revision!,
        oldPath ?? path,
        maxBytes: ChangesLimits.imageContentBytes,
      ),
      builder: (context, content) => _ImageCell(
        content: content,
        label: showNew ? 'base' : 'base — deleted since',
        missingMessage: 'Not readable at the base revision.',
      ),
    );

    Widget now() => FileContentBuilder(
      signature: ('now', path, refreshedAt),
      load: () => store.onDisk(path, maxBytes: ChangesLimits.imageContentBytes),
      builder: (context, content) => _ImageCell(
        content: content,
        label: showOld ? 'now' : null,
        missingMessage: 'No longer on disk.',
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        ...leading,
        if (showOld && showNew)
          LayoutBuilder(
            // Side by side is the point of a differ, but two 200 px thumbnails
            // are not a comparison — below that the sides stack.
            builder: (context, constraints) => constraints.maxWidth >= 640
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: base()),
                      const Gap(FwSpacing.lg),
                      Expanded(child: now()),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [base(), const Gap(FwSpacing.lg), now()],
                  ),
          )
        else if (showOld)
          base()
        else
          now(),
      ],
    );
  }
}

/// One image with its caption: label, dimensions, byte size.
class _ImageCell extends StatefulWidget {
  const _ImageCell({
    required this.content,
    required this.missingMessage,
    this.label,
  });

  final FileContent content;
  final String? label;

  /// What a [FileMissing] means on this side, which is different on each.
  final String missingMessage;

  @override
  State<_ImageCell> createState() => _ImageCellState();
}

class _ImageCellState extends State<_ImageCell> {
  (int, int)? _dimensions;
  Uint8List? _measuredBytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(_ImageCell old) {
    super.didUpdateWidget(old);
    _measure();
  }

  void _measure() {
    if (widget.content case FileBytes(:var bytes)
        when !identical(bytes, _measuredBytes)) {
      _measuredBytes = bytes;
      unawaited(
        imageDimensions(bytes).then((size) {
          if (mounted && identical(bytes, _measuredBytes)) {
            setState(() => _dimensions = size);
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var muted = context.type.micro.copyWith(color: colors.mut2);
    return switch (widget.content) {
      FileMissing() => Text(widget.missingMessage, style: muted),
      FileTooLarge(:var length) => Text(
        'This image is ${bytesLabel(length)} — past what the viewer decodes.',
        style: muted,
      ),
      FileBytes(:var bytes) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 360,
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            // The checkerboard is what says *this part is transparent* — on a
            // plain panel an alpha edge and a white edge are the same edge.
            child: CustomPaint(
              painter: _CheckerboardPainter(
                colors.line.withValues(alpha: 0.35),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(FwSpacing.sm),
                  // **scaleDown, never contain.** Contain upscales, and a
                  // 16 px icon blown to 360 px is a statement about the
                  // viewer, not the asset.
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.scaleDown,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) =>
                        Text('Could not decode this image.', style: muted),
                  ),
                ),
              ),
            ),
          ),
          const Gap(FwSpacing.xs),
          Row(
            children: [
              if (widget.label case var it?) ...[
                Text(it, style: context.type.micro),
                const Gap(FwSpacing.md),
              ],
              if (_dimensions case (var width, var height)) ...[
                Text('$width×$height', style: muted),
                const Gap(FwSpacing.md),
              ],
              Text(bytesLabel(bytes.length), style: muted),
            ],
          ),
        ],
      ),
    };
  }
}

class _CheckerboardPainter extends CustomPainter {
  _CheckerboardPainter(this.color);

  final Color color;

  static const _square = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()..color = color;
    for (var y = 0; y * _square < size.height; y++) {
      for (var x = y.isEven ? 0 : 1; x * _square < size.width; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH(x * _square, y * _square, _square, _square),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter old) => color != old.color;
}

/// A markdown file, rendered — the body a *new* markdown file defaults to,
/// where a wall of `+` lines says "prose changed" and nothing else.
class MarkdownFileBody extends StatelessWidget {
  const MarkdownFileBody({
    required this.content,
    required this.imageDirectory,
    this.leading = const [],
    super.key,
  });

  final String content;

  /// The absolute directory a relative image reference resolves against —
  /// the file's own directory in the worktree, with a trailing slash.
  final String imageDirectory;

  final List<Widget> leading;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.xxl,
      vertical: FwSpacing.lg,
    ),
    children: [
      ...leading,
      Align(
        alignment: Alignment.topLeft,
        // Capped the way every prose surface caps: a heading measured against
        // a 1400 px window is not a line anybody can read back.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: MarkdownBody(
            data: content,
            styleSheet: markdownStyleSheet(context),
            imageBuilder: (uri, title, alt) =>
                _MarkdownImage(uri: uri, directory: imageDirectory, alt: alt),
            onTapLink: (text, href, title) {
              if (href == null) return;
              var uri = Uri.tryParse(href);
              // Only a link that names where it goes. A relative one points
              // into the worktree, and opening source files is the editor's
              // job, not this pane's.
              if (uri != null && uri.hasScheme) unawaited(launchUrl(uri));
            },
          ),
        ),
      ),
    ],
  );
}

/// One image reference inside rendered markdown.
///
/// Not the package's default builder, for one reason: that one has no error
/// handling, so a reference to an image that is not there — entirely normal
/// in a README written against a website's asset pipeline — paints the
/// framework's error box across the prose. A broken reference here is a fact
/// about the file, and it is stated as one.
class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({required this.uri, required this.directory, this.alt});

  final Uri uri;
  final String directory;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    Widget broken(BuildContext context, Object error, StackTrace? stack) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: FwIconSize.sm,
          color: context.colors.mut3,
        ),
        const Gap(FwSpacing.xs),
        Flexible(
          child: Text(
            alt?.isNotEmpty ?? false ? '${alt!} — $uri' : '$uri',
            style: context.type.micro.copyWith(color: context.colors.mut2),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );

    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Image.network(
        uri.toString(),
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        errorBuilder: broken,
      );
    }
    if (uri.scheme == 'data') {
      var bytes = uri.data?.contentAsBytes();
      if (bytes == null) return broken(context, 'not decodable', null);
      return Image.memory(
        bytes,
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        errorBuilder: broken,
      );
    }
    var spelled = uri.toString();
    return Image.file(
      File(spelled.startsWith('/') ? spelled : '$directory$spelled'),
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      errorBuilder: broken,
    );
  }
}

/// An SVG, drawn. Behind the header toggle rather than a default: an SVG is
/// text first — it diffs — and rendering it is the second question.
class SvgFileBody extends StatelessWidget {
  const SvgFileBody({required this.bytes, this.leading = const [], super.key});

  final Uint8List bytes;
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        ...leading,
        Align(
          alignment: Alignment.topLeft,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: CustomPaint(
              painter: _CheckerboardPainter(
                colors.line.withValues(alpha: 0.35),
              ),
              child: Padding(
                padding: const EdgeInsets.all(FwSpacing.sm),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 720,
                    maxHeight: 420,
                  ),
                  child: SvgPicture.memory(
                    bytes,
                    fit: BoxFit.scaleDown,
                    errorBuilder: (context, error, stack) => Text(
                      'Could not render this SVG.',
                      style: context.type.micro.copyWith(color: colors.mut2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Gap(FwSpacing.xs),
        Text(
          bytesLabel(bytes.length),
          style: context.type.micro.copyWith(color: colors.mut2),
        ),
      ],
    );
  }
}

/// What a row of [TextFileBody] spends before its text starts. Named for the
/// same reason as `diffChromeWidth`: the pane subtracts it to know how wide
/// the text column is.
const textChromeWidth = CommentMargin.width + 44 + FwSpacing.sm + FwSpacing.lg;

/// The lines of a file git has no other side for. One gutter, no markers, no
/// tint: "every line is new" is the *index's* claim; drawing three hundred
/// green rows would repeat it at the reader for the length of the file.
///
/// **Everything else about a line is the same as in a diff**, and deliberately
/// so: the syntax colours come from the same tokeniser, the `+` in the margin
/// is the same [CommentMargin], and a thread drawn under a line sits where the
/// diff puts it. Whether an agent happened to run `git add` before you looked
/// decides what git can tell us about a file — it does not decide what you can
/// do with the file on your screen.
///
/// The same discipline as the diff body: fixed-height monospace rows in a
/// virtualised list, never wrapped, translated by one shared [DiffScrollX].
class TextFileBody extends StatelessWidget {
  const TextFileBody({
    required this.lines,
    required this.scrollX,
    required this.charWidth,
    this.tokens,
    this.controller,
    this.leading = const [],
    this.placed = const {},
    this.selected = const {},
    this.onComment,
    super.key,
  });

  final List<String> lines;
  final DiffScrollX scrollX;

  /// One character's advance in [diffTextStyle], measured once by the pane.
  final double charWidth;

  /// This file's lines, tokenised on demand — null for a file whose language
  /// nothing here reads, which draws exactly as it always did.
  ///
  /// Held by the pane rather than built here: it caches parsed chunks, and a
  /// cache rebuilt with the widget would be thrown away on every re-probe.
  final LazyLineTokens? tokens;

  final ScrollController? controller;

  /// Drawn above line 1 — what is about the file rather than about a line of
  /// it, and any note whose line this file no longer has.
  final List<Widget> leading;

  /// Threads and the composer, by the 1-based line they are drawn **under**.
  final Map<int, List<Widget>> placed;

  /// Lines inside the span the open composer is about, so you can see what you
  /// picked while you write about it.
  final Set<int> selected;

  /// Called with a 1-based line number when its `+` is pressed. Null on a host
  /// with no review — the catalog's demo, and a widget test pumping a body.
  final ValueChanged<int>? onComment;

  @override
  Widget build(BuildContext context) {
    // One flat row list, the way the diff body builds one: a virtualised list
    // needs every row addressable by index without building the ones above it,
    // and a comment is a variable-height row among fixed-height ones.
    var rows = <Object>[
      ...leading,
      for (var number = 1; number <= lines.length; number++) ...[
        number,
        ...?placed[number],
      ],
    ];
    return SelectionArea(
      child: ListView.builder(
        controller: controller,
        itemCount: rows.length,
        itemBuilder: (context, index) => switch (rows[index]) {
          int number => _TextLineView(
            number: number,
            text: lines[number - 1],
            tokens: tokens?.at(number - 1),
            scrollX: scrollX,
            charWidth: charWidth,
            selected: selected.contains(number),
            onComment: onComment == null ? null : () => onComment!(number),
          ),
          var widget => widget as Widget,
        },
      ),
    );
  }
}

class _TextLineView extends StatefulWidget {
  const _TextLineView({
    required this.number,
    required this.text,
    required this.tokens,
    required this.scrollX,
    required this.charWidth,
    required this.selected,
    required this.onComment,
  });

  final int number;
  final String text;
  final List<Token>? tokens;
  final DiffScrollX scrollX;
  final double charWidth;
  final bool selected;
  final VoidCallback? onComment;

  @override
  State<_TextLineView> createState() => _TextLineViewState();
}

class _TextLineViewState extends State<_TextLineView> {
  /// Hover, for the same reason as the diff's row: the row holds selectable
  /// text, so only the margin is pressable and hover is what reveals it.
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    var style = diffTextStyle(context);
    var colors = context.colors;
    // Reported from `build`, which is why [DiffScrollX.see] does not notify.
    widget.scrollX.see(widget.text.length * widget.charWidth);
    return MouseRegion(
      onEnter: (_) {
        if (widget.onComment != null) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Container(
        color: widget.selected ? colors.accentSoft : null,
        padding: const EdgeInsets.only(right: FwSpacing.lg),
        // The diff body's argument, unchanged: one line for the purpose of a
        // selection, and the line number is furniture rather than content.
        child: FwSelectableLine(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommentMargin(
                visible: _hovered,
                onTap: widget.onComment,
                style: style,
              ),
              SelectionContainer.disabled(
                child: SizedBox(
                  width: 44,
                  child: Text(
                    '${widget.number}',
                    textAlign: TextAlign.right,
                    style: style.copyWith(color: colors.mut3),
                  ),
                ),
              ),
              const Gap(FwSpacing.sm),
              Expanded(
                // The same translate-inside-a-clip as the diff's `_Code`, and
                // for the same reason: every row must move by the same amount
                // or the indentation stops lining up.
                child: SizedBox(
                  height: diffLineHeight(style),
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: widget.scrollX,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(-widget.scrollX.x, 0),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: double.infinity,
                          child: child,
                        ),
                      ),
                      child: switch (widget.tokens) {
                        var it? => Text.rich(
                          TextSpan(
                            children: spansFor(context, it, style: style),
                          ),
                          style: style,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                        ),
                        null => Text(
                          widget.text,
                          style: style,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                        ),
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
