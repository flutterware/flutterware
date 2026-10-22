import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'model.dart';

/// Recovers positioned, styled text runs for one painted paragraph.
///
/// The [ui.Paragraph] handed to `drawParagraph` is opaque: it exposes layout
/// (line metrics, boxes for ranges) but not its text. The string and the
/// styles come from the render tree instead — [span] is the owning
/// [RenderParagraph]'s fully-resolved `text`. The join is by character index:
/// the span flattens to the same string the paragraph was built from
/// (placeholders as U+FFFC), so every (line × style-run) intersection can ask
/// the real paragraph where it sits.
List<TextRun> extractTextRuns(
  ui.Paragraph paragraph,
  InlineSpan span,
  Offset offset,
) {
  var flat = _flatten(span);
  var text = flat.map((r) => r.text).join();
  if (text.isEmpty) return [];

  var runs = <TextRun>[];
  var lines = paragraph.computeLineMetrics();
  var pos = 0;
  for (var line in lines) {
    if (pos >= text.length) break;
    var boundary = paragraph.getLineBoundary(TextPosition(offset: pos));
    if (!boundary.isValid || boundary.isCollapsed) {
      pos += 1;
      continue;
    }
    var runStart = 0;
    for (var piece in flat) {
      var s = runStart;
      var e = runStart + piece.text.length;
      runStart = e;
      var from = s > boundary.start ? s : boundary.start;
      var to = e < boundary.end ? e : boundary.end;
      if (from >= to) continue;
      var content = text.substring(from, to);
      if (content.replaceAll('\n', '').isEmpty) continue;
      if (content.contains('￼')) continue;
      var boxes = paragraph.getBoxesForRange(from, to);
      if (boxes.isEmpty) continue;
      var clusters = <TextCluster>[];
      for (var i = from; i < to; i++) {
        var next = i + 1;
        // Keep surrogate pairs whole.
        if (text.codeUnitAt(i) & 0xFC00 == 0xD800 && next < to) next += 1;
        var charBoxes = paragraph.getBoxesForRange(i, next);
        if (charBoxes.isNotEmpty) {
          clusters.add(
            TextCluster(
              text.substring(i, next),
              charBoxes.first.left + offset.dx,
            ),
          );
        }
        if (next > i + 1) i += 1;
      }
      var style = piece.style ?? const TextStyle();
      runs.add(
        TextRun(
          text: content.replaceAll('\n', ''),
          x: boxes.first.left + offset.dx,
          baseline: line.baseline + offset.dy,
          fontFamily: style.fontFamily,
          fontSize: style.fontSize ?? 14,
          fontWeight: style.fontWeight ?? FontWeight.normal,
          fontStyle: style.fontStyle ?? FontStyle.normal,
          color: style.color ?? const Color(0xFF000000),
          letterSpacing: style.letterSpacing,
          clusters: clusters,
        ),
      );
    }
    pos = boundary.end;
    if (pos < text.length && text[pos] == '\n') pos += 1;
  }
  return runs;
}

class _FlatRun {
  _FlatRun(this.text, this.style);
  final String text;
  final TextStyle? style;
}

List<_FlatRun> _flatten(InlineSpan span) {
  var out = <_FlatRun>[];
  void walk(InlineSpan node, TextStyle? inherited) {
    var style = node.style == null
        ? inherited
        : (inherited?.merge(node.style) ?? node.style);
    if (node is TextSpan) {
      var text = node.text;
      if (text != null && text.isNotEmpty) {
        out.add(_FlatRun(text, style));
      }
      for (var child in node.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    } else {
      out.add(_FlatRun('￼', style));
    }
  }

  walk(span, null);
  return out;
}
