import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';
import 'package:vm_service/vm_service.dart'
    show DartIOExtension, HttpProfileRequest, HttpProfileRequestRef;

import '../run/connection.dart';
import '../run/network_tracker.dart';
import '../ui/code_block.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'mail_view.dart' show mailHtml;
import 'open_world.dart';
import 'web_snapshot.dart';
import 'world_timeline.dart';
import 'world_trace.dart';

/// Where a row's detail reads what the trace does not keep: a request's
/// headers and bodies, which only the app that sent it recorded, and a mail
/// as its recipient sees it.
abstract interface class TimelineSources {
  /// The request [row] is, as [person]'s app recorded it.
  Future<AppRequest> request(String person, TimelineRow row);

  /// [message] drawn as a mail client would; null where nothing draws.
  Future<WebSnapshot>? picture(OutboxMessage message);
}

/// What a person's app recorded of a request: its [detail], or [why] there
/// is none.
class AppRequest {
  const AppRequest(this.detail) : why = null;
  const AppRequest.missing(String this.why) : detail = null;

  final HttpProfileRequest? detail;
  final String? why;
}

/// [TimelineSources] of an open world: each person's app read through the
/// VM it runs in — the HTTP profile Run's Network tab reads — and the mail
/// pictures the world draws.
class WorldSources implements TimelineSources {
  WorldSources(this._world);

  final OpenWorld Function() _world;
  final _connections = <String, Future<RunConnection>>{};

  @override
  Future<AppRequest> request(String person, TimelineRow row) async {
    var who = _world().people[person];
    var uri = who != null && who.running ? who.handle?.vmService : null;
    if (uri == null) {
      return AppRequest.missing(
        "$person's app isn't running, so its side of the request isn't "
        'available.',
      );
    }
    var data = row.beat!.data;
    var path = '${data['path']}'.split('?').first;
    try {
      var connection = await (_connections[uri] ??= RunConnection.connect(
        uri,
        settle: Duration.zero,
      ));
      var service = connection.service;
      var isolate = RunConnection.rootIsolateOf(
        (await service.getVM()).isolates,
      );
      if (isolate == null) throw StateError('no isolate');
      var profile = await service.getHttpProfile(isolate);
      var at = row.beat!.at;
      Duration off(HttpProfileRequestRef request) =>
          request.startTime.difference(at).abs();
      var near = [
        for (var request in profile.requests)
          if (request.method == data['method'] &&
              request.uri.path == path &&
              off(request) < const Duration(seconds: 2))
            request,
      ]..sort((a, b) => off(a).compareTo(off(b)));
      // The nearest in time that carries the step: two requests alike in
      // one tap are told apart by when they left.
      for (var candidate in near.take(4)) {
        var detail = await service.getHttpProfileRequest(isolate, candidate.id);
        var steps = detail.request?.headers?[stepHeader];
        if (steps is List && steps.contains(row.step.id)) {
          return AppRequest(detail);
        }
      }
      return AppRequest.missing(
        "$person's app has no record of it. Restarting an app clears what it "
        'recorded.',
      );
    } on Object catch (error) {
      unawaited(
        _connections.remove(uri)?.then((c) => c.close(), onError: (_) {}),
      );
      return AppRequest.missing("Could not read $person's app: $error");
    }
  }

  /// The header a guest stamps each request with, naming its step.
  static const stepHeader = 'x-fw-step';

  @override
  Future<WebSnapshot>? picture(OutboxMessage message) =>
      _world().snapshots.of(message.html ?? mailHtml(message));

  void dispose() {
    for (var connection in _connections.values) {
      unawaited(connection.then((c) => c.close(), onError: (_) {}));
    }
    _connections.clear();
  }
}

/// One row, opened: what it was, in a sentence, what caused it, and the data
/// itself — a request and its response, the fields a write set, a message
/// as its recipient got it.
class TimelineDetail extends StatefulWidget {
  const TimelineDetail({
    super.key,
    required this.row,
    required this.trace,
    required this.onClose,
    this.sources,
  });

