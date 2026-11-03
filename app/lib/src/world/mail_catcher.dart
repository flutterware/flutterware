import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/plugins.dart' show MailCatcherKind;
// ignore: implementation_imports
import 'package:flutterware/src/world/mail_inbox.dart' show InboxMail;

/// A mail catcher a world reads: one a dev stack service declares, with its
/// port worked out for this checkout.
class WorldMailCatcher {
  WorldMailCatcher({
    required this.name,
    required this.kind,
    required this.api,
    Map<String, String> senders = const {},
  }) : senders = {
         for (var entry in senders.entries)
           entry.key.trim().toLowerCase(): entry.value,
       };

  /// Who sent a mail [senders] does not name.
  final String name;

  final MailCatcherKind kind;

  /// Where its web interface answers: `http://localhost:1080/`.
  final Uri api;

  /// Who sent a mail, by its `From` address, lower-cased.
  final Map<String, String> senders;

  /// Who sent [mail]: the service its `From` address belongs to, else the
  /// catcher itself.
  String senderOf(InboxMail mail) {
    for (var address in [?mail.from, ?mail.sender]) {
      if (senders[address.toLowerCase()] case var sender?) return sender;
    }
    return name;
  }
}

/// A mail [WorldMailCatcher] caught, once for each address it went to.
typedef CaughtMail = ({String to, String sender, InboxMail mail});

/// Reads a [WorldMailCatcher] while a world is open, and hands every mail it
/// catches from then on to [CatcherWatch.start]'s `onMail`.
abstract interface class CatcherWatch {
  /// Starts reading [catcher]. Answers once it knows which mails were there
  /// before, or has said in [say] that it cannot reach the catcher yet. Until
  /// it can, it tries again every second; the mails it then finds that
  /// arrived after [opened] are new.
  static Future<CatcherWatch> start(
    WorldMailCatcher catcher, {
    required DateTime opened,
    required void Function(CaughtMail mail) onMail,
    required void Function(String line) say,
  }) => switch (catcher.kind) {
    MailCatcherKind.mailcatcher => MailcatcherWatch.start(
      catcher,
      opened: opened,
      onMail: onMail,
      say: say,
    ),
  };

  Future<void> close();
}

/// [CatcherWatch] over [Mailcatcher](https://mailcatcher.me)'s API: the
/// websocket at `/messages` announces each mail, `GET /messages` lists them,
/// and `/messages/:id.source` is one as it was sent. While the websocket is
/// not open, the list is read every second instead.
class MailcatcherWatch implements CatcherWatch {
  MailcatcherWatch._(this.catcher, this._opened, this._onMail, this._say);

  static Future<MailcatcherWatch> start(
    WorldMailCatcher catcher, {
    required DateTime opened,
    required void Function(CaughtMail mail) onMail,
    required void Function(String line) say,
  }) async {
    var watch = MailcatcherWatch._(catcher, opened, onMail, say);
    say('Reading the mail ${catcher.name} catches, at ${catcher.api}');
    await watch._run(() => watch._list(starting: true));
    await watch._connect();
    watch._timer = Timer.periodic(pollEvery, (_) => watch._tick());
    return watch;
  }

  /// How often the list is read while the websocket is closed.
  static const pollEvery = Duration(seconds: 1);

  /// How often a closed websocket is opened again.
  static const reconnectEvery = Duration(seconds: 5);

  static const _timeout = Duration(seconds: 5);

  final WorldMailCatcher catcher;
  final DateTime _opened;
  final void Function(CaughtMail mail) _onMail;
  final void Function(String line) _say;
  final _http = HttpClient()..connectionTimeout = _timeout;

  /// The mails that were there before the world opened, by [_key]; null
  /// until the catcher first answered.
  Set<String>? _before;
  final _seen = <String>{};
  WebSocket? _socket;
  Timer? _timer;
  DateTime? _lastConnect;
  Future<void> _queue = Future.value();
  String? _problem;
  var _closed = false;

  /// A mail by its id and when it came: an id is used again once the
  /// catcher's list is cleared.
  static String _key(Map<Object?, Object?> message) =>
      '${message['id']}@${message['created_at']}';

  /// One at a time, in the order they were asked for: two reads of the list
  /// at once would hand the same new mail on twice.
  Future<void> _run(Future<void> Function() work) =>
      _queue = _queue.then((_) => _closed ? null : work());

  void _tick() {
    if (_closed || _socket != null) return;
    unawaited(_run(_list));
    var last = _lastConnect;
    if (_before != null &&
        (last == null || DateTime.now().difference(last) >= reconnectEvery)) {
      unawaited(_connect());
    }
  }

