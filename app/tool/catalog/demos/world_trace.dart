/// The world canvas's trace pieces — the shipping widgets, over a trace fed
/// from events rather than from a running world.
///
/// The events are the ones the lab's synced world recorded on 2026-09-26:
/// Ben orders a flat white, his local write uploads, the server writes it,
/// and PowerSync brings it to Cleo's phone and back to his. The phones are
/// stand-ins; everything else — the band, the numbers, the lines and where
/// their words go, the timeline with the step open, a table opened on its
/// records, the sequence — is what the Worlds panel draws.
library;

import 'package:flutter/widget_previews.dart';
import 'package:flutterware/src/server/attach_session.dart';
import 'package:flutterware/src/world/step_names.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/world_canvas.dart';
import 'package:flutterware_app/src/world/world_sequence.dart';
import 'package:flutterware_app/src/world/world_timeline.dart';
import 'package:flutterware_app/src/world/world_trace.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

@Preview(name: 'Trace', group: 'Worlds', wrapper: wrapInAppTheme)
Widget worldTrace() => const _Trace();

@Preview(name: 'Trace · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget worldTraceDark() => const _Trace();

/// The same step as a sequence: a lane each for Cleo, Ben, the server and
/// the sync engine, and what crossed between them.
@Preview(name: 'Sequence', group: 'Worlds', wrapper: wrapInAppTheme)
Widget worldSequence() => const _Sequence();

@Preview(name: 'Sequence · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget worldSequenceDark() => const _Sequence();

/// The orders table opened: the record Ben's tap made, and its life.
@Preview(name: 'Contents', group: 'Worlds', wrapper: wrapInAppTheme)
Widget worldContents() => const _Trace(opened: 'lab/table/orders');

@Preview(name: 'Contents · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget worldContentsDark() => const _Trace(opened: 'lab/table/orders');

/// Ben's order, as the world heard it.
WorldTrace _recorded() {
  var since = DateTime(2026, 9, 26, 23, 11);
  var trace = WorldTrace(since: since)
    ..addPerson('Cleo', userId: 'u1')
    ..addPerson('Ben', userId: 'u2');
  var id = 1;
  InspectorEvent at(
    int ms,
    String channel,
    Map<String, Object?> payload, [
    String? rid,
  ]) => InspectorEvent(
    channel: channel,
    id: id++,
    time: since.add(Duration(milliseconds: 52000 + ms)),
    payload: payload,
    isReplay: false,
    rid: rid,
  );
  void lab(
    int ms,
    String channel,
    Map<String, Object?> payload, [
    String? rid,
  ]) => trace.addServerEvent('lab', at(ms, channel, payload, rid));
  var rid = 'req-9';
  for (var (n, part) in [
    (1, 'POST /admin/users'),
    (2, 'POST /admin/users'),
    (3, 'GET /health'),
    (4, 'GET /health'),
    (5, 'GET /sync/token'),
    (6, 'GET /sync/token'),
    (7, 'GET /me'),
    (8, 'GET /me'),
  ]) {
    var space = part.indexOf(' ');
    lab(-40000 + n, 'http', {
      'method': part.substring(0, space),
      'path': part.substring(space + 1),
      'status': 200,
    }, 'req-$n');
  }
  trace
    ..addGuestEvent(
      'Ben',
      at(0, worldStepsChannel, {
        'step': 'ben.1',
        'verb': 'tap',
        'target': '"Order a flat white"',
      }),
    )
    ..addGuestEvent(
      'Ben',
      at(3, 'db:main/records', {
        'key': '5cc8e32f-a2bb-4ea1-8363-742901521840',
        'table': 'orders',
        'change': 'local insert',
      }),
    )
    ..addGuestEvent(
      'Ben',
      at(6, worldRequestsChannel, {
        'step': 'ben.1',
        'method': 'POST',
        'url': 'localhost:63486/sync/upload',
        'how': 'window',
      }),
    );
  lab(12, 'write', {
    'table': 'orders',
    'key': '5cc8e32f-a2bb-4ea1-8363-742901521840',
    'op': 'insert',
    'item': 'Flat white',
    'status': 'placed',
    'customer': 'u2',
    'step': 'ben.1',
  }, rid);
  lab(12, 'http', {
    'method': 'POST',
    'path': '/sync/upload',
    'part': '/sync/upload',
    'status': 200,
    'ms': 5.6,
    'step': 'ben.1',
  }, rid);
  for (var (person, ms, op) in [('Cleo', 22, 34), ('Ben', 256, 33)]) {
    trace.addGuestEvent(
      person,
      at(ms, 'db:main/records', {
        'key': '5cc8e32f-a2bb-4ea1-8363-742901521840',
        'table': 'orders',
        'change': 'synced',
        'op': op,
      }),
    );
  }
  return trace;
}

const _sync = {
  'Cleo': {'engine': 'powersync', 'clientId': '916f4f46-9a2e-4c1d-8f0e-1b2c'},
  'Ben': {'engine': 'powersync', 'clientId': 'b190d875-3d4f-4e5a-9b6c-7d8e'},
};

class _Trace extends StatefulWidget {
  const _Trace({this.opened});

  /// The node whose contents the column shows, instead of the step.
  final String? opened;

  @override
  State<_Trace> createState() => _TraceState();
}

class _TraceState extends State<_Trace> {
  final _anchors = TraceAnchors();
  final _trace = _recorded();

  @override
  Widget build(BuildContext context) {
    var people = ['Cleo', 'Ben'];
    Color colorOf(String? person) => person == null || !people.contains(person)
        ? context.colors.mut2
        : context.colors.person(people.indexOf(person));
    var traced = _trace.steps().last;
    var numbers = numberNodes(traced);
    var contents = switch (widget.opened) {
      var node? => _trace.contentsOf(node),
      null => null,
    };
    return SizedBox(
      width: 1180,
      height: 720,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _anchors.stage(
              Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          FwSpacing.xxl,
                          FwSpacing.md,
                          FwSpacing.xxl,
                          wireGap,
                        ),
                        child: Row(
                          children: [
                            for (var person in people)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: FwSpacing.xxl,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      person,
                                      style: context.type.bodyStrong,
                                    ),
                                    const SizedBox(height: FwSpacing.sm),
                                    _anchors.wrap(
                                      personAnchor(person),
                                      Container(
                                        width: 150,
                                        height: 280,
                                        decoration: BoxDecoration(
                                          color: context.colors.panel,
                                          border: Border.all(
                                            color: context.colors.line,
                                            width: 2,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            context.radii.radiusLarge,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      SystemBand(
                        servers: _trace.servers.toList(),
                        sync: _sync,
                        numbers: numbers,
                        litColor: colorOf(traced.step.person),
                        colorOf: colorOf,
                        anchors: _anchors,
                        opened: widget.opened,
                        compact: true,
                      ),
                    ],
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: TraceLinesPainter(
                          beats: traced.beats,
                          anchors: _anchors,
                          colorOf: colorOf,
                          label: context.type.micro.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          pill: context.colors.bg,
                          pillBorder: context.colors.line,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(width: 1, color: context.colors.line),
          SizedBox(
            width: 380,
            child: contents == null
                ? WorldTimeline(
                    steps: _trace.steps().reversed.toList(),
                    messages: _trace.outbox(),
                    people: people,
                    colorOf: colorOf,
                    chosen: traced.step.id,
                    following: traced.step.id,
                    onChoose: (_) {},
                    onOpenMessage: (_) {},
                    deliverTo: (_) => null,
                    log: const [],
                  )
                : NodeContentsView(
                    contents: contents,
                    label: contentsLabel(contents),
                    colorOf: colorOf,
                    shown: traced.step.id,
                    markColor: colorOf(traced.step.person),
                    onBack: () {},
                    onChoose: (_) {},
                  ),
          ),
        ],
      ),
    );
  }
}

class _Sequence extends StatelessWidget {
  const _Sequence();

  @override
  Widget build(BuildContext context) {
    var trace = _recorded();
    var people = ['Cleo', 'Ben'];
    Color colorOf(String? person) => person == null || !people.contains(person)
        ? context.colors.mut2
        : context.colors.person(people.indexOf(person));
    var steps = trace.steps();
    return SizedBox(
      width: 760,
      height: 420,
      child: WorldSequence(
        steps: steps,
        people: people,
        servers: trace.servers.toList(),
        colorOf: colorOf,
        chosen: steps.last.step.id,
        onChoose: (_) {},
      ),
    );
  }
}
