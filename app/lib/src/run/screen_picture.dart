import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import '../inspect/focus_order.dart';
import '../inspect/node_highlight.dart';
import '../inspect/semantics_node.dart';
import '../ui/age.dart';
import '../ui/stage.dart';
import '../ui/design/design.dart';
import '../ui/theme.dart';

/// The picture, and the caption that goes with it.
///
/// The caption is tied to the decoded frame rather than to the bytes. It used
/// to be tied to `image != null`, and that misreported for as long as
/// the decode took: `Image.memory` resolves *asynchronously*, and a
/// `RenderImage` with nothing to draw yet takes `constraints.smallest` — zero,
/// under the loose constraints this column hands it. So the caption drew,
/// slid up to where the picture should have been, and described a picture that
/// was not on screen. Measured on macOS: 103ms against a painting app, and
/// unbounded against one that is not painting — a hidden or occluded window
/// schedules no frame, so the decoded picture had nothing to arrive on. That is
/// the state a Studio is in for the whole of an agent's drive session.
///
/// Handing it an already-decoded [ui.Image] removes the window rather than
/// narrowing it: there is no moment where this widget has bytes and no picture.
class RunScreenPicture extends StatelessWidget {
  const RunScreenPicture({
    super.key,
    required this.picture,
    required this.undecodable,
    required this.loading,
    required this.highlight,
    required this.tree,
    required this.canvas,
    this.semanticsHighlight,
    this.focusOrder,
    this.focusNodes,
    this.readAt,
    this.movedSince = false,
  });

  final ui.Image? picture;

  /// The app answered with bytes that are not an image. Worth its own word:
  /// silence here reads as "no picture yet", which is the one thing it is not.
  final bool undecodable;

  final bool loading;

  /// The hovered node's id — see [RunScreenPicture.highlight].
  final ValueNotifier<String?> highlight;

  /// The tree the picture was read with. **The same reading**, which is what
  /// makes a rect over a still picture exact here: the catalog's overlay has
  /// to prefer the guest's own last frame over the tree's rect, because there
  /// the picture is live and the tree is of the build it was read from. This
  /// picture is a photograph of that build.
  final InspectTree? tree;

  /// What the picture frames, in the app's logical pixels — see
  /// [canvasOf].
  final InspectLayout? canvas;

  /// The hovered semantics node, from the other tab. Its rect is already in
  /// the app's own logical pixels — the same space [InspectLayout] reports —
  /// so it scales onto the picture exactly as a widget's box does.
  final ValueNotifier<SemanticsSnapshotNode?>? semanticsHighlight;

  /// The Semantics tab's reading-order switch, and what to number while it is
  /// on. [focusNodes] is null unless that tab is the one showing, which is
  /// what stops the discs outliving the toggle that controls them.
  final ValueNotifier<bool>? focusOrder;
  final List<SemanticsSnapshotNode>? focusNodes;

  /// When the picture was taken. Null before the first reading lands.
  ///
  /// Said out loud because this pane is a photograph of a live app and looks
  /// exactly like a mirror of one. Everything else about the design — the
  /// button, the exact boxes over the picture — depends on the reader knowing
  /// which of the two they are looking at, and a picture cannot say so.
  final DateTime? readAt;

  /// The cockpit has since been told the app moved and has not re-read.
  ///
  /// Only ever true of a change somebody *told* the cockpit about — see
  /// `RunCore.screenClockOf`. False is "nothing has reported a change", never
  /// "the screen is up to date", which is why it softens the caption rather
  /// than replacing it.
  final bool movedSince;

  /// The box the picture frames, in the app's own logical pixels — the
  /// [canvas] every rect is scaled against.
  ///
  /// The topmost rect in the tree, and that is not a guess. The screenshot
  /// RPC is handed the size `getLayoutExplorerNode` reads off the root — which
  /// is a `RenderView` and reports none, so the size that reaches it is the
  /// first *child* that does, the app's own bounds. The guest walk gives its
  /// first `layout` to the same node, because `_layoutOf` answers only for a
  /// `RenderBox` and everything above that one is the view. So the picture
  /// shows exactly this rect, and every other rect in the tree is inside it.
  static InspectLayout? canvasOf(InspectTree? tree) {
    InspectLayout? find(InspectNode node) {
      if (node.layout case var layout?) return layout;
      for (var child in node.children) {
        if (find(child) case var layout?) return layout;
      }
      return null;
    }

    var root = tree?.root;
    return root == null ? null : find(root);
  }

