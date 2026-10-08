/// What the app did — one report, and whichever surfaces are listening.
///
/// The app calls [recordAppEvent] once. A scenario run reads it off
/// [appEventBuffer] and shows it on the step's Events pane; a mounted devbar
/// reads it off [addAppEventListener] and shows it on its own tabs. Neither
/// is wired by the project, and neither knows about the other.
///
/// Deliberately free of every Flutter import: a project's fakes report through
/// [recordAppEvent], and a fake that lives in `lib/` must not drag
/// `flutter_test` into production code. `identity_hash.dart` is plain Dart for
/// the same reason, and is here because an event carries the framework's
/// identity hashes exactly the way a widget's properties do. That is also why
/// the devbar registers *into* here rather than being called from here.
library;

import 'dart:async';

import '../utils/identity_hash.dart';

/// The channel an event travelled on — what the panel filters and groups by.
///
/// A fixed vocabulary for the kinds that earn a rendering of their own, plus
/// whatever a [AppEvent.custom] names. Strings rather than an enum
/// because the set is open at the far end and every surface serialises it.
abstract final class AppChannel {
  /// An HTTP request, however the app made it.
  static const network = 'network';

  /// A database statement.
  static const db = 'db';

  /// A product analytics event.
  static const analytics = 'analytics';

  /// A `package:logging` record, or anything else log-shaped.
  static const log = 'log';

  /// A `print` or `debugPrint` from the app.
  static const print = 'print';

  /// A platform channel message — a plugin talking to its host.
  static const platform = 'platform';

  /// A framework channel (`flutter/…`). Captured, because "did the app ask for
  /// the keyboard" is a real question, and hidden by default, because on an
  /// ordinary transition it is the only thing you would see.
  static const system = 'system';
}

/// One thing that happened on the way from one step to the next.
class AppEvent {
  const AppEvent.custom({
    required this.channel,
    required this.title,
    this.detail,
    this.data = const {},
    this.body,
    this.error = false,
    this.level,
    this.origin,
  });

  /// An HTTP request: `POST /login → 401`.
  AppEvent.request({
    required String method,
    required String url,
    int? status,
    this.data = const {},
    this.body,
  }) : channel = AppChannel.network,
       title = '$method $url',
       detail = status?.toString(),
       error = status != null && status >= 400,
       level = null,
       origin = null;

  /// A database statement, with the SQL as the body so it can be read whole.
  ///
  /// Report the app's own statements, not the schema's. Opening a database
  /// costs a dozen before the app has done anything — `BEGIN IMMEDIATE`, the
  /// migration bookkeeping, the `create table`s, `COMMIT` — and measured on a
  /// real suite that was 1680 of 1874 events, 89% of the channel, drowning the
  /// 194 that were the app. It takes measuring to notice, because a busy pane
  /// looks like a working one. Keep the decorator quiet until the database has
  /// finished opening.
  AppEvent.query({
    required String sql,
    List<Object?> args = const [],
    int? rows,
  }) : channel = AppChannel.db,
       title = foldSql(sql),
       detail = rows == null ? null : '$rows ${rows == 1 ? 'row' : 'rows'}',
       data = args.isEmpty ? const {} : {'args': args},
       body = sql,
       error = false,
       level = null,
       origin = null;

  /// A product analytics event and its parameters.
  AppEvent.analytics(String name, {Map<String, Object?> params = const {}})
    : channel = AppChannel.analytics,
      title = name,
      detail = null,
      data = params,
      body = null,
      error = false,
      level = null,
      origin = null;

  /// A log line.
  AppEvent.log(String message, {this.level, String? logger})
    : channel = AppChannel.log,
      title = message,
      detail = logger,
      data = const {},
      body = null,
      origin = null,
      error = level == 'SEVERE' || level == 'SHOUT';

  /// Decodes what [toJson] wrote — an entry of a step's `.events.json`.
  ///
  /// Lenient like every published reader here: an event a fake reported with
  /// a channel of its own still decodes, and a field this version does not
  /// know is ignored. The caps [toJson] applies are already in the text, so a
  /// round-tripped title reads exactly as the panel showed it.
  factory AppEvent.fromJson(Map<String, Object?> json) => AppEvent.custom(
    channel: json['channel'] as String? ?? '',
    title: json['title'] as String? ?? '',
    detail: json['detail'] as String?,
    data: switch (json['data']) {
      Map data => data.cast<String, Object?>(),
      _ => const {},
    },
    body: json['body'] as String?,
    error: json['error'] == true,
    level: json['level'] as String?,
    origin: json['origin'] as String?,
  );

