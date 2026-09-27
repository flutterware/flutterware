import 'dart:math';

import 'package:material_ui/material_ui.dart';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'world_canvas.dart';
import 'world_trace.dart';

/// The world as a sequence: a lane for each person, for the world's own
/// actions and for each part of the system, and each step a band down the
/// page with what crossed between them drawn as arrows — requests solid,
/// messages and arrivals dashed, what a server did within itself a note on
/// its own lane. The same steps the canvas draws one at a time, read as a
/// story of who caused what.
class WorldSequence extends StatelessWidget {
  const WorldSequence({
    super.key,
    required this.steps,
    required this.people,
    required this.servers,
    required this.colorOf,
    required this.chosen,
    required this.onChoose,
  });

  /// Oldest first.
  final List<TracedStep> steps;
  final List<String> people;
  final List<SystemServer> servers;
  final Color Function(String? person) colorOf;

  /// The step the stage shows.
  final String? chosen;
  final void Function(String step) onChoose;

  /// Where the first lane is, from the left edge.
  static const inset = 70.0;

  /// A step's own line, above its arrows: who did what, when.
  static const title = 30.0;

  /// Room right of the last lane, for what a server did within itself.
  static const notes = 150.0;

  @override
  Widget build(BuildContext context) {
    var lanes = [
      for (var person in people) _Lane(person, person, colorOf(person)),
      if (steps.any((traced) => traced.step.verb == 'action'))
        _Lane(worldActionsOwner, 'The world', colorOf(worldActionsOwner)),
      for (var server in servers) _Lane(server.name, server.name, null),
      if (steps.any(
        (traced) => everyBeat(traced.beats).any((b) => b.node == syncNode),
      ))
        _Lane(syncNode, 'Sync', null),
    ];
    var rows = [
      for (var traced in steps)
        if (traced.beats.isNotEmpty) (traced, _crossings(traced, lanes)),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var first = inset;
        var span = max(0.0, width - first - notes);
        var xs = <String, double>{
          for (var (i, lane) in lanes.indexed)
            lane.id: lanes.length == 1
                ? first + span / 2
                : first + span * i / (lanes.length - 1),
        };
        var style = context.type.caption.copyWith(color: context.colors.ink);
        return ClipRect(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The lanes' names, above each lane.
              SizedBox(
                height: 32,
                child: Stack(
                  children: [
                    for (var lane in lanes)
                      Positioned(
                        left: xs[lane.id]! - 60,
                        width: 120,
                        top: 6,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (lane.color case var color?) ...[
                              PersonDot(color),
                              const SizedBox(width: FwSpacing.xs),
                            ] else ...[
                              Icon(
                                lane.id == syncNode
                                    ? Icons.sync
                                    : Icons.dns_outlined,
                                size: FwIconSize.sm,
                                color: context.colors.ink2,
                              ),
                              const SizedBox(width: FwSpacing.xs),
                            ],
                            Flexible(
                              child: Text(
                                lane.label,
                                style: context.type.bodyStrong,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Container(height: 1, color: context.colors.line),
              Expanded(
                child: rows.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(FwSpacing.xl),
                        child: Text(
                          'Nothing has crossed between anyone yet.',
                          style: context.type.bodyMuted,
                        ),
                      )
                    : ListView(
                        children: [
                          for (var (traced, crossings) in rows)
                            Tappable(
                              onTap: () => onChoose(traced.step.id),
                              child: Container(
                                height: title + 10 + crossings.length * 26,
                                decoration: BoxDecoration(
                                  color: traced.step.id == chosen
                                      ? context.colors.accentSoft2
                                      : null,
                                  border: Border(
                                    bottom: BorderSide(
                                      color: context.colors.line2,
                                    ),
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _RowPainter(
                                          xs: xs,
                                          crossings: crossings,
                                          lifeline: context.colors.line,
                                          label: style,
                                          paper: context.colors.bg,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: FwSpacing.lg,
                                      right: FwSpacing.lg,
                                      top: FwSpacing.sm,
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: stepTitle(traced.step),
                                              style: context.type.bodySmall
                                                  .copyWith(
                                                    color: colorOf(
                                                      traced.step.person,
                                                    ),
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            TextSpan(
                                              text:
                                                  '   ${clockOf(traced.step.at!)}'
                                                  ' · ${traced.step.id}',
                                              style: context.type.caption,
                                            ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// What [traced] sent between the lanes, in order: an arrow for each beat
  /// that crossed between a person or the world and the system, a note on a
  /// server's lane for what it did within itself.
  List<_Crossing> _crossings(TracedStep traced, List<_Lane> lanes) {
    var ids = {for (var lane in lanes) lane.id};
    String? laneOf(String? node) {
      if (node == null) return null;
      if (node == syncNode) return syncNode;
      var server = node.split('/').first;
      return ids.contains(server) ? server : null;
    }

    var crossings = <_Crossing>[];
    for (var (beat, depth) in beatsByDepth(traced.beats)) {
      var lane = laneOf(beat.node);
      var person = beat.person;
      var said = beat.line ?? _shorn(beat.what);
      var message = beat.node?.contains('/sent/') ?? false;
      if (lane != null && person != null && ids.contains(person)) {
        crossings.add(
          beat.inbound
              ? _Crossing.arrow(
                  lane,
                  person,
                  said,
                  colorOf(person),
                  dashed: true,
                )
              : _Crossing.arrow(person, lane, said, colorOf(person)),
        );
      } else if (lane != null &&
          depth == 0 &&
          traced.step.verb == 'action' &&
          (beat.node?.contains('/part/') ?? false)) {
        // An action's own request: from the world to the server.
        crossings.add(
          _Crossing.arrow(
            worldActionsOwner,
            lane,
            said,
            colorOf(worldActionsOwner),
          ),
        );
      } else if (lane != null && !message) {
        crossings.add(_Crossing.note(lane, said));
      } else if (person != null && ids.contains(person) && lane == null) {
        crossings.add(_Crossing.note(person, said));
      }
    }
    return crossings;
  }

  /// A beat's line without the server's name it starts with, which the lane
  /// already says.
  static String _shorn(String what) {
    var gap = what.indexOf('  ');
    return gap < 0 ? what : what.substring(gap + 2);
  }
}

class _Lane {
  const _Lane(this.id, this.label, this.color);

  final String id;
  final String label;

  /// A person's colour; null for a part of the system.
  final Color? color;
}

class _Crossing {
  const _Crossing.arrow(
    this.from,
    String this.to,
    this.said,
    this.color, {
    this.dashed = false,
  });

  const _Crossing.note(this.from, this.said)
    : to = null,
      color = null,
      dashed = false;

  final String from;

  /// Null for a note on [from]'s lane.
  final String? to;
  final String said;
  final Color? color;
  final bool dashed;
}

class _RowPainter extends CustomPainter {
  _RowPainter({
    required this.xs,
    required this.crossings,
    required this.lifeline,
    required this.label,
    required this.paper,
  });

  final Map<String, double> xs;
  final List<_Crossing> crossings;
  final Color lifeline;
  final TextStyle label;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    var line = Paint()
      ..color = lifeline
      ..strokeWidth = 1;
    for (var x in xs.values) {
      for (var y = 0.0; y < size.height; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, min(y + 3, size.height)), line);
      }
    }
    for (var (i, crossing) in crossings.indexed) {
      var y = WorldSequence.title + 24 + i * 26;
      var from = xs[crossing.from];
      if (from == null) continue;
      var to = crossing.to == null ? null : xs[crossing.to];
      if (to == null) {
        _text(
          canvas,
          crossing.said,
          Offset(from + 8, y - 8),
          min(240, size.width - from - 16),
        );
        continue;
      }
      var paint = Paint()
        ..color = crossing.color ?? lifeline
        ..strokeWidth = 1.6;
      if (crossing.dashed) {
        var step = from < to ? 6.0 : -6.0;
        for (var x = from; (step > 0 ? x < to : x > to); x += step) {
          var end = step > 0 ? min(x + step / 2, to) : max(x + step / 2, to);
          canvas.drawLine(Offset(x, y), Offset(end, y), paint);
        }
      } else {
        canvas.drawLine(Offset(from, y), Offset(to, y), paint);
      }
      var head = from < to ? -7.0 : 7.0;
      canvas.drawPath(
        Path()
          ..moveTo(to, y)
          ..lineTo(to + head, y - 4)
          ..lineTo(to + head, y + 4)
          ..close(),
        Paint()..color = crossing.color ?? lifeline,
      );
      var left = min(from, to);
      _text(
        canvas,
        crossing.said,
        Offset(left + 6, y - 17),
        (from - to).abs() - 12,
      );
    }
  }

  void _text(Canvas canvas, String text, Offset at, double width) {
    if (width <= 20) return;
    var painter = TextPainter(
      text: TextSpan(text: text, style: label),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: width);
    canvas.drawRect(
      Rect.fromLTWH(at.dx - 2, at.dy, painter.width + 4, painter.height),
      Paint()..color = paper.withValues(alpha: 0.85),
    );
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.crossings != crossings || old.xs != xs || old.label != label;
}
