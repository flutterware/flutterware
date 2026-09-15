import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'artifact.dart';
import 'finding_face.dart';
import 'shot_cache.dart';

/// What a pull-request comment needs, as files.
///
/// fw emits, the workflow hosts and posts. A comment on GitHub can only
/// show images by URL, and where those URLs live — an orphan branch, Pages, a
/// bucket — is the repository's business, not this tool's. So the comment is
/// written with `__MOSAIC_URL__` and `__VIEWER_URL__` placeholders, and the
/// fifteen lines of workflow that upload the files substitute them.
class PrReport {
  const PrReport({required this.commentPath, this.mosaicPath});

  final String commentPath;

  /// Absent when nothing changed — a clean comment carries no picture.
  final String? mosaicPath;
}

/// One cell of the mosaic: what to call it, and the two frames.
class _MosaicRow {
  const _MosaicRow({
    required this.state,
    required this.id,
    required this.base,
    required this.head,
    this.clusters = const [],
  });

  /// The caption's first half, which always survives — it is one short word.
  final String state;

  /// The caption's second half, elided from the left when it will not fit.
  final String id;

  final img.Image? base;
  final img.Image? head;

  /// Burned onto the head frame, in its pixel space.
  final List<DiffRect> clusters;
}

/// Writes `comment.md` and, when anything changed, `mosaic.png` into
/// [directory].
///
/// The mosaic is one row per finding, base beside head, capped at
/// [mosaicRowCap] — it is the teaser, and the exported page is the artifact.
///
/// **A picture leads with what a picture can show.** The findings whose
/// picture shows their change come first, worst first among them, and the ones
/// that changed only what no screenshot sees — events, texts, the tree — fill
/// whatever the cap leaves. Ranked by state alone, a branch that fired a new
/// event on thirty flows and moved a layout on two would spend the cap on
/// thirty pairs of identical frames and cut the two anybody could see.
PrReport writePrReport({
  required ComparisonArtifact artifact,
  required ShotCache cache,
  required String against,
  required String directory,
  String? head,
}) {
  Directory(directory).createSync(recursive: true);

  var findings = _findings(artifact);
  var pictured = [
    ...findings.where((finding) => finding.showsInPicture),
    ...findings.where((finding) => !finding.showsInPicture),
  ];
  var rows = [
    for (var finding in pictured.take(mosaicRowCap))
      ?_row(finding, cache: cache),
  ];

  String? mosaicPath;
  if (rows.isNotEmpty) {
    mosaicPath = p.join(directory, 'mosaic.png');
    File(mosaicPath).writeAsBytesSync(_mosaic(rows));
  }

  var commentPath = p.join(directory, 'comment.md');
  File(commentPath).writeAsStringSync(
    _comment(
      artifact,
      against: against,
      head: head,
      findings: findings,
      hasMosaic: mosaicPath != null,
    ),
  );
  return PrReport(commentPath: commentPath, mosaicPath: mosaicPath);
}

/// The comment's first line, and how a workflow finds its own comment again:
/// a run that updates in place greps for this and PATCHes, instead of
/// stacking a new comment per push.
const commentMarker = '<!-- fw-compare -->';

/// The mosaic stops here and the comment says "and N more" — a comment is a
/// teaser, and forty cells of phone frames is a page pretending to be one.
const mosaicRowCap = 20;

/// The table stops here, folded or not: GitHub refuses a comment past 65536
/// characters, and a table that grows a row per finding walks a big
/// comparison straight into that wall — a report that fails to *post* on
/// exactly the runs with the most to say. The page has every row.
const commentRowCap = 100;

/// Both frames scale to this height, so a phone step and a wide desktop
/// preview read as cells of one table rather than a ransom note.
const _rowHeight = 320;
const _pad = 12;
const _titleHeight = 28;

/// Cells are laid out across before they are laid down, and this is how far
/// across they go before wrapping.
///
/// Stacked in one column a teaser got *taller* the more it had to show, which
/// is backwards: fifteen findings came to 332×5580 — narrower than a comment's
/// content column, so no client scaled it down, and the comment became a
/// ribbon nobody reached the end of. Wide enough here for four phone pairs,
/// and still under what a comment renders at.
const _mosaicMaxWidth = 1400;