  Future<void> _list({bool starting = false}) async {
    List<Object?> messages;
    try {
      messages = jsonDecode(utf8.decode(await _get('messages'))) as List;
    } on Object catch (error) {
      _fail(
        '${catcher.name} is not answering at ${catcher.api}: $error. A mail '
        'it catches reaches nobody until it answers.',
      );
      return;
    }
    _answered();
    // Everything listed at the start was there before the world. Listed
    // later, once the catcher came up, a mail is new if it came after.
    _before ??= {
      for (var message in messages.whereType<Map<Object?, Object?>>())
        if (starting || !_cameAfterOpening(message)) _key(message),
    };
    for (var message in messages.whereType<Map<Object?, Object?>>()) {
      await _consider(message);
    }
  }

  bool _cameAfterOpening(Map<Object?, Object?> message) {
    var at = DateTime.tryParse('${message['created_at']}');
    // Whole seconds: one in the second the world opened may be after it.
    var second = DateTime.fromMillisecondsSinceEpoch(
      _opened.millisecondsSinceEpoch ~/ 1000 * 1000,
    );
    return at != null && !at.isBefore(second);
  }

  Future<void> _consider(Map<Object?, Object?> message) async {
    var before = _before;
    if (before == null || message['id'] == null) return;
    var key = _key(message);
    if (before.contains(key) || !_seen.add(key)) return;
    Uint8List source;
    try {
      source = await _get('messages/${message['id']}.source');
    } on Object catch (error) {
      _seen.remove(key);
      _fail('${catcher.name} did not hand over mail ${message['id']}: $error');
      return;
    }
    var mail = InboxMail.parse(
      source,
      sender: _bare('${message['sender'] ?? ''}'),
      recipients: [
        for (var recipient in message['recipients'] as List? ?? const [])
          ?_bare('$recipient'),
      ],
    );
    var sender = catcher.senderOf(mail);
    for (var to in mail.recipients.isNotEmpty ? mail.recipients : mail.to) {
      try {
        _onMail((to: to, sender: sender, mail: mail));
      } on Object catch (error) {
        _say('A mail ${catcher.name} caught: $error');
      }
    }
  }

  /// An address as Mailcatcher lists it, `<ana@example.com>`, or with the
  /// SMTP parameters it keeps after the sender: `<ana@example.com> size=630`.
  static String? _bare(String listed) {
    var address = switch (RegExp('<([^>]*)>').firstMatch(listed)) {
      var match? => match[1]!,
      null => listed.split(' ').first,
    };
    address = address.trim();
    return address.isEmpty ? null : address;
  }

  Future<void> _connect() async {
    _lastConnect = DateTime.now();
    var url = catcher.api.replace(
      scheme: catcher.api.scheme == 'https' ? 'wss' : 'ws',
    );
    WebSocket socket;
    try {
      socket = await WebSocket.connect(url.resolve('messages').toString())
          .timeout(_timeout);
    } on Object {
      return; // Read every second instead.
    }
    if (_closed) {
      unawaited(socket.close());
      return;
    }
    _socket = socket;
    socket.listen(
      (frame) {
        Object? announced;
        try {
          announced = jsonDecode('$frame');
        } on FormatException {
          return;
        }
        var message = switch (announced) {
          {'type': 'add', 'message': Map<Object?, Object?> message} => message,
          // Before 0.8, the mail itself, with no envelope around it.
          {'id': int _, 'created_at': _} => announced,
          _ => null,
        };
        if (message != null) unawaited(_run(() => _consider(message)));
      },
      onDone: () => _socket = null,
      onError: (Object _) => _socket = null,
      cancelOnError: true,
    );
    // What came while it was closed.
    unawaited(_run(_list));
  }

  Future<Uint8List> _get(String path) async {
    var request = await _http
        .getUrl(catcher.api.resolve(path))
        .timeout(_timeout);
    var response = await request.close().timeout(_timeout);
    var body = await response
        .fold(BytesBuilder(copy: false), (bytes, chunk) => bytes..add(chunk))
        .timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode} for /$path');
    }
    return body.takeBytes();
  }

  /// Says [problem], once until the catcher answers again.
  void _fail(String problem) {
    if (_problem != null) return;
    _problem = problem;
    _say(problem);
  }

  void _answered() {
    if (_problem == null) return;
    _problem = null;
    _say('${catcher.name} answers again at ${catcher.api}');
  }

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _socket?.close();
    _socket = null;
    _http.close(force: true);
  }
}
