import 'dart:convert';
import 'dart:io';

/// Mailcatcher's web interface, as much of it as a world reads: the list at
/// `/messages`, each mail's `/messages/:id.source`, and the websocket at
/// `/messages` announcing each new one, in the shapes Mailcatcher 0.10 uses.
class FakeMailCatcher {
  FakeMailCatcher._(this._server, {required this.websocket});

  /// Listens on a free port. With no [websocket], an upgrade is refused, as
  /// a proxy in front of the catcher might, so only the list tells.
  static Future<FakeMailCatcher> start({bool websocket = true}) async {
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var catcher = FakeMailCatcher._(server, websocket: websocket);
    server.listen(catcher._serve);
    return catcher;
  }

  final HttpServer _server;
  final bool websocket;
  final _messages = <({Map<String, Object?> summary, String source})>[];
  final _sockets = <WebSocket>[];
  var _nextId = 1;

  /// While false, every request is answered 503, as by a catcher still
  /// starting.
  var answering = true;

  int get port => _server.port;

  Uri get api => Uri.parse('http://localhost:$port/');

  /// How many websockets are open on it.
  int get listening => _sockets.length;

  /// Catches a mail from [from] to [recipients], as one sent to Mailcatcher
  /// over SMTP, received [at] (now by default).
  void catches({
    required String from,
    required List<String> recipients,
    required String subject,
    String text = '',
    String? messageId,
    DateTime? at,
  }) {
    var source = [
      'From: $from',
      'To: ${recipients.join(', ')}',
      'Subject: $subject',
      if (messageId != null) 'Message-ID: $messageId',
      'Content-Type: text/plain; charset=utf-8',
      '',
      text,
    ].join('\r\n');
    var sender = RegExp('<([^>]*)>').firstMatch(from)?[1] ?? from;
    var summary = <String, Object?>{
      'id': _nextId++,
      // Mailcatcher keeps the SMTP parameters after the sender.
      'sender': '<$sender> size=${source.length}',
      'recipients': [for (var recipient in recipients) '<$recipient>'],
      'subject': subject,
      'size': '${source.length}',
      'created_at': _seconds(at ?? DateTime.now()),
    };
    _messages.add((summary: summary, source: source));
    _announce({'type': 'add', 'message': summary});
  }

  /// Deletes every mail, after which ids start again at 1.
  void clear() {
    _messages.clear();
    _nextId = 1;
    _announce({'type': 'clear'});
  }

  /// Closes the websockets, as a catcher restarting does.
  Future<void> dropSockets() async {
    for (var socket in [..._sockets]) {
      await socket.close();
    }
    _sockets.clear();
  }

  Future<void> close() async {
    await dropSockets();
    await _server.close(force: true);
  }

  static String _seconds(DateTime at) =>
      '${at.toUtc().toIso8601String().substring(0, 19)}+00:00';

  void _announce(Map<String, Object?> frame) {
    for (var socket in _sockets) {
      socket.add(jsonEncode(frame));
    }
  }

  Future<void> _serve(HttpRequest request) async {
    var path = request.uri.path;
    if (!answering) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    if (path == '/messages' && WebSocketTransformer.isUpgradeRequest(request)) {
      if (!websocket) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      var socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen(null, onDone: () => _sockets.remove(socket));
      return;
    }
    if (path == '/messages') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode([for (var message in _messages) message.summary]));
      await request.response.close();
      return;
    }
    if (RegExp(r'^/messages/(\d+)\.source$').firstMatch(path) case var match?) {
      var id = int.parse(match[1]!);
      var message = _messages
          .where((message) => message.summary['id'] == id)
          .firstOrNull;
      if (message != null) {
        request.response
          ..headers.contentType = ContentType('message', 'rfc822')
          ..write(message.source);
        await request.response.close();
        return;
      }
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}
