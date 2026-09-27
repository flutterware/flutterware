import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A local SMTP server for a world: a service in the stack that sends its own
/// mail is pointed at it, and every mail that service sends is decoded and
/// handed to `onMail`, the way a Dart server reports a mail it sends.
///
/// It accepts every mail from anyone to anyone. Any `AUTH` succeeds, so a
/// service configured with a username and password needs no change beyond the
/// host and port. It speaks plain SMTP only and never offers STARTTLS, so a
/// service set to require TLS will not send through it.
///
/// With a `relay`, each mail also goes on, unchanged, to another SMTP server,
/// usually the stack's own mail catcher, so the stack keeps showing what it
/// showed before the world stepped in between.
final class MailInbox {
  MailInbox._(this._server, this._onMail, this._relay, this._onRelayError);

  /// Listens on [port] (0 picks a free one) on the loopback address unless
  /// [address] says otherwise, and calls [onMail] with each mail received.
  ///
  /// [onMail] is called once the client has been told the mail was accepted.
  /// If it throws, that mail is not reported, but the client, the relay and
  /// every later mail are unaffected: a handler that cares about its errors
  /// catches them itself.
  ///
  /// With a [relay], every mail is forwarded to that SMTP server in the
  /// background, one at a time in the order they arrived, with the envelope
  /// it came with. A mail the relay could not take is reported to
  /// [onRelayError] as a [MailRelayException], or dropped silently without
  /// one; either way the client that sent it was already told it was
  /// accepted.
  static Future<MailInbox> start({
    required void Function(InboxMail mail) onMail,
    int port = 0,
    InternetAddress? address,
    ({String host, int port})? relay,
    void Function(Object error)? onRelayError,
  }) async {
    var server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    var inbox = MailInbox._(server, onMail, relay, onRelayError);
    inbox._subscription = server.listen(inbox._accept);
    return inbox;
  }

  static const _relayConnectTimeout = Duration(seconds: 5);
  static const _relayReplyTimeout = Duration(seconds: 10);
  static const _drainTimeout = Duration(seconds: 3);

  final ServerSocket _server;
  final void Function(InboxMail mail) _onMail;
  final ({String host, int port})? _relay;
  final void Function(Object error)? _onRelayError;
  late final StreamSubscription<Socket> _subscription;
  final _sessions = <_Session>{};
  var _relayQueue = Future<void>.value();
  Socket? _relaying;
  var _closed = false;
  var _relayAbandoned = false;

  /// The port it listens on.
  int get port => _server.port;

  /// Stops accepting connections and drops the ones still open, then waits a
  /// few seconds at most for the mails already received to reach the relay.
  /// Whatever the relay has not taken by then is abandoned without an error.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close();
    for (var session in _sessions.toList()) {
      session.end();
    }
    await _relayQueue.timeout(
      _drainTimeout,
      onTimeout: () {
        _relayAbandoned = true;
        _relaying?.destroy();
      },
    );
  }

  void _accept(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    _sessions.add(_Session(this, socket));
  }

  void _received(Uint8List raw, String? sender, List<String> recipients) {
    try {
      _onMail(InboxMail.parse(raw, sender: sender, recipients: recipients));
    } catch (_) {
      // Documented on [start]: the handler's failure is the handler's.
    }
    if (_relay case var relay?) {
      _relayQueue = _relayQueue.then(
        (_) => _relayOne(relay, raw, sender, recipients),
      );
    }
  }

  Future<void> _relayOne(
    ({String host, int port}) relay,
    Uint8List raw,
    String? sender,
    List<String> recipients,
  ) async {
    if (_relayAbandoned) return;
    var target = '${relay.host}:${relay.port}';
    Socket? socket;
    _Replies? replies;
    try {
      socket = await Socket.connect(
        relay.host,
        relay.port,
        timeout: _relayConnectTimeout,
      );
      _relaying = socket;
      socket.done.ignore();
      var open = socket;
      var reader = replies = _Replies(socket);

      Future<_Reply> ask(String? command) {
        if (command != null) open.write('$command\r\n');
        return reader.next().timeout(_relayReplyTimeout);
      }

      Future<void> require(String? command, int kind) async {
        var reply = await ask(command);
        if (reply.code ~/ 100 != kind) {
          throw MailRelayException(
            '$target answered "${reply.text}" to '
            '${command ?? 'the connection'}',
          );
        }
      }

      await require(null, 2);
      if ((await ask('EHLO localhost')).code ~/ 100 != 2) {
        await require('HELO localhost', 2);
      }
      await require('MAIL FROM:<${sender ?? ''}>', 2);
      for (var recipient in recipients) {
        await require('RCPT TO:<$recipient>', 2);
      }
      await require('DATA', 3);
      socket.add(_dotStuffed(raw));
      await require('.', 2);
      try {
        await ask('QUIT');
      } catch (_) {
        // The mail is delivered; how the relay says goodbye does not matter.
      }
    } catch (error) {
      if (_relayAbandoned) return;
      _reportRelayError(
        error is MailRelayException
            ? error
            : MailRelayException(
                'could not relay the mail to ${recipients.join(', ')} '
                'through $target: $error',
                cause: error,
              ),
      );
    } finally {
      _relaying = null;
      await replies?.cancel();
      socket?.destroy();
    }
  }

  void _reportRelayError(MailRelayException error) {
    try {
      _onRelayError?.call(error);
    } catch (_) {
      // A failing error handler must not stop the relay queue.
    }
  }
}