/// What a clipped caption is replaced by. Three periods rather than `…`,
/// which [_captionFont] has no glyph for and would draw as nothing at all.
const _elision = '...';

final _captionFont = img.arial14;

/// One finding, whichever half it came from.
class _Finding {
  const _Finding({
    required this.id,
    required this.tab,
    required this.state,
    this.delta,
    this.item,
    this.frames,
    this.showsInPicture = false,
  });

  final String id;

  /// The exported page's tab this finding lives on — the first segment of the
  /// fragment its table row links to.
  final String tab;

  final ComparedState state;

  /// The third column: `0.38% · 2 regions`, or the step that moved.
  final String? delta;

  /// The row whose shots and clusters draw, when there is one.
  final ComparedItem? item;

  /// A scenario step's frames, which are files rather than cache keys.
  final ({FrameRef? base, FrameRef? head})? frames;

  /// Whether [item]'s picture shows its change — see `showsInPicture`.
  final bool showsInPicture;
}

List<_Finding> _findings(ComparisonArtifact artifact) {
  var findings = <_Finding>[];
  for (var item in artifact.previews.items) {
    if (!_isFinding(item.state)) continue;
    findings.add(
      _Finding(
        id: item.id,
        tab: 'previews',
        state: item.state,
        delta: _delta(item),
        item: item,
        showsInPicture: showsInPicture(item),
      ),
    );
  }
  for (var scenario
      in artifact.scenarios?.items ?? const <ScenarioComparison>[]) {
    if (!_isFinding(scenario.state)) continue;
    // The scenario's face in the mosaic is one step that has pictures — one
    // row per flow, because one decision in the source should not fill the
    // comment with four near-identical frames.
    var face = scenarioFace(scenario);
    findings.add(
      _Finding(
        id: scenario.scenario,
        tab: 'scenarios',
        state: scenario.state,
        delta: face == null
            ? scenario.branches.isEmpty
                  ? null
                  : '${scenario.branches.length} branch'
                        '${scenario.branches.length == 1 ? '' : 'es'}'
            : 'step `${face.id}`',
        item: face,
        frames: face == null ? null : scenario.frames[face.id],
        showsInPicture: face != null && showsInPicture(face),
      ),
    );
  }
  findings.sort(
    (a, b) => a.state.index == b.state.index
        ? a.id.compareTo(b.id)
        : a.state.index.compareTo(b.state.index),
  );
  return findings;
}

bool _isFinding(ComparedState state) =>
    state != ComparedState.same && state != ComparedState.skipped;

String? _delta(ComparedItem item) {
  var pixels = item.pixels?.diff;
  if (pixels == null || !pixels.changed) return _oneLine(item.note);
  return '${(pixels.fraction * 100).toStringAsFixed(2)}% · '
      '${pixels.clusters.length} region${pixels.clusters.length == 1 ? '' : 's'}';
}

/// A cell's worth of a note.
///
/// A newline inside a markdown table cell **ends the row**, so a compiler
/// error dropped in whole does not merely look untidy: it breaks the table
/// from that row down, and a failing entry's note is exactly where the
/// compiler's diagnostics live. The page has the whole message.
String? _oneLine(String? note) {
  if (note == null) return null;
  var first = note.split('\n').first.trim();
  return first.length < note.trim().length ? '$first …' : first;
}

_MosaicRow? _row(_Finding finding, {required ShotCache cache}) {
  img.Image? decode(String? key, FrameRef? ref) {
    if (key != null) {
      var bytes = cache.read(key);
      var record = cache.meta(key);
      if (bytes == null || record == null) return null;
      return _fromRgba(bytes, record.width, record.height);
    }
    if (ref != null && ref.isDrawable) {
      var file = File(ref.path);
      if (!file.existsSync()) return null;
      return _fromRgba(file.readAsBytesSync(), ref.width, ref.height);
    }
    return null;
  }

  var shots = finding.item?.shots;
  var base = decode(shots?.base, finding.frames?.base);
  var head = decode(shots?.head, finding.frames?.head);
  if (base == null && head == null) return null;
  return _MosaicRow(
    state: finding.state.name,
    id: finding.id,
    base: base,
    head: head,
    clusters: finding.item?.pixels?.diff.clusters ?? const [],
  );
}

img.Image _fromRgba(Uint8List rgba, int width, int height) =>
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