  @override
  Widget build(BuildContext context) {
    // **The app is never the pane's background** — the studio's rule wherever
    // it shows you somebody else's app, arrived at in previews and the same
    // question here. A screenshot of a Flutter app drawn flush on a Flutter
    // panel is two apps sharing a design system with nothing between them: the
    // reader has to work out which `Reload` button is real. The ground and the
    // edge do that work, and they are the *same* ground and edge previews
    // draws, because two greys would read as two conventions.
    return Container(
      color: stageGroundColor(context.colors),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.all(stageInset),
      // Shrink-wrapped and top-aligned so the caption sits *under the
      // picture*, not at the bottom of whatever height the pane happens to
      // have. `Expanded` put it a screen away from what it describes.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (picture case var picture?) ...[
            Flexible(
              // The edge hugs the picture rather than the pane it is centred
              // in: `RawImage` under `BoxFit.contain` letterboxes inside
              // whatever box it is given, and a border on the box would frame
              // the empty margins with it.
              child: StageEdge(
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    RawImage(
                      image: picture,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _Overlay(
                          highlight: highlight,
                          semanticsHighlight: semanticsHighlight,
                          focusOrder: focusOrder,
                          focusNodes: focusNodes,
                          tree: tree,
                          canvas: canvas,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Gap(FwSpacing.sm),
            _Freshness(readAt: readAt, movedSince: movedSince),
            Text(
              'rendered by the app — platform views will not appear',
              textAlign: TextAlign.center,
              style: context.type.micro.copyWith(color: context.colors.mut3),
            ),
          ] else
            Text(
              switch ((loading, undecodable)) {
                // Never the empty string: a pane that draws nothing is
                // indistinguishable from a pane that is not there, and beside
                // the grip it reads as an unexplained rule down the page.
                (true, _) => 'Taking a picture…',
                (_, true) =>
                  'The app answered with a picture that decodes to nothing.',
                _ => 'No picture yet',
              },
              textAlign: TextAlign.center,
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
        ],
      ),
    );
  }
}

/// How old the picture is, and whether anything has reported a change since.
///
/// It keeps its own clock, and that is the point of it being a widget at all:
/// an age drawn once is wrong a second later, and rebuilding the pane around
/// it would re-lay-out a decoded image and a widget tree to move one word.
/// Nothing above this line rebuilds.
class _Freshness extends StatefulWidget {
  const _Freshness({required this.readAt, required this.movedSince});

  final DateTime? readAt;
  final bool movedSince;

  @override
  State<_Freshness> createState() => _FreshnessState();
}

class _FreshnessState extends State<_Freshness> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // A second, because the first ten of them are the ones a reader is
    // actually judging — after that the wording changes by the minute and an
    // extra rebuild costs a `Text`.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var age = ageOf(widget.readAt);
    if (age == null) return const SizedBox.shrink();
    var colors = context.colors;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'read $age'),
          if (widget.movedSince)
            TextSpan(
              text: ' · the app has moved since',
              style: TextStyle(color: colors.warningText),
            ),
        ],
      ),
      textAlign: TextAlign.center,
      style: context.type.micro.copyWith(color: colors.mut2),
    );
  }
}