  /// One of [AppChannel]'s constants, or a name of the reporter's own.
  final String channel;

  /// The one-line summary — what the list shows, and what an agent reads.
  final String title;

  /// Trailing detail beside the title: a status code, a row count, a logger
  /// name. Null where the title says everything.
  final String? detail;

  /// The structured payload, shown when a row is expanded.
  final Map<String, Object?> data;

  /// Long text — a SQL statement, a JSON body, a stack. Kept apart from [data]
  /// because it is rendered as text rather than as fields.
  final String? body;

  /// Whether this event is itself a problem: a 4xx/5xx, a severe log, a
  /// channel call that came back an error. Tints the row; never fails a step.
  final bool error;

  /// The log level, for [AppChannel.log] events.
  final String? level;

  /// Where the app made this event — `package:app/src/cart.dart Cart.checkout`.
  ///
  /// Filled in by [AppEventBuffer], never by the reporter: an app calls
  /// [recordAppEvent] and the stack at that moment says where from. Null
  /// outside a scenario run, and null inside one when the trace was cut by an
  /// asynchronous gap and left no frame to name.
  ///
  /// **Never compared.** It exists so a reader can exclude a whole file's
  /// worth of noise — *not the db events out of `lib/data/cache.dart`* — and a
  /// line number moves whenever anything above it does, so an origin inside
  /// the compared set would report every event as changed on any edit. That is
  /// also why it keeps the file and the symbol and drops the `line:col` the
  /// frame came with.
  final String? origin;

  /// What a step's `.events.json` records — **normalised, then capped.**
  ///
  /// That order is the whole of it. A cap writes a count of what it cut, and a
  /// count is a derived field: computed over un-normalised text it absorbs
  /// every identity hash in the payload, and no later rule can reach it. Two
  /// runs of one commit differed only in `… (1429 more characters)` against
  /// `… (1432 more characters)` for exactly this reason.
  /// This event, saying where it was made. See [AppEventBuffer.drain].
  AppEvent _at(String? origin) => AppEvent.custom(
    channel: channel,
    title: title,
    detail: detail,
    data: data,
    body: body,
    error: error,
    level: level,
    origin: origin,
  );

  Map<String, Object?> toJson() => {
    'channel': channel,
    'title': _cap(withoutIdentityHash(title), _maxTitleChars),
    'detail': ?(detail == null ? null : withoutIdentityHash(detail!)),
    if (data.isNotEmpty) 'data': _capData(data),
    if (body != null) 'body': _cap(withoutIdentityHash(body!), _maxBodyChars),
    if (error) 'error': true,
    'level': ?level,
    'origin': ?origin,
  };
}

/// A SQL statement on one line — what a title is made of.
///
/// Folded rather than cut at the first newline, which is what this used to
/// do. A generator emits one line, so its statement titled whole; a person
/// formats theirs across several with the keyword alone on the first, so it
/// titled `select …`. Measured on a real suite, 110 of 194 db events were
/// that one string — a list of rows saying nothing, about half the channel,
/// and which half depended only on who wrote the SQL.
///
/// Worse than unreadable, it was wrong: the comparison channel keys an event
/// on its channel and title, so every hand-formatted `select` shared one key
/// and a branch that swapped one query for another reported no difference at
/// all.
///
/// The literals stay. Blanking them is [normalizeSql]'s job and it is the
/// right one for *grouping*, where an N+1's queries must collapse — but a
/// title is read, and `version >= 3` says more than `version >= ?` for the
/// same width. Grouping is unharmed: the comparison mask already folds digits
/// to `#`, so N+1 siblings still meet.
String foldSql(String sql) => sql.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Per-event caps. An app that logs in a build method would otherwise write a
/// run measured in tens of megabytes; every one of these leaves a marker
/// rather than truncating quietly.
const _maxTitleChars = 300;
const _maxBodyChars = 4000;
const _maxDataChars = 4000;

/// How much of one *leaf* of a payload is kept.
const _maxLeafChars = 512;

/// What a number, a bool or a null is charged against the payload's budget.
/// Nobody's rendering is exactly this; the budget only has to be bounded.
const _scalarWidth = 8;

/// How many events one transition keeps, and how many one **scenario** keeps
/// in total — the buffer lives for exactly one scenario, so the second is the
/// ceiling across all of its steps, replays included.
const maxAppEventsPerStep = 200;
const maxAppEventsPerRun = 5000;