/// One cell once its frames are scaled: what to draw, and how wide it draws.
class _MosaicCell {
  _MosaicCell({required this.row, this.base, this.head});

  final _MosaicRow row;
  final img.Image? base;
  final img.Image? head;

  int get width =>
      (base?.width ?? 0) +
      (head?.width ?? 0) +
      (base != null && head != null ? _pad : 0);
}

Uint8List _mosaic(List<_MosaicRow> rows) {
  var cells = [for (var row in rows) _scale(row)];

  // Cells flow left to right and wrap, each keeping its own width. A uniform
  // grid also cures the ribbon, but every column then has to be as wide as
  // the widest cell — one desktop preview among fourteen phones made a
  // 1396×2004 picture that was two thirds empty.
  var lines = <List<_MosaicCell>>[[]];
  var lineWidth = _pad;
  for (var cell in cells) {
    if (lines.last.isNotEmpty &&
        lineWidth + cell.width + _pad > _mosaicMaxWidth) {
      lines.add([]);
      lineWidth = _pad;
    }
    lines.last.add(cell);
    lineWidth += cell.width + _pad;
  }

  var cellHeight = _titleHeight + _rowHeight;
  var canvas = img.Image(
    // The widest line rather than [_mosaicMaxWidth]: an all-phone mosaic
    // should not be padded out to a width it does not use, and a lone cell
    // too wide to wrap has to fit anyway.
    width: lines
        .map((line) => line.fold(_pad, (w, cell) => w + cell.width + _pad))
        .reduce(max),
    height: _pad + lines.length * (cellHeight + _pad),
    numChannels: 3,
  );
  img.fill(canvas, color: img.ColorRgb8(250, 250, 250));

  var y = _pad;
  for (var line in lines) {
    var x = _pad;
    for (var cell in line) {
      img.drawString(
        canvas,
        mosaicCaption(cell.row.state, cell.row.id, cell.width),
        font: _captionFont,
        x: x,
        y: y,
        color: img.ColorRgb8(40, 40, 40),
      );
      var frameX = x;
      for (var frame in [cell.base, cell.head]) {
        if (frame == null) continue;
        img.compositeImage(canvas, frame, dstX: frameX, dstY: y + _titleHeight);
        frameX += frame.width + _pad;
      }
      x += cell.width + _pad;
    }
    y += cellHeight + _pad;
  }
  return img.encodePng(canvas);
}

/// Both frames to [_rowHeight], with the changed regions boxed on the head.
_MosaicCell _scale(_MosaicRow row) {
  var base = row.base == null
      ? null
      : img.copyResize(row.base!, height: _rowHeight);
  img.Image? head;
  if (row.head != null) {
    // The clusters are burned in before scaling, in the frame's own pixel
    // space — scaled coordinates drift a pixel per region and a box that
    // misses what it points at is worse than none.
    var full = row.head!.clone();
    for (var rect in row.clusters) {
      img.drawRect(
        full,
        x1: rect.x - 1,
        y1: rect.y - 1,
        x2: rect.x + rect.width + 1,
        y2: rect.y + rect.height + 1,
        color: img.ColorRgb8(255, 160, 0),
        thickness: (full.width / 300).clamp(1, 4).toDouble(),
      );
    }
    head = img.copyResize(full, height: _rowHeight);
  }
  return _MosaicCell(row: row, base: base, head: head);
}

/// A cell's caption, sized to the cell rather than to the frames under it.
///
/// Drawn unmeasured it ran off the right edge of the canvas and was simply
/// clipped, which cost the leaf and the symbol — the half that says *which*
/// entry this is. So the id is elided from the **left** and the state, one
/// short word, always survives: `changed  ...card.dart#TaskCardExample.new`.
@visibleForTesting
String mosaicCaption(String state, String id, int width) {
  var prefix = '$state  ';
  return '$prefix${_elideLeft(id, width - mosaicTextWidth(prefix))}';
}

String _elideLeft(String text, int width) {
  if (mosaicTextWidth(text) <= width) return text;
  var budget = width - mosaicTextWidth(_elision);
  var taken = 0;
  var kept = 0;
  for (var index = text.length - 1; index >= 0; index--) {
    var advance =
        _captionFont.characters[text.codeUnitAt(index)]?.xAdvance ?? 0;
    if (taken + advance > budget) break;
    taken += advance;
    kept++;
  }
  return '$_elision${text.substring(text.length - kept)}';
}