/// A mail [MailInbox] could not hand on to its relay.
final class MailRelayException implements Exception {
  MailRelayException(this.message, {this.cause});

  /// What went wrong, naming the relay.
  final String message;

  /// The underlying error, such as a [SocketException] for a relay that is
  /// not listening, or null when the relay answered with a refusal.
  final Object? cause;

  @override
  String toString() => 'MailRelayException: $message';
}

/// A mail as [MailInbox] received it: its envelope, and what a person reading
/// it would see.
final class InboxMail {
  InboxMail({
    this.sender,
    this.recipients = const [],
    this.from,
    this.to = const [],
    this.subject,
    this.text,
    this.html,
    required this.received,
  });

  /// Decodes the message [raw], as it arrived after the SMTP `DATA` command
  /// with its dot-stuffing already undone. [sender] and [recipients] are the
  /// envelope, which the message itself does not carry.
  ///
  /// Decoding never fails: whatever cannot be read is left null, and bytes
  /// that are not valid in their charset become replacement characters.
  factory InboxMail.parse(
    List<int> raw, {
    String? sender,
    List<String> recipients = const [],
    DateTime? received,
  }) {
    var message = _Entity.parse(
      raw is Uint8List ? raw : Uint8List.fromList(raw),
    );
    var bodies = _Bodies()..collect(message, 0);
    return InboxMail(
      sender: sender,
      recipients: List.unmodifiable(recipients),
      from: _addresses(message.headers['from']).firstOrNull,
      to: List.unmodifiable(_addresses(message.headers['to'])),
      subject: switch (message.headers['subject']) {
        var subject? => _decodeEncodedWords(subject),
        null => null,
      },
      text: bodies.text,
      html: bodies.html,
      received: received ?? DateTime.now(),
    );
  }

  /// The envelope sender (`MAIL FROM`), as a bare address, or null for the
  /// null sender `<>` that bounces use.
  final String? sender;

  /// The envelope recipients (`RCPT TO`), as bare addresses: who the mail was
  /// actually delivered to, Bcc included.
  final List<String> recipients;

  /// The address in the `From` header, without its display name.
  final String? from;

  /// The addresses in the `To` header, without their display names.
  final List<String> to;

  /// The `Subject` header, with any encoded words decoded.
  final String? subject;

  /// The first `text/plain` part that is not an attachment, decoded, with its
  /// line breaks as `\n`. A message with no `Content-Type` is plain text.
  final String? text;

  /// The first `text/html` part that is not an attachment, decoded, with its
  /// line breaks as `\n`.
  final String? html;

  /// When it was received.
  final DateTime received;