  final TimelineRow row;
  final WorldTrace trace;
  final TimelineSources? sources;
  final VoidCallback onClose;

  @override
  State<TimelineDetail> createState() => _TimelineDetailState();
}

class _TimelineDetailState extends State<TimelineDetail> {
  /// The app's side of a call, read once.
  Future<AppRequest>? _request;

  /// A mail's picture, drawn once.
  Future<WebSnapshot>? _picture;

  @override
  void initState() {
    super.initState();
    var row = widget.row;
    var beat = row.beat;
    var person = beat?.person;
    if (beat?.kind == BeatKind.call &&
        person != null &&
        beat!.data['url'] != null) {
      _request = widget.sources?.request(person, row);
    }
    if (beat?.kind == BeatKind.mail) {
      if (_message case var message?) {
        _picture = widget.sources?.picture(message);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    // What was read makes it taller: shown too, once it is drawn.
    for (var later in <Future<Object?>?>[_request, _picture]) {
      unawaited(
        later?.then(
          (_) => WidgetsBinding.instance.addPostFrameCallback((_) => _reveal()),
          onError: (_) {},
        ),
      );
    }
  }

  /// Scrolls it into view: up to its row when that went above the view —
  /// the detail open before it closed, and everything under that moved up —
  /// and down to its end when it opened below the fold, no further than
  /// keeps its row on screen.
  void _reveal() {
    if (!mounted) return;
    var box = context.findRenderObject();
    var scrollable = Scrollable.maybeOf(context);
    if (box == null || scrollable == null) return;
    var viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    var position = scrollable.position;
    var top = viewport.getOffsetToReveal(box, 0).offset - rowHeight;
    var bottom = viewport.getOffsetToReveal(box, 1).offset;
    var target = position.pixels > top
        ? top
        : position.pixels < bottom
        ? min(bottom, top)
        : position.pixels;
    target = target.clamp(0.0, position.maxScrollExtent);
    if (target != position.pixels) {
      unawaited(
        position.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  /// The row it opens under, which stays in view.
  static const rowHeight = 40.0;

  OutboxMessage? get _message => switch (widget.row.beat?.event) {
    var id? => widget.trace.messageById(id),
    null => null,
  };

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (head, lines, blocks) = _said(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(84, 0, FwSpacing.xxl, FwSpacing.md),
      decoration: BoxDecoration(
        color: colors.statusFill(colors.accent),
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.statusBorder(colors.accent)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xl,
              FwSpacing.lg,
              FwSpacing.xxxl + FwSpacing.lg,
              FwSpacing.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(head, style: context.type.bodyStrong),
                for (var line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: FwSpacing.xxs),
                    child: SelectableText(
                      line,
                      style: context.type.body.copyWith(color: colors.ink2),
                    ),
                  ),
                if (blocks.isNotEmpty) ...[
                  const SizedBox(height: FwSpacing.lg),
                  _Blocks(blocks),
                ],
              ],
            ),
          ),
          Positioned(
            top: FwSpacing.sm,
            right: FwSpacing.sm,
            child: Tooltip(
              message: 'Close',
              child: Tappable(
                onTap: widget.onClose,
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
                child: Padding(
                  padding: const EdgeInsets.all(FwSpacing.sm),
                  child: Icon(
                    Icons.close,
                    size: FwIconSize.sm,
                    color: colors.mut,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The sentence, the lines under it, and the blocks of data.
  (String, List<String>, List<_Block>) _said(BuildContext context) {
    var row = widget.row;
    var step = row.step;
    var beat = row.beat;
    var at = clockOf(row.at, widget.trace.since);
    if (beat == null) return _step(at);
    var server = beat.server ?? 'the';
    var cause = 'Caused by ${causeOf(step)} (${step.id}).';
    var data = beat.data;
    var person = beat.person;
    switch (beat.kind) {
      case BeatKind.call:
        return _call(beat, cause);
      case BeatKind.write:
        var run = beat.folded.length > 1;
        var statements = [
          for (var line in row.within?.folded ?? const <String>[])
            if (!line.startsWith('wrote ')) line,
        ];
        return (
          run
              ? 'The $server server ${beat.said.split(' · ').first}.'
              : 'The $server server wrote ${data['table']}/${data['key']}.',
          [cause],
          [
            _Block.fields(
              run ? 'Where it ended' : 'The row',
              _fields(data, leave: const {'step', 'layer', 'level'}),
            ),
            if (run)
              _Block.code('Each write', beat.folded.join('\n'))
            else if (statements.isNotEmpty)
              _Block.code(
                'What its request ran',
                statements.join('\n'),
                language: 'sql',
              )
            else
              const _Block.note(
                'SQL',
                'None reported. Statements show here when the server reports '
                    '`sql` events.',
              ),
          ],
        );
      case BeatKind.identify:
        var user = '${data['user']}';
        var who = widget.trace.personOfUser(user);
        return (
          who == null
              ? 'The $server server identified this request as $user, who '
                    'is not in this world.'
              : 'The $server server identified $user as $who.',
          [cause],
          [
            _Block.fields('Who', [
              ('user', user),
              ('is', who ?? 'not in this world'),
            ]),
          ],
        );
      case BeatKind.reach:
        // One row for a broadcast: everyone it reached is in [row.to].
        var reached = row.to.isEmpty ? ['${data['user']}'] : row.to;
        return (
          reached.length == 1
              ? "The $server server sent ${reached.single}'s app an update: "
                    '${data['what']}.'
              : 'The $server server sent an update to ${_listed(reached)}: '
                    '${data['what']}.',
          [cause],
          [
            _Block.fields('What the server reported', [
              ('to', _listed(reached)),
              ('said', '${data['what']}'),
            ]),
            const _Block.note(
              'Content',
              'Not recorded. The server reports who it updated and about '
                  'what, not the message itself.',
            ),
          ],
        );
      case BeatKind.sms || BeatKind.mail || BeatKind.push:
        return _sent(beat, cause);
      case BeatKind.record:
        var change = '${data['change']}';
        var name = '${data['table']}/${data['key']}';
        var op = data['op'] == null ? '' : ' (op ${data['op']})';
        return (
          change.startsWith('local ')
              ? "$person's phone wrote $name locally."
              : person == step.person
              ? "$person's phone had $name confirmed by the sync$op."
              : "$person's phone received $name$op.",
          [
            if (change.startsWith('local '))
              'Caused by ${causeOf(step)} (${step.id}).'
            else
              'Synced from a write caused by ${causeOf(step)} (${step.id}).',
          ],
          [
            _Block.fields('The record', [
              for (var MapEntry(:key, :value) in data.entries)
                if (key != 'newBucket') (key, '$value'),
              if (data['newBucket'] == true)
                ('bucket', 'new to this phone (first sync)'),
            ]),
          ],
        );
      case BeatKind.subscription:
        var bucket = '${data['bucket']}';
        var subscribed = data['change'] == 'subscribed';
        var under = data['byTime'] == true
            ? "Its cause isn't known, so it is shown under $person's last "
                  'action before it: ${causeOf(step)} (${step.id}).'
            : 'Shown under ${causeOf(step)} (${step.id}), whose write brought '
                  'its first record.';
        return (
          subscribed
              ? "$person's phone subscribed to $bucket."
              : "$person's phone let go of $bucket.",
          [if (subscribed) _heldFrom else _letGo, under],
          [
            _Block.fields('What the phone reported', [
              ('bucket', bucket),
              ('change', '${data['change']}'),
            ]),
          ],
        );
      case BeatKind.job || BeatKind.statements:
        return (
          beat.kind == BeatKind.job
              ? 'The $server server ran ${beat.said}.'
              : 'The $server server ran ${beat.said} in the background.',
          [cause],
          [
            if (beat.folded.isNotEmpty)
              _Block.code(
                'What it ran',
                beat.folded.join('\n'),
                language: 'sql',
              ),
            if (beat.kind == BeatKind.job)
              _Block.fields('The job', _fields(data, leave: const {'step'})),
          ],
        );
      case BeatKind.reload:
        return (
          'The world reloaded the code (${data['step']}).',
          ['What was running then finished on the old code.'],
          const [],
        );
      case BeatKind.log || BeatKind.error || BeatKind.other:
        return (
          switch (beat.kind) {
            BeatKind.log => 'The $server server logged: ${beat.said}',
            BeatKind.error => 'The $server server reported ${beat.said}',
            _ => 'The $server server reported ${beat.said}',
          },
          [cause],
          [_Block.fields('What it reported', _fields(data, leave: const {}))],
        );
    }
  }

  /// A step's own row: what someone did, and a count of what it caused.
  (String, List<String>, List<_Block>) _step(String at) {
    var step = widget.row.step;
    var world = step.person == worldActionsOwner;
    var caused = [
      for (var (step: _, :beats) in widget.trace.steps(step: step.id, limit: 1))
        ...everyBeat(beats),
    ];
    var counts = <String, int>{};
    for (var beat in caused) {
      var noun = switch (beat.kind) {
        BeatKind.call => 'call',
        BeatKind.job => 'job',
        BeatKind.write || BeatKind.statements => 'write',
        BeatKind.reach => 'update',
        BeatKind.sms => 'SMS',
        BeatKind.mail => 'mail',
        BeatKind.push => 'push',
        BeatKind.record => 'synced record',
        BeatKind.subscription => 'subscription',
        _ => null,
      };
      if (noun != null) counts[noun] = (counts[noun] ?? 0) + 1;
    }
    var said = [
      for (var MapEntry(key: noun, value: n) in counts.entries)
        n == 1
            ? 'one $noun'
            : '$n ${noun == 'SMS' || noun == 'push' ? noun : '${noun}s'}',
    ];
    if (step.verb == 'reload') {
      return (
        'The code was reloaded at $at (${step.id}).',
        [?step.note, _afterReload],
        const [],
      );
    }
    return (
      world
          ? 'The world ran its action ${step.target} at $at.'
          : '${step.person} ${Timeline.didOf(step)} at $at.',
      [
        if (said.isEmpty)
          world ? 'It caused nothing.' : 'The app sent nothing.'
        else
          'It caused ${_listed(said)}, shown under it in its colour.',
        if (step.target?.startsWith('at (') ?? false) _unlabelled,
      ],
      const [],
    );
  }

  static const _heldFrom =
      'The phone now receives this bucket, including records written to it '
      'earlier. That is why a record can arrive long after it was written.';

  static const _letGo = 'The phone no longer receives this bucket.';

  static const _afterReload =
      'Everything after this runs the new code, except work that was '
      'already running (a job or a request), which finishes on the old code.';

  static const _unlabelled =
      'There was no label near where it landed, so it is named by its '
      'position.';

  (String, List<String>, List<_Block>) _call(TraceBeat beat, String cause) {
    var data = beat.data;
    var person = beat.person;
    var server = beat.server ?? 'a server';
    var what = '${data['method']} ${data['path']}';
    var answered = data['status'] != null;
    var serverMs = switch (data['ms']) {
      num ms => _ms(ms),
      _ => null,
    };
    var statements = [
      if (beat.folded.isNotEmpty)
        _Block.code('What it ran', beat.folded.join('\n'), language: 'sql'),
    ];
    // The world's script, or a callback: only the server's side exists.
    if (person == null || data['url'] == null) {
      var who = widget.row.from == worldActionsOwner
          ? "The world's script"
          : 'Something outside the apps';
      return (
        '$who called $what on $server, answered ${data['status']}'
            '${serverMs == null ? '' : ' in $serverMs'}.',
        [cause],
        [
          _Block.fields('What the server reported', [
            if (data['part'] case var part?) ('route', '$part'),
            ('status', '${data['status']}'),
            if (serverMs != null) ('took', serverMs),
          ]),
          ...statements,
          _Block.note(
            "The caller's side",
            widget.row.from == worldActionsOwner
                ? "Not recorded. The script isn't an app, so only the "
                      "server's side exists."
                : 'Not recorded. No app here sent it.',
          ),
        ],
      );
    }
    return (
      answered
          ? "$person's app called $what, answered ${data['status']}"
                '${serverMs == null ? '' : ', $serverMs of it in the server'}.'
          : "$person's app called $what on $server, which hasn't answered.",
      [cause, if (data['how'] == 'window') _byWindow],
      [
        _Block.future(
          _request ?? Future.value(const AppRequest.missing('')),
          (context, request) => _appSide(context, request, statements),
        ),
      ],
    );
  }

  static const _byWindow =
      'It was sent outside any tap, so it is matched to the one just before '
      'it.';

  List<_Block> _appSide(
    BuildContext context,
    AppRequest request,
    List<_Block> statements,
  ) {
    var detail = request.detail;
    if (detail == null) {
      return [
        ...statements,
        _Block.note(
          "The app's side",
          request.why == null || request.why!.isEmpty
              ? 'Not available.'
              : request.why!,
        ),
      ];
    }
    var status = networkStatusOf(detail);
    var took = networkDurationOf(detail);
    var response = detail.response;
    var upgrade = networkIsUpgrade(detail);
    return [
      _Block.http(
        'Request',
        line: '${detail.method} ${_hiddenUri(detail.uri)}',
        headers: _headers(detail.request?.headers),
        body: _body(detail.requestBody),
      ),
      _Block.http(
        'Response',
        line: [
          '${status ?? 'no answer yet'}',
          ?response?.reasonPhrase,
          if (took != null) '· ${_ms(took)} in the app',
        ].join(' '),
        headers: _headers(response?.headers),
        body: upgrade
            ? 'A live connection from here on. What passes over it is not '
                  'recorded.'
            : _body(detail.responseBody),
      ),
      ...statements,
    ];
  }

  (String, List<String>, List<_Block>) _sent(TraceBeat beat, String cause) {
    var message = _message;
    var word = switch (beat.kind) {
      BeatKind.sms => 'SMS',
      BeatKind.mail => 'Email',
      _ => 'Push',
    };
    var to = beat.person ?? message?.to ?? '${beat.data['to']}';
    var said = message?.text ?? beat.said;
    var lines = [
      if (message?.byTime ?? false)
        "Its sender doesn't say what caused it, so it is matched to "
            '${causeOf(widget.row.step)} (${widget.row.step.id}), just before '
            'it.'
      else
        cause,
    ];
    if (message == null) {
      return (
        '$word to $to: “$said”',
        lines,
        [_Block.fields('What the server reported', _fields(beat.data))],
      );
    }
    var person = message.person;
    return (
      '$word to $to: “$said”',
      lines,
      [
        _Block.fields('The ${word == 'Email' ? 'email' : word}', [
          if (message.sender case var sender? when sender != beat.server)
            ('from', sender)
          else
            ('from', beat.server ?? ''),
          ('to', person == null ? message.to : '${message.to} ($person)'),
          (
            word == 'Email'
                ? 'subject'
                : word == 'Push'
                ? 'title'
                : 'text',
            message.text,
          ),
          if (message.body case var body? when body != message.text)
            (word == 'Email' ? 'text' : 'body', body),
          if (message.code case var code?)
            (
              'code',
              person == null
                  ? code
                  : "$code (Enter code types it into $person's app)",
            ),
          for (var link in message.links) ('link', link),
        ]),
        if (_picture case var picture?)
          _Block.picture('As ${person ?? message.to} sees it', picture),
      ],
    );
  }

  /// [data] as label and value, a user the world knows by name too.
  List<(String, String)> _fields(
    Map<String, Object?> data, {
    Set<String> leave = const {'step'},
  }) => [
    for (var MapEntry(:key, :value) in data.entries)
      if (!leave.contains(key) && value is! Map && value is! List)
        (
          key,
          switch (value) {
            String user when widget.trace.personOfUser(user) != null =>
              '$user (${widget.trace.personOfUser(user)})',
            _ => '$value',
          },
        ),
  ];
}

/// What caused [step], as a line saying so ends: `Leo's tap on "Order"`.
String causeOf(TraceStep step) {
  var person = step.person;
  var target = step.target ?? '';
  return switch (step.verb) {
    'action' => "the world's action $target",
    'reload' => 'the reload ${step.id}',
    'tap' => "$person's tap on $target",
    'longPress' => "$person's long press on $target",
    'drag' => "$person's drag on $target",
    'type' => "$target entered in $person's app",
    'open' => "$target opened in $person's app",
    'start' => "$person's app starting",
    _ => "$person's ${step.did}",
  };
}

String _listed(List<String> items) => switch (items.length) {
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};

String _ms(num ms) => '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms';

/// What names a secret: its value is cut in what the timeline shows. Run's
/// Network tab has it whole.
final _secret = RegExp(
  'authorization|cookie|token|secret|password|api[-_]?key',
  caseSensitive: false,
);

String _hide(String value) {
  if (value.startsWith('Bearer ') || value.startsWith('Basic ')) {
    var space = value.indexOf(' ');
    return '${value.substring(0, space + 1)}${_hide(value.substring(space + 1))}';
  }
  return value.length <= 8 ? '…(hidden)' : '${value.substring(0, 4)}…(hidden)';
}

String _hiddenUri(Uri uri) => uri.queryParameters.keys.any(_secret.hasMatch)
    ? uri
          .replace(
            queryParameters: {
              for (var MapEntry(:key, :value) in uri.queryParameters.entries)
                key: _secret.hasMatch(key) ? _hide(value) : value,
            },
          )
          .toString()
    : uri.toString();

List<(String, String)> _headers(Map<String, dynamic>? headers) => [
  for (var MapEntry(:key, :value) in (headers ?? const {}).entries)
    (
      key,
      _secret.hasMatch(key)
          ? [
              for (var one in value is List ? value : [value]) _hide('$one'),
            ].join(', ')
          : value is List
          ? value.join(', ')
          : '$value',
    ),
];

/// A body as text: pretty JSON with its secrets cut when it is JSON, the
/// text when it decodes, a byte count when it is binary; empty for none.
String _body(List<int>? bytes) {
  if (bytes == null || bytes.isEmpty) return '';
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return '${bytes.length} bytes of binary data';
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(_cut(jsonDecode(text)));
  } on FormatException {
    return text;
  }
}

Object? _cut(Object? json) => switch (json) {
  Map() => {
    for (var MapEntry(:key, :value) in json.entries)
      '$key': value is String && _secret.hasMatch('$key')
          ? _hide(value)
          : _cut(value),
  },
  List() => [for (var item in json) _cut(item)],
  _ => json,
};

/// One block of a detail: a title, and under it fields, text, code, a
/// picture — or blocks read later.
class _Block {
  const _Block._(
    this.title, {
    this.fields,
    this.note,
    this.code,
    this.language,
    this.line,
    this.picture,
    this.later,
    this.wide = false,
  });

  const _Block.fields(String title, List<(String, String)> fields)
    : this._(title, fields: fields);

  const _Block.note(String title, String note) : this._(title, note: note);

  const _Block.code(String title, String code, {String? language})
    : this._(title, code: code, language: language);

  /// A request or a response: its first line, its headers, its body.
  _Block.http(
    String title, {
    required String line,
    required List<(String, String)> headers,
    required String body,
  }) : this._(
         title,
         line: line,
         fields: headers,
         code: body,
         language: body.startsWith('{') || body.startsWith('[') ? 'json' : null,
       );

  const _Block.picture(String title, Future<WebSnapshot> picture)
    : this._(title, picture: picture, wide: true);

  /// Blocks that wait on something read: they replace this one.
  _Block.future(
    Future<AppRequest> future,
    List<_Block> Function(BuildContext context, AppRequest request) then,
  ) : this._('', later: (future, then));

  final String title;
  final List<(String, String)>? fields;
  final String? note;
  final String? code;
  final String? language;
  final String? line;
  final Future<WebSnapshot>? picture;
  final (Future<AppRequest>, List<_Block> Function(BuildContext, AppRequest))?
  later;

  /// Whether it takes a line of its own rather than a share of one.
  final bool wide;
}

/// Blocks side by side while each has room, one under the other when not.
class _Blocks extends StatelessWidget {
  const _Blocks(this.blocks);

  final List<_Block> blocks;

  @override
  Widget build(BuildContext context) {
    if (blocks case [_Block(:var later?)]) {
      return FutureBuilder(
        future: later.$1,
        builder: (context, read) => switch (read.data) {
          var request? => _Blocks(later.$2(context, request)),
          null => Text(
            'Reading it from the app…',
            style: context.type.bodyMuted,
          ),
        },
      );
    }
    var narrow = [
      for (var block in blocks)
        if (!block.wide) block,
    ];
    var wide = [
      for (var block in blocks)
        if (block.wide) block,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        var side = constraints.maxWidth >= 360.0 * max(narrow.length, 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (side && narrow.length > 1)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var (i, block) in narrow.indexed) ...[
                      if (i > 0) const SizedBox(width: FwSpacing.lg),
                      Expanded(child: _BlockView(block)),
                    ],
                  ],
                ),
              )
            else
              for (var (i, block) in narrow.indexed) ...[
                if (i > 0) const SizedBox(height: FwSpacing.lg),
                _BlockView(block),
              ],
            for (var block in wide) ...[
              if (narrow.isNotEmpty) const SizedBox(height: FwSpacing.lg),
              _BlockView(block),
            ],
          ],
        );
      },
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView(this.block);

  final _Block block;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono.copyWith(
      fontSize: context.type.bodySmall.fontSize,
    );
    var fields = block.fields ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          block.title.toUpperCase(),
          style: context.type.sectionLabel.copyWith(color: colors.mut),
        ),
        const SizedBox(height: FwSpacing.sm),
        if (block.line case var line?)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.sm),
            child: SelectableText(
              line,
              style: mono.copyWith(color: colors.ink),
            ),
          ),
        if (fields.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.md,
              vertical: FwSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.bg,
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              border: Border.all(color: colors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var (label, value) in fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 120,
                          child: Text(
                            label,
                            style: mono.copyWith(color: colors.mut),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: FwSpacing.md),
                        Expanded(
                          child: SelectableText(
                            value,
                            style: context.type.bodySmall.copyWith(
                              color: colors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (block.code case var code? when code.isNotEmpty) ...[
          if (fields.isNotEmpty) const SizedBox(height: FwSpacing.sm),
          FwCodeBlock(
            code,
            language: block.language,
            wrap: true,
            maxHeight: 260,
            padding: const EdgeInsets.all(FwSpacing.md),
          ),
        ],
        if (block.note case var note?)
          Text(note, style: context.type.bodySmall.copyWith(color: colors.mut)),
        if (block.picture case var picture?) _MailPicture(picture),
      ],
    );
  }
}

/// A mail as WebKit drew it, at most as wide as a phone's mail app shows it.
class _MailPicture extends StatelessWidget {
  const _MailPicture(this.future);

  final Future<WebSnapshot> future;

  static const _widest = 420.0;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, drawn) {
      if (drawn.error case var error?) {
        return Text('Could not draw it: $error', style: context.type.bodyMuted);
      }
      var page = drawn.data;
      if (page == null) {
        return Text('Drawing the mail…', style: context.type.bodyMuted);
      }
      var scale = min(1.0, _widest / page.width);
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: page.width * scale,
          height: min(page.height * scale, 480),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            border: Border.all(color: context.colors.line),
          ),
          child: Image.file(
            File(page.picture),
            fit: BoxFit.fitWidth,
            alignment: Alignment.topCenter,
            filterQuality: FilterQuality.medium,
          ),
        ),
      );
    },
  );
}
