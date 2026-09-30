/// **Everything that happens to a frame after something has drawn one.**
///
/// Which engine drew it stops mattering here, and that is the whole reason
/// this is its own file. A crop and an annotation look like guest features and
/// are not: they resolve against an `InspectTree` and then push pixels around
/// with `package:image`, and neither half touches a socket, a daemon or a
/// binding. What is left in `frame_capture.dart` is the part that genuinely is
/// the embedder's — the capture request, the ack, and the `.rawframe` layout
/// its C host writes.
///
/// So a `flutter_tester` frame goes through exactly this: it arrives as packed
/// rgba with its dimensions in the reply rather than as BGRA behind a
/// twelve-byte header, and from the decode onwards there is one pipeline and
/// one answer to "what does `--node` mean".
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

// The node types, not the umbrella `ui_catalog.dart`: that one reaches
// `package:flutter/widgets.dart`, and this file is on `fw`'s import graph.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

/// What `--node` and `--annotate` mean against one tree: a rect to crop to, and
/// the boxes to draw.
///
/// One implementation, because there were briefly two. `observe` was written
/// with a copy of `capture`'s version — the same lookup, the same two error
/// messages, byte for byte — which is precisely the drift that produced every
/// other defect this file carries a note about: `settledAxes` beside
/// `_readAxes`, the panel's tolerant writes, `setParameter` surviving a rename.
/// A rule about what a node id means belongs in one place.
class PictureFraming {
  const PictureFraming({this.crop, this.boxes = const []});

  /// Resolves [node] and [annotate] against [tree], refusing rather than
  /// approximating: an id that names nothing, and a widget with no box of its
  /// own, are different mistakes and each gets its own answer.
  factory PictureFraming.of(
    InspectTree tree, {
    required String? node,
    required bool annotate,
    required String entryId,
  }) {
    InspectLayout? crop;
    if (node != null && node.isNotEmpty) {
      crop = _cropTo(tree, node, entryId);
    }
    return PictureFraming(
      crop: crop,
      boxes: annotate ? tree.nodes.toList() : const [],
    );
  }

  /// The box [selector] names — **a widget's name, or a tree id**.
  ///
  /// The name is what this is for, and the id is the fallback rather than the
  /// other way round. Asking for a picture of a widget you are working on is
  /// the common case by a distance, and requiring an id made it a two-step:
  /// read a tree, find the position, ask again — thousands of tokens to
  /// photograph something the caller could already name. `SplitButton` is what
  /// somebody has in their hand.
  ///
  /// Matched by [InspectTree.matching], which is the same matcher `find` uses,
  /// so one grammar covers looking something up and cropping to it.
  ///
  /// Several places are refused, never guessed. A silently-picked first
  /// match is a picture of the wrong widget that looks like a picture of the
  /// right one, and the refusal carries the ids so the next call is exact.
  /// Matches nested in one another are one place — see
  /// [InspectTree.places], which is the rule the harness scrolls by too.
  static InspectLayout _cropTo(
    InspectTree tree,
    String selector,
    String entryId,
  ) {
    var matches = tree.places(selector);
    if (matches.length == 1) return _boxOf(matches.single, selector, entryId);
    if (matches.isEmpty) {
      throw ArgumentError.value(
        selector,
        'node',
        'nothing in $entryId is called that, and it is not the id of a node '
            'either. `node` takes a widget name — `SplitButton`, `Save` — '
            'matched against every type, description and label on screen, or '
            'an id from a tree read. Read the entry without `node` to see '
            'what is there.',
      );
    }
    var named = matches
        .take(8)
        .map((node) => '${node.type} (${node.id})')
        .join(', ');
    throw ArgumentError.value(
      selector,
      'node',
      '${matches.length} widgets match "$selector" in $entryId, and cropping '
          'to the wrong one produces a picture that looks right: $named'
          '${matches.length > 8 ? ', …' : ''}. Name one by its id, or narrow '
          'the text.',
    );
  }

  static InspectLayout _boxOf(InspectNode found, String named, String entryId) {
    var box = found.layout;
    if (box == null) {
      throw ArgumentError.value(
        named,
        'node',
        '${found.type} has no box of its own to crop to. Providers and '
            'builders lay nothing out; ask for one of its children.',
      );
    }
    return box;
  }

  final InspectLayout? crop;
  final List<InspectNode> boxes;
}

/// The frame, cut to one node's box.
///
/// Cropped out of the real composited frame rather than re-rendered in
/// isolation, which is what `ext.flutter.inspector.screenshot` would do: a
/// widget photographed away from its surroundings is a different picture, and
/// usually not the one the question was about.
///
/// Clamped to the frame, because a node may legitimately sit partly outside it
/// — that is what an overflow *is* — and a crop that threw would refuse to show
/// the one case worth looking at.
img.Image cropToNode(img.Image image, InspectLayout rect, double ratio) {
  var x = (rect.x * ratio).round().clamp(0, image.width - 1);
  var y = (rect.y * ratio).round().clamp(0, image.height - 1);
  return img.copyCrop(
    image,
    x: x,
    y: y,
    width: (rect.width * ratio).round().clamp(1, image.width - x),
    height: (rect.height * ratio).round().clamp(1, image.height - y),
  );
}