  @override
  String toString() => 'InboxMail($from to ${to.join(', ')}: $subject)';
}

const _serverName = 'flutterware';
const _cr = 0x0d;
const _lf = 0x0a;
const _dot = 0x2e;
final _crlf = Uint8List.fromList([_cr, _lf]);

enum _State { command, authPlain, authLoginUser, authLoginPassword, data }

/// One client connected to a [MailInbox].
final class _Session {
  _Session(this._inbox, this._socket) {
    _socket.done.ignore();
    _subscription = _socket.listen(
      _onBytes,
      onError: (Object _) => end(),
      onDone: end,
      cancelOnError: true,
    );
    _reply('220 $_serverName ESMTP');
  }

  static final _mailFrom = RegExp(
    r'^FROM:\s*(<[^>]*>|[^\s<>]+)',
    caseSensitive: false,
  );
  static final _rcptTo = RegExp(
    r'^TO:\s*(<[^>]*>|[^\s<>]+)',
    caseSensitive: false,
  );

  final MailInbox _inbox;
  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _lines = _LineBuffer();
  var _state = _State.command;
  var _hasSender = false;
  String? _sender;
  final _recipients = <String>[];
  final _data = BytesBuilder();
  var _quitting = false;
  var _ended = false;

  void end() {
    if (_ended) return;
    _ended = true;
    unawaited(_subscription.cancel());
    _socket.destroy();
    _inbox._sessions.remove(this);
  }

  void _onBytes(Uint8List chunk) {
    if (_ended || _quitting) return;
    try {
      _lines.add(chunk, (line) {
        _onLine(line);
        return !_ended && !_quitting;
      });
    } catch (_) {
      // A bug here must cost this one connection, never the server.
      end();
    }
  }

  void _onLine(Uint8List line) {
    switch (_state) {
      case _State.data:
        _onDataLine(line);
      case _State.authPlain:
      case _State.authLoginPassword:
        _state = _State.command;
        _authResponse(line);
      case _State.authLoginUser:
        if (_cancelsAuth(line)) {
          _state = _State.command;
          _reply('501 5.7.0 Authentication cancelled');
        } else {
          _state = _State.authLoginPassword;
          _reply('334 UGFzc3dvcmQ6');
        }
      case _State.command:
        _onCommand(utf8.decode(line, allowMalformed: true));
    }
  }

  void _onCommand(String line) {
    var space = line.indexOf(' ');
    var verb = (space < 0 ? line : line.substring(0, space)).toUpperCase();
    var argument = space < 0 ? '' : line.substring(space + 1).trim();
    switch (verb) {
      case 'EHLO':
        _resetMail();
        _reply(
          '250-$_serverName greets ${argument.isEmpty ? 'you' : argument}',
        );
        _reply('250-8BITMIME');
        _reply('250-SMTPUTF8');
        _reply('250 AUTH PLAIN LOGIN');
      case 'HELO':
        _resetMail();
        _reply('250 $_serverName');
      case 'AUTH':
        _auth(argument);
      case 'MAIL':
        _mail(argument);
      case 'RCPT':
        _rcpt(argument);
      case 'DATA':
        if (!_hasSender) {
          _reply('503 5.5.1 Error: need MAIL command');
        } else if (_recipients.isEmpty) {
          _reply('503 5.5.1 Error: need RCPT command');
        } else {
          _state = _State.data;
          _data.clear();
          _reply('354 End data with <CR><LF>.<CR><LF>');
        }
      case 'RSET':
        _resetMail();
        _reply('250 2.0.0 OK');
      case 'NOOP':
        _reply('250 2.0.0 OK');
      case 'VRFY':
        _reply('252 2.5.2 Cannot VRFY user, but will accept message');
      case 'QUIT':
        _reply('221 2.0.0 Bye');
        _quitting = true;
        unawaited(
          _socket
              .close()
              .then((_) {}, onError: (Object _) {})
              .whenComplete(end),
        );
      default:
        _reply('502 5.5.2 Command not recognized');
    }
  }