/// What [img.drawString] will measure this at — the same rule it uses, down to
/// dropping a character the font has no glyph for.
@visibleForTesting
int mosaicTextWidth(String text) {
  var width = 0;
  for (var unit in text.codeUnits) {
    width += _captionFont.characters[unit]?.xAdvance ?? 0;
  }
  return width;
}

/// A comment is a teaser, and its visible height must not scale with what the
/// comparison found: the heading carries the verdict, the mosaic carries the
/// pictures, and the table — the only part that grows per finding — is folded
/// into a `<details>`. The call to action is the page, so its link is the
/// first line under the heading rather than the last thing before the footer.
String _comment(
  ComparisonArtifact artifact, {
  required String against,
  required String? head,
  required List<_Finding> findings,
  required bool hasMosaic,
}) {
  var counts = artifact.counts;
  var compared = counts.values.fold(0, (a, b) => a + b);
  var skipped = counts[ComparedState.skipped] ?? 0;
  var elapsed =
      artifact.previews.elapsed +
      (artifact.scenarios?.elapsed ?? Duration.zero);
  // Which packages, when there is more than one to name — a comparison that
  // covered three of a repository's four is a different receipt from one that
  // covered everything, and the row ids alone do not add up to that.
  var packages = {
    ...artifact.previews.packages,
    ...?artifact.scenarios?.packages,
  };
  // The skip clause only when the skip rule answered anything: a cold CI run
  // printing "0 skipped" is noise wearing a number.
  var notCompared = artifact.notCompared;
  var receipt = [
    '$compared entries compared',
    if (packages.length > 1) 'across ${packages.length} packages',
    if (skipped - notCompared.length > 0)
      '${skipped - notCompared.length} skipped',
    if (elapsed > Duration.zero) 'in ${_took(elapsed)}',
  ].join(' · ');

  var buffer = StringBuffer()..writeln(commentMarker);
  // **Before the verdict, because it unmakes it.** A half whose harness would
  // not build leaves no rows, and no rows read as "nothing changed" — the
  // silence a `note` exists to break. The comment used to print that silence
  // as a pass, which is the one thing a pull-request gate must never do.
  var gap = verdictGapOf(
    scenariosNote: artifact.scenarios?.note,
    previewsNote: artifact.previews.note,
    scenarioStates:
        artifact.scenarios?.items.map((item) => item.state) ?? const [],
    previewStates: artifact.previews.items.map((item) => item.state),
    inconclusiveScenarios: artifact.notCompared.length,
    narrowed: artifact.narrowed,
  );
  // Under the heading, whatever it says: a caveat qualifies a clean verdict as
  // much as a red one — "nothing changed" over a tree the base read another
  // way is the sentence a reader most needs the reason for.
  void caveats() {
    for (var caveat in artifact.caveats) {
      buffer.writeln('> $caveat\n');
    }
  }

  // Scenarios that produced no result, named under whichever verdict the rest
  // reached. Not findings — nothing here is a claim about the branch — and
  // never folded into "skipped", which means the skip rule found no reason to
  // look: every one of these was looked at, and what it drew depended on the
  // machine.
  void unsure() {
    if (notCompared.isEmpty) return;
    var count = notCompared.length;
    buffer
      ..writeln(
        '<details><summary>$count scenario${count == 1 ? '' : 's'} not '
        'compared — no result on this machine, which is a finding about the '
        'scenario and not the branch</summary>\n',
      )
      ..writeln('| scenario | why |')
      ..writeln('|---|---|');
    for (var scenario in notCompared.take(commentRowCap)) {
      var why = scenario.inconclusive!.replaceAll('|', r'\|');
      buffer.writeln('| `${scenario.scenario}` | $why |');
    }
    if (count > commentRowCap) {
      buffer.writeln(
        '\n*…and ${count - commentRowCap} more — the page has them all.*',
      );
    }
    buffer.writeln('\n</details>\n');
  }

  var notComparedClause = notCompared.isEmpty
      ? ''
      : ' · ${notCompared.length} not compared';
  if (findings.isEmpty && gap == null) {
    buffer.writeln('### Comparison against `$against`$notComparedClause\n');
    caveats();
    buffer.writeln('Nothing changed — $receipt.\n');
    unsure();
  } else if (findings.isEmpty) {
    buffer.writeln('### Comparison against `$against` — **no verdict**\n');
    caveats();
    buffer
      ..writeln('$gap.\n')
      ..writeln(
        '[**Open the full comparison →**]($viewerUrlPlaceholder) · $receipt\n',
      );
    unsure();
  } else {
    var summary = [
      for (var entry in counts.entries)
        if (_isFinding(entry.key)) '${entry.value} ${entry.key.name}',
    ].join(' · ');
    buffer.writeln(
      '### Comparison against `$against` — **$summary**$notComparedClause\n',
    );
    caveats();
    // Above the link rather than folded away with the table: a reader who
    // stops at the pictures has to know part of the run answered nothing.
    if (gap != null) buffer.writeln('> **No verdict** — $gap.\n');
    buffer.writeln(
      '[**Open the full comparison →**]($viewerUrlPlaceholder) · $receipt\n',
    );
    if (hasMosaic) {
      // The image is the biggest thing in the comment, so it is also a door:
      // clicking it opens the page rather than the raw PNG.
      buffer.writeln(
        '[![comparison]($mosaicUrlPlaceholder)]($viewerUrlPlaceholder)\n',
      );
    }
    // The summary line says the mosaic is a cap when it is one, which is the
    // whole job the old "…and N more" footnote was doing.
    var shown = hasMosaic && findings.length > mosaicRowCap
        ? '${findings.length} findings (the picture shows $mosaicRowCap, '
              'those that moved on screen first)'
        : '${findings.length} finding${findings.length == 1 ? '' : 's'}';
    buffer
      ..writeln('<details><summary>$shown</summary>\n')
      ..writeln('| entry | state | Δ |')
      ..writeln('|---|---|---|');
    for (var finding in findings.take(commentRowCap)) {
      // Every row is a door into the page: the entry opens its finding, and a
      // scenario's Δ opens the very step that moved. The fragment grammar is
      // the viewer's own — `<tab>/<selection>`, escapes spelled out so an
      // id's `#` neither ends the URL nor breaks the markdown.
      var entry =
          '[`${finding.id}`]'
          '($viewerUrlPlaceholder#${finding.tab}/${_component(finding.id)})';
      var delta = finding.delta ?? '';
      if (finding.tab == 'scenarios' &&
          finding.item != null &&
          delta.isNotEmpty) {
        delta =
            '[$delta]($viewerUrlPlaceholder#scenarios/'
            '${_component(finding.id)}/${_component(finding.item!.id)})';
      }
      buffer.writeln('| $entry | ${finding.state.name} | $delta |');
    }
    if (findings.length > commentRowCap) {
      buffer.writeln(
        '\n*…and ${findings.length - commentRowCap} more — the page has '
        'them all.*',
      );
    }
    buffer.writeln('\n</details>\n');
    unsure();
  }
  // The head sha, because this comment gets overwritten in place: it is what
  // tells a reader whether the report still describes the latest push.
  var at = head == null
      ? ''
      : ' @${head.length > 7 ? head.substring(0, 7) : head}';
  // "Computed from git" was the whole sentence, and it was loose: either side
  // may be read back from the cache instead of replayed. What it meant is that
  // nothing is blessed — and that a cached side is one that was a result.
  buffer.writeln(
    '<sub>`fw compare`$at — both sides from git, nothing blessed; a side '
    'read from the cache is one that replayed to a result under the same '
    'inputs.</sub>',
  );
  return buffer.toString();
}

/// A fragment segment, escaped for the page *and* for markdown:
/// [Uri.encodeComponent] leaves `(` and `)` alone, and an unescaped `)` in a
/// link target ends the link mid-id.
String _component(String value) =>
    Uri.encodeComponent(value).replaceAll('(', '%28').replaceAll(')', '%29');

String _took(Duration elapsed) {
  var ms = elapsed.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) {
    return '${(ms / 1000).toStringAsFixed(ms >= 10000 ? 0 : 1)}s';
  }
  return '${elapsed.inMinutes}m '
      '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}s';
}

/// What the workflow substitutes once it has hosted `mosaic.png`.
const mosaicUrlPlaceholder = '__MOSAIC_URL__';

/// What the workflow substitutes once it has hosted the `web/` page.
const viewerUrlPlaceholder = '__VIEWER_URL__';