String _cap(String text, int limit) => text.length <= limit
    ? text
    : '${text.substring(0, limit)}… (${text.length - limit} more characters)';

/// A payload capped **per leaf**, with its shape kept.
///
/// This used to stringify the whole map and, past the limit, replace it with
/// the truncation — which is the one thing a payload must not do. The count in
/// `… (1429 more characters)` is taken over every leaf at once, so a single
/// volatile field moved a number standing for the entire payload, and the
/// structure it stood for was gone. Measured on a real suite, 11 of 1071 event
/// files still differed after every known noise source had been normalised
/// away, and every one of them differed only in that counter.
///
/// Per leaf, a volatile field is one leaf and every other one compares
/// exactly. The budget is still bounded — a payload wide enough to exhaust it
/// stops and says how many fields it dropped, rather than collapsing the ones
/// it had already kept.
Object? _capData(Map<String, Object?> data) {
  var remaining = _maxDataChars;
  var dropped = 0;

  Object? walk(Object? value) {
    if (value is Map) {
      var out = <String, Object?>{};
      for (var entry in value.entries) {
        if (remaining <= 0) {
          dropped++;
          continue;
        }
        var key = '${entry.key}';
        remaining -= key.length;
        out[key] = walk(entry.value);
      }
      return out;
    }
    if (value is List) {
      var out = <Object?>[];
      for (var item in value) {
        if (remaining <= 0) {
          dropped++;
          continue;
        }
        out.add(walk(item));
      }
      return out;
    }
    if (value is String) {
      var capped = _cap(withoutIdentityHash(value), _maxLeafChars);
      remaining -= capped.length;
      return capped;
    }
    remaining -= _scalarWidth;
    return value;
  }

  var capped = walk(data)! as Map<String, Object?>;
  return dropped == 0 ? capped : {...capped, '…': '$dropped more fields'};
}

/// Reports [event] to every surface that is listening.
///
/// Inside a scenario it lands on the current transition, and the step's Events
/// pane shows it. Inside a running app it lands on a mounted devbar's tabs.
/// Both at once, if both are there; neither is wired by the project.
///
/// A no-op — one null check and an empty list — when nothing is listening,
/// which is every bare `flutter test` run. That is what makes it safe for a
/// project to leave these calls in its shared fakes forever, and it holds all
/// the way: a listener that throws is reported to the [Zone] and skipped
/// rather than surfacing here, and one that unregisters itself mid-report
/// costs its neighbours nothing.
///
/// ```dart
/// class FakeApi implements Api {
///   Future<User> login(String email) async {
///     recordAppEvent(AppEvent.request(
///         method: 'POST', url: '/login', status: 200));
///     return User(email);
///   }
/// }
/// ```
///
/// [source] names the reporter, for the one case where a surface has already
/// been handed this event by another route: a listener registered with a
/// matching `ignoreSource` skips it. Everybody else — the buffer, and every
/// other listener — sees it normally. See [addAppEventListener].
void recordAppEvent(AppEvent event, {Object? source}) {
  // The stack is captured here and resolved much later, and the split is the
  // whole reason this is affordable. Measured JIT at a hundred frames — the
  // depth of a widget test — capturing costs 3.5 µs and resolving it costs
  // 78.6 µs, so resolving every event at the run cap would be ~390 ms a
  // scenario. Captured here and resolved in [AppEventBuffer.drain], the
  // expensive half is paid only for the events that survive the per-step cap
  // and reach a file.
  //
  // Behind the buffer's null check, which is already the first thing this
  // function does: a production app and a plain `flutter test` have no buffer
  // and pay nothing at all.
  appEventBuffer?.add(event, StackTrace.current);
  if (_listeners.isEmpty) return;
  // Over a copy, and never over the live list. A listener that unregisters on
  // its way out — a devbar disposing mid-report — shifts everything behind it
  // down a slot, so a walk by index silently *skips* its neighbour and a
  // for-in throws a concurrent modification. Neither is acceptable: the whole
  // promise of this call is that reporting cannot disturb the app.
  for (var registration in List.of(_listeners)) {
    if (source != null && registration.ignoreSource == source) continue;
    try {
      registration.listener(event);
    } on Object catch (e, stack) {
      // A surface that breaks may not take the app's own call with it — this
      // is a line in somebody's fake, not a place to fail. Loud, but not here:
      // the zone reports it the way an unhandled async error is reported.
      Zone.current.handleUncaughtError(e, stack);
    }
  }
}