  void _auth(String argument) {
    var words = argument.split(RegExp(r'\s+'));
    var initial = words.length > 1 ? words[1] : null;
    switch (words.first.toUpperCase()) {
      case 'PLAIN':
        if (initial == null) {
          _state = _State.authPlain;
          _reply('334 ');
        } else {
          _reply('235 2.7.0 Authentication successful');
        }
      case 'LOGIN':
        if (initial == null) {
          _state = _State.authLoginUser;
          _reply('334 VXNlcm5hbWU6');
        } else {
          _state = _State.authLoginPassword;
          _reply('334 UGFzc3dvcmQ6');
        }
      case '':
        _reply('501 5.5.4 Syntax: AUTH mechanism');
      default:
        _reply('504 5.5.4 Unrecognized authentication type');
    }
  }

  void _authResponse(Uint8List line) {
    _reply(
      _cancelsAuth(line)
          ? '501 5.7.0 Authentication cancelled'
          : '235 2.7.0 Authentication successful',
    );
  }

  bool _cancelsAuth(Uint8List line) => line.length == 1 && line[0] == 0x2a;

  void _mail(String argument) {
    var match = _mailFrom.firstMatch(argument);
    if (match == null) {
      _reply('501 5.5.4 Syntax: MAIL FROM:<address>');
      return;
    }
    _resetMail();
    var sender = _pathAddress(match[1]!);
    _sender = sender.isEmpty ? null : sender;
    _hasSender = true;
    _reply('250 2.1.0 OK');
  }

  void _rcpt(String argument) {
    if (!_hasSender) {
      _reply('503 5.5.1 Error: need MAIL command');
      return;
    }
    var match = _rcptTo.firstMatch(argument);
    var recipient = match == null ? '' : _pathAddress(match[1]!);
    if (recipient.isEmpty) {
      _reply('501 5.5.4 Syntax: RCPT TO:<address>');
      return;
    }
    _recipients.add(recipient);
    _reply('250 2.1.5 OK');
  }

  void _onDataLine(Uint8List line) {
    if (line.length == 1 && line[0] == _dot) {
      var raw = _data.takeBytes();
      var sender = _sender;
      var recipients = List.of(_recipients);
      _state = _State.command;
      _resetMail();
      _reply('250 2.0.0 OK: queued');
      _inbox._received(raw, sender, recipients);
      return;
    }
    _data
      ..add(
        line.isNotEmpty && line[0] == _dot
            ? Uint8List.sublistView(line, 1)
            : line,
      )
      ..add(_crlf);
  }

  void _resetMail() {
    _hasSender = false;
    _sender = null;
    _recipients.clear();
  }

  void _reply(String line) {
    if (_ended || _quitting) return;
    try {
      _socket.write('$line\r\n');
    } catch (_) {
      end();
    }
  }

  /// The address in an SMTP path: `<a@example.test>` or a bare
  /// `a@example.test`, without a source route.
  static String _pathAddress(String path) {
    var address = path.startsWith('<') && path.endsWith('>')
        ? path.substring(1, path.length - 1)
        : path;
    if (address.startsWith('@')) {
      var colon = address.indexOf(':');
      if (colon >= 0) address = address.substring(colon + 1);
    }
    return address.trim();
  }
}

/// Splits a byte stream into lines, each without its CRLF or bare LF.
final class _LineBuffer {
  final _partial = BytesBuilder();

  /// Hands each line that [chunk] completes to [onLine], until it returns
  /// false; an unfinished last line waits for the next chunk.
  void add(Uint8List chunk, bool Function(Uint8List line) onLine) {
    var start = 0;
    while (true) {
      var newline = chunk.indexOf(_lf, start);
      if (newline < 0) {
        if (start < chunk.length) {
          _partial.add(Uint8List.sublistView(chunk, start));
        }
        return;
      }
      var line = Uint8List.sublistView(chunk, start, newline);
      if (_partial.isNotEmpty) {
        _partial.add(line);
        line = _partial.takeBytes();
      }
      start = newline + 1;
      if (line.isNotEmpty && line.last == _cr) {
        line = Uint8List.sublistView(line, 0, line.length - 1);
      }
      if (!onLine(line)) return;
    }
  }
}