/// A box and an id over each node.
///
/// The point is the id: an agent reads a tree, gets `0/1/2`, and then gets a
/// picture with `0/1/2` written on the thing it names. Without that the tree
/// and the screenshot are two observations of the same frame with nothing
/// joining them.
img.Image annotateNodes(
  img.Image image,
  List<InspectNode> nodes,
  double ratio,
) {
  for (var node in _distinctBoxes(nodes)) {
    if (node.layout case var layout?) {
      var x = (layout.x * ratio).round();
      var y = (layout.y * ratio).round();
      var w = (layout.width * ratio).round();
      var h = (layout.height * ratio).round();
      img.drawRect(
        image,
        x1: x,
        y1: y,
        x2: x + w - 1,
        y2: y + h - 1,
        color: img.ColorRgb8(255, 0, 128),
      );
      var label = node.id.isEmpty ? 'root' : node.id;
      // A filled strip behind it: these are drawn over a rendered UI, and
      // magenta-on-whatever-was-there is not always legible.
      var labelX = x + 2;
      var labelY = y < 16 ? y + 2 : y - 15;
      img.fillRect(
        image,
        x1: labelX - 1,
        y1: labelY - 1,
        x2: labelX + label.length * 8,
        y2: labelY + 14,
        color: img.ColorRgb8(255, 0, 128),
      );
      img.drawString(
        image,
        label,
        font: img.arial14,
        x: labelX,
        y: labelY,
        color: img.ColorRgb8(255, 255, 255),
      );
    }
  }
  return image;
}

/// One node per distinct box, outermost kept.
///
/// Most of a summary tree lays nothing out of its own: a provider, a builder
/// and the widget under them share one rect, so drawing every node draws the
/// same rectangle six times and stacks six labels on one corner. The first
/// version did exactly that and was unreadable — which is the difference
/// between a feature that exists and one that answers the question.
///
/// Outermost wins because it is the shorter id and the one a caller is more
/// likely to have meant; the inner ones are still in the tree for anyone who
/// wants them.
List<InspectNode> _distinctBoxes(List<InspectNode> nodes) {
  var seen = <String>{};
  return [
    for (var node in nodes)
      if (node.layout case var l?)
        if (seen.add('${l.x},${l.y},${l.width},${l.height}')) node,
  ];
}

/// A `flutter_tester` frame, decoded.
///
/// The other end of the same pipeline, and the difference between the two
/// engines in one function. The embedder's C host writes a `.rawframe` —
/// twelve bytes of header, BGRA, a stride that may exceed the width
/// (`raw_frame.dart`). The harness writes what `Image.toByteData` gives it:
/// packed RGBA, no header, no padding, with the dimensions in the reply that
/// named the file. From here on there is one pipeline.
img.Image decodeTesterFrame(
  Uint8List bytes, {
  required int width,
  required int height,
}) {
  var expected = width * height * 4;
  if (bytes.length != expected) {
    throw FormatException(
      'a $width×$height rgba frame is $expected bytes; this file has '
      '${bytes.length}',
    );
  }
  return img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bytes.buffer,
    bytesOffset: bytes.offsetInBytes,
    numChannels: 4,
  );
}

/// The frame with [framing] applied — the boxes drawn, then the crop taken.
///
/// **Annotate before cropping**, so a box on a node partly outside the crop is
/// clipped with the picture rather than drawn against its edge.
///
/// [pixelRatio] is what turns a layout rect into pixels, so it must be the
/// ratio the frame was *rendered* at rather than one anybody wanted: an
/// `InspectLayout` is logical and a frame is physical, and a crop computed
/// against the wrong one cuts the wrong rectangle convincingly.
img.Image framePicture(
  img.Image image, {
  PictureFraming framing = const PictureFraming(),
  double pixelRatio = 1,
}) {
  if (framing.boxes.isNotEmpty) {
    image = annotateNodes(image, framing.boxes, pixelRatio);
  }
  if (framing.crop case var rect?) {
    image = cropToNode(image, rect, pixelRatio);
  }
  return image;
}

/// The frame, framed and encoded, on disk.
///
/// The last stage, and the one that was split between the backends before this
/// file existed: the guest encoded and wrote inside its session, and the
/// harness lane wrote raw bytes and left its caller to work out the rest. One
/// picture is written one way now.
File writePicture(
  img.Image image,
  String output, {
  PictureFraming framing = const PictureFraming(),
  double pixelRatio = 1,
}) {
  var file = File(output);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(
    img.encodePng(
      framePicture(image, framing: framing, pixelRatio: pixelRatio),
    ),
  );
  return file;
}

