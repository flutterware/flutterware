/// The Server plugin over a recording: the handles, the hello, the ring and
/// the details a real attachment would have delivered, read from files the
/// recorder wrote by attaching to a real inspector once. See
/// `tool/demo/record.dart --only=server`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutterware/server.dart';

import '../plugins/native/server_core.dart';
import 'recording.dart';

class RecordedServerSource implements ServerSource {
  RecordedServerSource(this.recording, {this.packagePath = '.'});

  final Recording recording;
  final String packagePath;

  final _loaded = <String, _RecordedServer>{};

  Future<String?> _read(String path) =>
      Future.value(recording.readString(path));

  Future<_RecordedServer?> _server(String name) async {
    if (_loaded[name] case var server?) return server;
    var text = await _read(recordedServerPath(packagePath, name));
    if (text == null) return null;
    return _loaded[name] = _RecordedServer.fromJson(
      jsonDecode(text) as Map<String, Object?>,
    );
  }

  @override
  Future<List<ServerHandle>> scan({required String underRoot}) async {
    var text = await _read(recordedServerIndexPath(packagePath));
    if (text == null) return const [];
    var names = ((jsonDecode(text) as Map)['servers'] as List).cast<String>();
    return [
      for (var name in names)
        if (await _server(name) case var server?) server.handle,
    ];
  }

  @override
  Stream<void>? watch() => null;

  @override
  Future<ServerAttachment?> attach(
    ServerHandle handle, {
    required void Function(Object error, {required bool deleted}) onFailure,
  }) async {
    var server = await _server(handle.name);
    if (server == null) {
      onFailure(StateError('not in the recording'), deleted: true);
      return null;
    }
    return _RecordedAttachment(server);
  }
}

class _RecordedServer {
  _RecordedServer({
    required this.handle,
    required this.hello,
    required this.events,
    required this.details,
    required this.answers,
  });

  factory _RecordedServer.fromJson(Map<String, Object?> json) {
    var handle = json['handle']! as Map<String, Object?>;
    var hello = json['hello']! as Map<String, Object?>;
    return _RecordedServer(
      handle: ServerHandle(
        projectRoot: handle['projectRoot']! as String,
        name: handle['name']! as String,
        socketPath: handle['socketPath']! as String,
        pid: handle['pid']! as int,
        startedAt: DateTime.parse(handle['startedAt']! as String),
        baseUrl: handle['baseUrl'] as String?,
        environment: handle['environment'] as String?,
      ),
      hello: ServerHello(
        name: hello['name']! as String,
        pid: hello['pid']! as int,
        projectRoot: hello['projectRoot']! as String,
        startedAt: DateTime.parse(hello['startedAt']! as String),
        channels: (hello['channels']! as List).cast<String>(),
        eventCount: hello['eventCount']! as int,
      ),
      events: [
        for (var event
            in (json['events']! as List).cast<Map<String, Object?>>())
          ServerEvent(
            channel: event['channel']! as String,
            id: event['id']! as int,
            time: DateTime.parse(event['time']! as String),
            rid: event['rid'] as String?,
            payload: (event['payload']! as Map).cast<String, Object?>(),
            isReplay: true,
          ),
      ],
      details: {
        for (var entry in (json['details']! as Map).entries)
          int.parse(entry.key as String): (entry.value as Map)
              .cast<String, Object?>(),
      },
      answers: {
        for (var entry in (json['answers']! as Map).entries)
          entry.key as String: (entry.value as Map).cast<String, Object?>(),
      },
    );
  }

  final ServerHandle handle;
  final ServerHello hello;
  final List<ServerEvent> events;
  final Map<int, Map<String, Object?>> details;
  final Map<String, Map<String, Object?>> answers;
}

/// A finished replay that never closes: the ring is [received] from the
/// start, nothing follows it, and the server is never gone.
class _RecordedAttachment implements ServerAttachment {
  _RecordedAttachment(this._server);

  final _RecordedServer _server;
  final _events = StreamController<ServerEvent>.broadcast();

  @override
  ServerHello get hello => _server.hello;
  @override
  List<ServerEvent> get received => _server.events;
  @override
  Stream<ServerEvent> get events => _events.stream;
  @override
  bool get replayComplete => true;
  @override
  Future<void> get done => Completer<void>().future;

  /// The recorder asked each command once, with the arguments the panel
  /// sends; the answer is keyed by channel and method alone, so any
  /// occurrence gets the recorded reply.
  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    var answer = _server.answers['$channel/$method'];
    if (answer == null) {
      throw ServerRequestException('$channel/$method was not recorded');
    }
    return answer;
  }

  @override
  Future<Map<String, Object?>?> details(int eventId) async =>
      _server.details[eventId];

  @override
  Future<void> close() => _events.close();
}