typedef _Reply = ({int code, String text});

/// The replies an SMTP server sends, a multi-line one (`250-…`) as one.
final class _Replies {
  _Replies(Socket socket) {
    _subscription = socket.listen(
      (chunk) => _lines.add(chunk, _onLine),
      onError: (Object error) => _fail(error),
      onDone: () => _fail(const SocketException('The connection was closed')),
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _lines = _LineBuffer();
  final _text = <String>[];
  final _replies = <_Reply>[];
  Completer<_Reply>? _waiting;
  Object? _error;

  Future<_Reply> next() {
    if (_replies.isNotEmpty) return Future.value(_replies.removeAt(0));
    if (_error case var error?) return Future.error(error);
    return (_waiting = Completer<_Reply>()).future;
  }

  Future<void> cancel() => _subscription.cancel();

  bool _onLine(Uint8List bytes) {
    var line = utf8.decode(bytes, allowMalformed: true);
    _text.add(line);
    if (line.length > 3 && line[3] == '-') return true;
    var reply = (
      code: int.tryParse(line.length < 3 ? line : line.substring(0, 3)) ?? 0,
      text: _text.join(' / '),
    );
    _text.clear();
    if (_waiting case var waiting?) {
      _waiting = null;
      waiting.complete(reply);
    } else {
      _replies.add(reply);
    }
    return true;
  }

  void _fail(Object error) {
    _error ??= error;
    if (_waiting case var waiting?) {
      _waiting = null;
      waiting.completeError(error);
    }
  }
}

/// [raw] as SMTP sends it after `DATA`: a line starting with a dot gets a
/// second one, and the whole ends with a line break.
Uint8List _dotStuffed(Uint8List raw) {
  var out = BytesBuilder(copy: false);
  var from = 0;
  var lineStart = true;
  for (var i = 0; i < raw.length; i++) {
    if (lineStart && raw[i] == _dot) {
      out
        ..add(Uint8List.sublistView(raw, from, i))
        ..addByte(_dot);
      from = i;
    }
    lineStart = raw[i] == _lf;
  }
  out.add(Uint8List.sublistView(raw, from));
  if (!lineStart) out.add(_crlf);
  return out.takeBytes();
}

/// One MIME entity: a whole message, or one part of a multipart.
final class _Entity {
  _Entity(this.headers, this.body);

  /// Splits [bytes] at the first empty line into unfolded headers and the
  /// body. Header names are lower-cased; a header that repeats keeps its
  /// first value.
  factory _Entity.parse(Uint8List bytes) {
    var lines = <String>[];
    var bodyStart = bytes.length;
    var position = 0;
    while (position < bytes.length) {
      var newline = bytes.indexOf(_lf, position);
      var end = newline < 0 ? bytes.length : newline;
      var next = newline < 0 ? bytes.length : newline + 1;
      if (end > position && bytes[end - 1] == _cr) end--;
      if (end == position) {
        bodyStart = next;
        break;
      }
      lines.add(
        utf8.decode(
          Uint8List.sublistView(bytes, position, end),
          allowMalformed: true,
        ),
      );
      position = next;
    }

    var headers = <String, String>{};
    String? name;
    var value = StringBuffer();
    void flush() {
      if (name case var name?) {
        headers.putIfAbsent(name, () => value.toString().trim());
      }
      value.clear();
    }

    for (var line in lines) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (name != null) value.write(line);
        continue;
      }
      flush();
      var colon = line.indexOf(':');
      if (colon <= 0) {
        name = null;
        continue;
      }
      name = line.substring(0, colon).trim().toLowerCase();
      value.write(line.substring(colon + 1));
    }
    flush();

    return _Entity(
      headers,
      bodyStart < bytes.length
          ? Uint8List.sublistView(bytes, bodyStart)
          : Uint8List(0),
    );
  }

  final Map<String, String> headers;
  final Uint8List body;
}