/// Where a picture taller than a screen is cut into pages, in logical pixels
/// from the picture's top: the top of every page after the first.
///
/// **Pages because of who reads them.** A model is shown an image no taller
/// than about two thousand pixels, so a phone's whole list in one picture
/// reaches it about a hundred and fifty pixels wide, every row a smudge. A
/// screen at a time, each page is as legible as an ordinary screenshot.
///
/// **Between the rows, never through them.** A cut goes only where no box
/// crosses — a row, a label, a button. A box taller than half a page is a
/// container rather than something to read, and may be cut through; a page
/// with nowhere clean to end is cut at its full height.
///
/// **As few pages as that allows, and even.** The count is what cutting
/// each page as low as it can go takes; the cuts are then moved as near an
/// even share as a clean line allows, so a picture a little taller than a
/// screen is two half screens rather than a screen and a strip — and never
/// so far that the pages after a cut would need one more.
///
/// [top] and [bottom] are the part of the screen the picture shows, in the
/// tree's coordinates: the whole of it, or a `--node` crop.
List<double> pageCuts(
  InspectTree tree, {
  required double page,
  required double top,
  required double bottom,
}) {
  if (bottom - top <= page + _seam) return const [];
  var boxes = [
    for (var node in _distinctBoxes(tree.nodes.toList()))
      if (!node.offstage)
        if (node.layout case var box? when box.height < page / 2) box,
  ];

  /// The lines between [low] and [high] that no box crosses.
  List<double> clean(double low, double high) {
    var near = [
      for (var box in boxes)
        if (box.y < high && box.y + box.height > low) box,
    ];
    return [
      for (var y in {
        for (var box in near) ...[box.y, box.y + box.height],
      })
        if (y > low &&
            y <= high &&
            !near.any(
              (box) => box.y < y - _seam && box.y + box.height > y + _seam,
            ))
          y,
    ];
  }

  /// Where a page from [start] ends when it goes as low as it can.
  double furthest(double start) {
    var lines = clean(start + page / 2, start + page);
    return lines.isEmpty ? start + page : lines.reduce(math.max);
  }

  /// How many pages from [start] to the bottom, each as long as it can be.
  int pagesFrom(double start) {
    var count = 1;
    while (bottom - start > page + _seam) {
      start = furthest(start);
      count++;
    }
    return count;
  }

  var count = pagesFrom(top);
  var share = (bottom - top) / count;
  var cuts = <double>[];
  var previous = top;
  for (var k = 1; k < count; k++) {
    var ideal = top + k * share;
    var options = [
      for (var y in clean(previous + share / 2, previous + page))
        if (pagesFrom(y) <= count - k) y,
    ];
    // Nearest the share, and the higher of two equally near: a page is
    // better a row short than a row long.
    var cut = options.isEmpty
        ? furthest(previous)
        : options.reduce((a, b) {
            var da = (a - ideal).abs(), db = (b - ideal).abs();
            if ((da - db).abs() > _seam) return da < db ? a : b;
            return math.min(a, b);
          });
    cuts.add(cut - top);
    previous = cut;
  }
  return cuts;
}

/// How far a box may overlap a cut and still count as not crossing it: a
/// layout that rounds is not a row sliced in half.
const _seam = 0.5;

/// [picture] cut at [cuts] — logical pixels from its top — and written
/// beside [output] as `<name>.page-<n>.png`, first page first.
///
/// Pages a previous picture left under the same name are removed first, so
/// what is on disk is this picture's pages and no stale seventh.
List<File> writePages(
  img.Image picture,
  String output,
  List<double> cuts, {
  double pixelRatio = 1,
}) {
  var stem = p.withoutExtension(output);
  var directory = File(output).parent..createSync(recursive: true);
  var name = RegExp(
    '^${RegExp.escape(p.basename(stem))}'
    r'\.page-\d+\.png$',
  );
  for (var stale in directory.listSync().whereType<File>()) {
    if (name.hasMatch(p.basename(stale.path))) stale.deleteSync();
  }
  if (cuts.isEmpty) return const [];

  var rows = {
    0,
    for (var cut in cuts) (cut * pixelRatio).round().clamp(0, picture.height),
    picture.height,
  }.toList()..sort();
  return [
    for (var i = 0; i + 1 < rows.length; i++)
      File('$stem.page-${i + 1}.png')..writeAsBytesSync(
        img.encodePng(
          img.copyCrop(
            picture,
            x: 0,
            y: rows[i],
            width: picture.width,
            height: rows[i + 1] - rows[i],
          ),
        ),
      ),
  ];
}