/// The first frame of [trace] that is not this package's own, as
/// `package:app/src/cart.dart Cart.checkout`.
///
/// flutterware's frames are skipped because the app is what a reader means by
/// where an event came from: [recordAppEvent] is always frame zero and says
/// nothing. `dart:` frames go for the same reason. Whatever is left first —
/// the app's fake, its data layer, or the framework call that sent a platform
/// message — is the answer, and it is the truthful one even when it is not the
/// call site somebody hoped for.
///
/// The `line:col` the frame carries is dropped on purpose. It contributes
/// nothing to *exclude everything from this file* and it is the churn that
/// would make the value worthless: a line moves whenever anything above it
/// does. Null when an asynchronous gap cut the trace before any such frame.
String? originOf(StackTrace trace) {
  for (var line in trace.toString().split('\n')) {
    var frame = _frame.firstMatch(line);
    if (frame == null) continue;
    var uri = frame.group(2)!;
    if (uri.startsWith('package:flutterware/') || uri.startsWith('dart:')) {
      continue;
    }
    return '$uri ${frame.group(1)}';
  }
  return null;
}

/// `#12     Cart.checkout (package:app/src/cart.dart:41:7)` — the VM's own
/// rendering, symbol then parenthesised location.
final _frame = RegExp(r'^#\d+\s+(.+?)\s+\(([^\s()]+?):\d+(?::\d+)?\)\s*$');

/// Set by the harness for the duration of one scenario run; null everywhere
/// else. The seam between the reporting API and the runner, like
/// `scenarioRunListener` — not part of the authoring surface.
AppEventBuffer? appEventBuffer;

final _listeners = <_Registration>[];

class _Registration {
  _Registration(this.listener, this.ignoreSource);

  final void Function(AppEvent) listener;
  final Object? ignoreSource;
}

/// Subscribes [listener] to every event reported from now on, and returns the
/// call that unsubscribes it.
///
/// The seam a live surface uses, where a scenario run uses [appEventBuffer].
/// A devbar registers one while it is mounted; a project can register its own.
///
/// Pass [ignoreSource] to skip events a particular reporter tagged, for a
/// surface that reporter already handed a copy to directly. That is how a
/// devbar avoids listing a `DevbarHttpClient` request twice — it is given the
/// exchange in two halves as it happens, so it ignores the one-piece report
/// the same client makes for everybody else.
///
/// A listener that throws is reported to the current [Zone] and skipped; it
/// never reaches the app code that called [recordAppEvent].
///
/// Applies no cap of its own — a live surface keeps whatever history it wants,
/// and the devbar's tabs already bound theirs.
void Function() addAppEventListener(
  void Function(AppEvent) listener, {
  Object? ignoreSource,
}) {
  var registration = _Registration(listener, ignoreSource);
  _listeners.add(registration);
  return () => _listeners.remove(registration);
}

/// What has been recorded since the last capture.
///
/// Whatever is in here when a step captures is what happened on the way
/// to it.
class AppEventBuffer {
  final _events = <(AppEvent, StackTrace)>[];

  /// Dropped since the last drain, and over the whole run — reported on the
  /// step, because silence would read as "the app did nothing".
  var _dropped = 0;
  var _total = 0;

  void add(AppEvent event, StackTrace trace) {
    if (_events.length >= maxAppEventsPerStep || _total >= maxAppEventsPerRun) {
      _dropped++;
      return;
    }
    _total++;
    _events.add((event, trace));
  }

  /// The transition's events, and how many were dropped to stay inside the
  /// caps. Empties the buffer.
  ///
  /// Where each event's [AppEvent.origin] is resolved. The stack was taken
  /// when the event was recorded; symbolising it is twenty times dearer than
  /// taking it, so it happens here — once per event that survived the caps and
  /// is about to be written — rather than once per event ever recorded.
  (List<AppEvent>, int) drain() {
    var drained = (
      [
        for (var (event, trace) in _events)
          event.origin != null ? event : event._at(originOf(trace)),
      ],
      _dropped,
    );
    _events.clear();
    _dropped = 0;
    return drained;
  }

  /// Throws the buffer away without reporting it — a `split` replay walking a
  /// prefix that was captured on an earlier path. Its events were recorded the
  /// first time through; recording them again would multiply them per branch.
  void discard() {
    _events.clear();
    _dropped = 0;
  }
}