/// The first plain-text and the first HTML body found in a message.
final class _Bodies {
  static const _maxDepth = 16;

  String? text;
  String? html;

  void collect(_Entity entity, int depth) {
    if (text != null && html != null) return;
    var disposition = _parameterized(entity.headers['content-disposition']);
    if (disposition.value == 'attachment') return;
    var contentType = _parameterized(entity.headers['content-type']);
    var type = contentType.value.contains('/')
        ? contentType.value
        : 'text/plain';
    var charset = contentType.parameters['charset'];
    if (type.startsWith('multipart/')) {
      var boundary = contentType.parameters['boundary'];
      if (boundary == null || boundary.isEmpty || depth >= _maxDepth) return;
      for (var part in _multipartParts(entity.body, boundary)) {
        collect(_Entity.parse(part), depth + 1);
      }
    } else if (type == 'text/plain') {
      text ??= _decodeBody(entity, charset);
    } else if (type == 'text/html') {
      html ??= _decodeBody(entity, charset);
    }
  }
}

/// The parts of a multipart [body] delimited by [boundary], each with its
/// headers. The preamble and epilogue are dropped; a body that never closes
/// its last part ends it at the end of the body.
List<Uint8List> _multipartParts(Uint8List body, String boundary) {
  var delimiter = utf8.encode('--$boundary');
  var parts = <Uint8List>[];
  int? partStart;
  var lineStart = 0;
  while (true) {
    var newline = body.indexOf(_lf, lineStart);
    var lineEnd = newline < 0 ? body.length : newline;
    var kind = _delimiterKind(body, lineStart, lineEnd, delimiter);
    if (kind != _Delimiter.none) {
      if (partStart case var start?) {
        var end = lineStart;
        if (end > start && body[end - 1] == _lf) end--;
        if (end > start && body[end - 1] == _cr) end--;
        parts.add(Uint8List.sublistView(body, start, end));
      }
      if (kind == _Delimiter.close) return parts;
      partStart = newline < 0 ? body.length : newline + 1;
    }
    if (newline < 0) break;
    lineStart = newline + 1;
  }
  if (partStart case var start? when start < body.length) {
    parts.add(Uint8List.sublistView(body, start));
  }
  return parts;
}

enum _Delimiter { none, part, close }

_Delimiter _delimiterKind(
  Uint8List body,
  int start,
  int end,
  List<int> delimiter,
) {
  if (end - start < delimiter.length) return _Delimiter.none;
  for (var i = 0; i < delimiter.length; i++) {
    if (body[start + i] != delimiter[i]) return _Delimiter.none;
  }
  var rest = start + delimiter.length;
  if (rest + 1 < end && body[rest] == 0x2d && body[rest + 1] == 0x2d) {
    return _Delimiter.close;
  }
  for (var i = rest; i < end; i++) {
    if (!_isSpace(body[i]) && body[i] != _cr) return _Delimiter.none;
  }
  return _Delimiter.part;
}

bool _isSpace(int byte) => byte == 0x20 || byte == 0x09;

/// A leaf part's body as text: its transfer encoding undone, its charset
/// decoded, and CRLF turned into `\n`.
String _decodeBody(_Entity entity, String? charset) {
  var encoding = _parameterized(entity.headers['content-transfer-encoding'])
      .value;
  var bytes = switch (encoding) {
    'quoted-printable' => _decodeQuotedPrintable(entity.body),
    'base64' => _decodeBase64(entity.body),
    _ => entity.body,
  };
  return _decodeCharset(bytes, charset).replaceAll('\r\n', '\n');
}

/// A header value such as `text/plain; charset="utf-8"`: the value lower-cased
/// and the parameters by lower-cased name, unquoted. An absent header is an
/// empty value.
({String value, Map<String, String> parameters}) _parameterized(
  String? header,
) {
  if (header == null) return (value: '', parameters: const {});
  var segments = _splitOutsideQuotes(header, ';');
  var value = segments.first.split('(').first.trim().toLowerCase();
  var parameters = <String, String>{};
  for (var segment in segments.skip(1)) {
    var equals = segment.indexOf('=');
    if (equals < 0) continue;
    var name = segment.substring(0, equals).trim().toLowerCase();
    parameters.putIfAbsent(
      name,
      () => _unquote(segment.substring(equals + 1).trim()),
    );
  }
  return (value: value, parameters: parameters);
}