/// What the inspector draws on the picture: the hovered node's box, from
/// whichever tab is hovering, and the reading order when that is asked for.
///
/// The rect is scaled here rather than under a `FittedBox`. The catalog paints
/// into a surface that *is* the guest's logical size, so its painter needs no
/// transform — but this picture is the app shrunk into part of a pane, and
/// scaling the painter would take the label down with it to three points. So
/// the host does what the painter's contract says the host does: decides which
/// rect, in the coordinates the painter draws in.
///
/// Width and height scale independently. They are the same number whenever the
/// picture frames the canvas, which is the case this is built for; if something
/// ever letterboxes the render, a box covering the same *fraction* of the
/// picture is a better wrong answer than one that has slid off it.
class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.highlight,
    required this.semanticsHighlight,
    required this.focusOrder,
    required this.focusNodes,
    required this.tree,
    required this.canvas,
  });

  final ValueNotifier<String?> highlight;
  final ValueNotifier<SemanticsSnapshotNode?>? semanticsHighlight;
  final ValueNotifier<bool>? focusOrder;
  final List<SemanticsSnapshotNode>? focusNodes;
  final InspectTree? tree;
  final InspectLayout? canvas;

  @override
  Widget build(BuildContext context) {
    if (canvas == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        var size = constraints.biggest;
        Widget paint(
          BuildContext context,
          String? lit,
          SemanticsSnapshotNode? sem,
        ) {
          // **Hover only, never the selection** — the rule the catalog's
          // overlay arrived at and for its reason: a box that stays after you
          // choose something is a box you then need a way to dismiss. What a
          // selection leaves behind is the detail pane, not a rectangle.
          var node = lit == null ? null : tree?.nodeAt(lit);
          // An offstage node wears the rect it had the last time it was on a
          // screen. Hovering its row lights the row and leaves the picture
          // alone.
          if (node?.offstage ?? false) node = null;
          // The elements highlight wins when both are set. The two tabs cannot
          // be hovered at once, so this only decides which stale one to drop.
          var (rect, label) = switch ((node?.layout, sem)) {
            (var layout?, _) => (scale(layout, canvas!, size), node!.type),
            (_, var hovered?) => (
              scaleRect(hovered.rect, canvas!, size),
              hovered.headline,
            ),
            _ => (null, null),
          };
          // Nothing rather than a painter with no rect in it: a hover that
          // found no box should leave the picture exactly as it was, and a
          // `CustomPaint` that paints nothing is still a thing on the screen
          // for anything reading this widget's output.
          if (rect == null) return const SizedBox.shrink();
          return CustomPaint(
            painter: NodeHighlightPainter(
              rect: rect,
              label: label,
              color: context.colors.accent,
            ),
          );
        }

        var box = ValueListenableBuilder(
          valueListenable: highlight,
          // Nested only where there is a second thing to listen to. A
          // placeholder notifier built here would be a new object every build,
          // subscribed to and dropped once a frame.
          builder: (context, lit, _) => switch (semanticsHighlight) {
            var semantic? => ValueListenableBuilder(
              valueListenable: semantic,
              builder: (context, sem, _) => paint(context, lit, sem),
            ),
            _ => paint(context, lit, null),
          },
        );

        if (focusOrder case var numbering?) {
          // Under the highlight rectangle, so hovering a row still points at
          // one box while the whole order is numbered.
          return ValueListenableBuilder(
            valueListenable: numbering,
            builder: (context, numbered, child) {
              var nodes = focusNodes;
              if (!numbered || nodes == null || nodes.isEmpty) return child!;
              var colors = context.colors;
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: FocusOrderPainter(
                      rects: [
                        for (var node in nodes)
                          scaleRect(node.rect, canvas!, size),
                      ],
                      color: colors.accent,
                      onColor: colors.onPrimary,
                      haloColor: colors.bg,
                    ),
                  ),
                  child!,
                ],
              );
            },
            child: box,
          );
        }
        return box;
      },
    );
  }

  /// [box] in the app's logical pixels, as a rect in a picture of [canvas]
  /// drawn at [size].
  static Rect? scale(InspectLayout box, InspectLayout canvas, Size size) {
    if (canvas.width <= 0 || canvas.height <= 0) return null;
    var x = size.width / canvas.width;
    var y = size.height / canvas.height;
    return Rect.fromLTWH(
      (box.x - canvas.x) * x,
      (box.y - canvas.y) * y,
      box.width * x,
      box.height * y,
    );
  }

  /// The same, for a rect that already is one — a semantics node's box, which
  /// arrives in the screen's logical coordinates rather than as an
  /// [InspectLayout].
  static Rect scaleRect(Rect box, InspectLayout canvas, Size size) {
    if (canvas.width <= 0 || canvas.height <= 0) return Rect.zero;
    var x = size.width / canvas.width;
    var y = size.height / canvas.height;
    return Rect.fromLTWH(
      (box.left - canvas.x) * x,
      (box.top - canvas.y) * y,
      box.width * x,
      box.height * y,
    );
  }
}