List<String> _splitOutsideQuotes(String value, String separator) {
  var segments = <String>[];
  var start = 0;
  var quoted = false;
  for (var i = 0; i < value.length; i++) {
    var char = value[i];
    if (quoted && char == r'\') {
      i++;
    } else if (char == '"') {
      quoted = !quoted;
    } else if (!quoted && char == separator) {
      segments.add(value.substring(start, i));
      start = i + 1;
    }
  }
  segments.add(value.substring(start));
  return segments;
}

/// A parameter value: the inside of a quoted string with its escapes undone,
/// or a bare token up to any trailing comment.
String _unquote(String value) {
  if (!value.startsWith('"')) {
    return value.split(RegExp(r'[\s(]')).first;
  }
  var out = StringBuffer();
  for (var i = 1; i < value.length; i++) {
    var char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      out.write(value[++i]);
    } else if (char == '"') {
      break;
    } else {
      out.write(char);
    }
  }
  return out.toString();
}

Uint8List _decodeQuotedPrintable(Uint8List body) {
  var out = BytesBuilder(copy: false);
  var i = 0;
  // Where the line break at [at] ends, or -1 if there is none there.
  int lineBreakEnd(int at) {
    if (at == body.length) return at;
    if (body[at] == _lf) return at + 1;
    if (body[at] == _cr) {
      return at + 1 < body.length && body[at + 1] == _lf ? at + 2 : at + 1;
    }
    return -1;
  }

  while (i < body.length) {
    var byte = body[i];
    if (byte == 0x3d) {
      var after = i + 1;
      while (after < body.length && _isSpace(body[after])) {
        after++;
      }
      var softBreak = lineBreakEnd(after);
      if (softBreak >= 0) {
        i = softBreak;
        continue;
      }
      if (i + 2 < body.length) {
        var high = _hexValue(body[i + 1]);
        var low = _hexValue(body[i + 2]);
        if (high >= 0 && low >= 0) {
          out.addByte(high * 16 + low);
          i += 3;
          continue;
        }
      }
      out.addByte(byte);
      i++;
    } else if (_isSpace(byte)) {
      // Trailing whitespace is transport padding, not content.
      var end = i;
      while (end < body.length && _isSpace(body[end])) {
        end++;
      }
      if (lineBreakEnd(end) < 0) out.add(Uint8List.sublistView(body, i, end));
      i = end;
    } else {
      out.addByte(byte);
      i++;
    }
  }
  return out.takeBytes();
}

int _hexValue(int char) {
  if (char >= 0x30 && char <= 0x39) return char - 0x30;
  if (char >= 0x41 && char <= 0x46) return char - 0x41 + 10;
  if (char >= 0x61 && char <= 0x66) return char - 0x61 + 10;
  return -1;
}

/// Base64 with everything outside its alphabet ignored, line breaks included,
/// and missing padding forgiven.
Uint8List _decodeBase64(List<int> encoded) {
  var chars = StringBuffer();
  for (var char in encoded) {
    if (char >= 0x41 && char <= 0x5a ||
        char >= 0x61 && char <= 0x7a ||
        char >= 0x30 && char <= 0x39 ||
        char == 0x2b ||
        char == 0x2f ||
        char == 0x2d ||
        char == 0x5f) {
      chars.writeCharCode(char);
    }
  }
  var text = chars.toString();
  if (text.length % 4 == 1) text = text.substring(0, text.length - 1);
  try {
    return base64.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return Uint8List(0);
  }
}

/// [bytes] in [charset]. UTF-8, US-ASCII and anything unknown are read as
/// UTF-8, keeping what is malformed as replacement characters; ISO-8859-1 as
/// Latin-1.
String _decodeCharset(List<int> bytes, String? charset) =>
    switch (charset?.trim().toLowerCase()) {
      'iso-8859-1' ||
      'iso8859-1' ||
      'iso_8859-1' ||
      'latin1' ||
      'latin-1' ||
      'l1' => latin1.decode(bytes),
      _ => utf8.decode(bytes, allowMalformed: true),
    };

final _encodedWord = RegExp(r'=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?=');

/// [value] with its RFC 2047 encoded words decoded. Whitespace between two
/// adjacent encoded words is dropped, and adjacent words in the same charset
/// are decoded together, so a character split across two words survives.
String _decodeEncodedWords(String value) {
  var out = StringBuffer();
  var pending = <int>[];
  String? pendingCharset;
  void flush() {
    if (pendingCharset != null) {
      out.write(_decodeCharset(pending, pendingCharset));
      pending = [];
      pendingCharset = null;
    }
  }

  var last = 0;
  for (var match in _encodedWord.allMatches(value)) {
    var gap = value.substring(last, match.start);
    if (pendingCharset == null || gap.trim().isNotEmpty) {
      flush();
      out.write(gap);
    }
    var charset = match[1]!.split('*').first.toLowerCase();
    if (pendingCharset != charset) flush();
    var text = match[3]!;
    pending.addAll(
      match[2]!.toUpperCase() == 'B'
          ? _decodeBase64(text.codeUnits)
          : _decodeQ(text),
    );
    pendingCharset = charset;
    last = match.end;
  }
  flush();
  out.write(value.substring(last));
  return out.toString();
}

/// The Q encoding of RFC 2047: quoted-printable where `_` is a space.
List<int> _decodeQ(String text) {
  var out = <int>[];
  for (var i = 0; i < text.length; i++) {
    var char = text.codeUnitAt(i);
    if (char == 0x5f) {
      out.add(0x20);
    } else if (char == 0x3d && i + 2 < text.length) {
      var high = _hexValue(text.codeUnitAt(i + 1));
      var low = _hexValue(text.codeUnitAt(i + 2));
      if (high >= 0 && low >= 0) {
        out.add(high * 16 + low);
        i += 2;
      } else {
        out.add(char);
      }
    } else {
      out.add(char < 0x100 ? char : 0x3f);
    }
  }
  return out;
}

/// The bare addresses in an address-list header such as
/// `"Lovelace, Ada" <ada@example.test>, bob@example.test`. Display names,
/// comments and group names are dropped.
List<String> _addresses(String? header) {
  if (header == null) return const [];
  var addresses = <String>[];
  var bare = StringBuffer();
  var angle = StringBuffer();
  var sawAngle = false;
  void flush() {
    var address = (sawAngle ? angle.toString() : bare.toString()).trim();
    address = _Session._pathAddress(address);
    if (address.isNotEmpty) addresses.add(address);
    bare.clear();
    angle.clear();
    sawAngle = false;
  }

  var i = 0;
  while (i < header.length) {
    var char = header[i];
    switch (char) {
      case '"':
        var end = i + 1;
        while (end < header.length && header[end] != '"') {
          if (header[end] == r'\') end++;
          end++;
        }
        bare.write(header.substring(i, end < header.length ? end + 1 : end));
        i = end + 1;
        continue;
      case '(':
        var depth = 0;
        while (i < header.length) {
          if (header[i] == r'\') {
            i++;
          } else if (header[i] == '(') {
            depth++;
          } else if (header[i] == ')' && --depth == 0) {
            break;
          }
          i++;
        }
      case '<':
        var end = header.indexOf('>', i);
        if (end < 0) end = header.length;
        angle
          ..clear()
          ..write(header.substring(i + 1, end));
        sawAngle = true;
        i = end;
      case '[':
        var end = header.indexOf(']', i);
        if (end < 0) end = header.length - 1;
        bare.write(header.substring(i, end + 1));
        i = end;
      case ',' || ';':
        flush();
      case ':':
        // A group's name: `Team: a@example.test, b@example.test;`.
        bare.clear();
      default:
        bare.write(char);
    }
    i++;
  }
  flush();
  return addresses;
}
