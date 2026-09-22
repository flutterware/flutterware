/// The run plugin over a recording: one real session of the demo app on an
/// iOS simulator, as `tool/demo/run_session.dart` kept it.
///
/// The three doors of [RunSources], answered from that session. The run dir
/// is the run's own files — the handle, the launcher's log, the journal and
/// every picture it points at — read by the paths the tool wrote, under
/// [recordedRunDir]. The app answers its probe as a run whose launcher is gone
/// and whose app is still there, which is the header's *no launcher — cannot
/// reload*: the truth about a recording, and a state the cockpit already
/// draws. Its screen is the last picture the session took, and its channels
/// answer what the app said when the recorder asked.
///
/// Everything else — launching, reloading, booting, driving — refuses with
/// [recordedRunRefusal], through the core's own read-only door.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutterware/channels.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/semantics.dart';
import 'package:path/path.dart' as p;

import '../plugins/native/run_plugin.dart';
import '../run/channel_client.dart';
import '../run/handle.dart';
import '../run/inspect.dart';
import '../run/journal.dart';
import '../run/refusal.dart';
import '../run/run_files.dart';
import '../run/run_sources.dart';
import 'recording.dart';

/// What every change to a recorded run is refused with.
const recordedRunRefusal =
    'This is a recording of one session on an iOS simulator. The app it shows '
    'is not running anywhere, so nothing here can launch, reload, drive or '
    'change it.';

/// The run plugin's sources over [recording] — `RunCore(sources: …)`.
RunSources recordedRunSources(Recording recording) {
  var files = RecordedRunFiles(recording);
  return RunSources(
    files: files,
    apps: RecordedRunApps(files),
    channels: RecordedRunChannels(recording),
    runDir: recordedRunDir,
    readOnly: recordedRunRefusal,
  );
}

/// The pictures of a recorded run — `RunPlugin(image: …)`.
RunImage recordedRunImage(Recording recording) =>
    (path) => recording.encodedImage(_relative(path));

/// `$recordedRunDir/x` as the recording names it, `run/x`.
String _relative(String path) =>
    recordedRunFilePath(p.posix.relative(path, from: recordedRunDir));

/// The recorded run dir, preloaded.
///
/// Every file is fetched once, up front, because the run plugin's readers are
/// synchronous and the recording's HTTP end is not. The whole run is a few
/// hundred kilobytes. A write — the App tab remembering a knob someone
/// turned — lands in memory and is gone with the page.
class RecordedRunFiles extends RunFiles {
  RecordedRunFiles(this.recording) {
    ready = _load();
  }

  final Recording recording;

  final _files = <String, Uint8List>{};

  @override
  late final Future<void> ready;

  Future<void> _load() async {
    // Through `Future.value`, for the reason `recordedIconScanner` gives: a
    // synchronous end must still resume this function on a microtask.
    var index = await Future.value(recording.readString(recordedRunIndexPath));
    if (index == null) return;
    var names = ((jsonDecode(index) as Map)['files'] as List).cast<String>();
    await Future.wait([
      for (var name in names)
        Future.value(recording.readBytes(recordedRunFilePath(name))).then((
          bytes,
        ) {
          if (bytes != null) _files[p.posix.join(recordedRunDir, name)] = bytes;
        }),
    ]);
  }

  @override
  Uint8List? readBytes(String path, {int start = 0}) {
    var bytes = _files[path];
    if (bytes == null) return null;
    return start == 0 ? bytes : Uint8List.sublistView(bytes, start);
  }

  @override
  int? lengthOf(String path) => _files[path]?.length;

  @override
  List<String> list(String directory) => [
    for (var path in _files.keys)
      if (p.posix.dirname(path) == directory) path,
  ];

  @override
  void writeString(String path, String text) =>
      _files[path] = utf8.encode(text);

  /// Nothing under a recording moves.
  @override
  Stream<void> changes(String path) => const Stream.empty();
}

/// The app behind a recorded handle.
class RecordedRunApps extends RunApps {
  const RecordedRunApps(this.files);

  final RunFiles files;

  /// Up, and without its launcher — inspectable, not reloadable.
  @override
  Future<RunProbe> probe(RunHandle handle) async =>
      const RunProbe(app: true, launcher: false);

  /// The last picture the session took, with its tree and its semantics —
  /// the same archive the Steps tab reads, which is a reading of the app at
  /// that moment.
  @override
  Future<InspectRead> read(
    RunHandle handle, {
    bool tree = true,
    bool screenshot = true,
    bool semantics = false,
    bool summary = true,
  }) async {
    await files.ready;
    var step = readJournal(
      handle,
      files: files,
    ).lastWhereOrNull((entry) => entry.screenshot != null);
    Map<String, Object?>? json(String? path) => switch (path) {
      String path => switch (files.readString(path)) {
        String text => (jsonDecode(text) as Map).cast<String, Object?>(),
        null => null,
      },
      null => null,
    };
    var treeJson = tree ? json(step?.tree) : null;
    var semanticsJson = semantics ? json(step?.semantics) : null;
    return InspectRead(
      tree: treeJson == null ? null : InspectTree.fromJson(treeJson),
      image: screenshot && step?.screenshot != null
          ? files.readBytes(step!.screenshot!)
          : null,
      semantics: semanticsJson == null
          ? null
          : InspectSemantics(entryId: null, root: semanticsJson),
      fromGuest: true,
    );
  }
}

/// A recorded app's channels: what it replayed and answered when the recorder
/// attached, one file per run.
class RecordedRunChannels extends RunChannels {
  const RecordedRunChannels(this.recording);

  final Recording recording;

  @override
  Future<RunAttachment> attach(RunHandle handle, {required String peer}) async {
    var text = await Future.value(
      recording.readString(recordedRunChannelsPath(handle.key)),
    );
    if (text == null) {
      throw RunRefusal('${handle.entrypointLabel} reported no panels.');
    }
    var json = (jsonDecode(text) as Map).cast<String, Object?>();
    return _RecordedAttachment(
      received: [
        for (var event in (json['received']! as List).cast<Map>())
          InspectorEvent(
            channel: event['channel']! as String,
            id: event['id']! as int,
            time: DateTime.parse(event['time']! as String),
            rid: event['rid'] as String?,
            payload: (event['payload']! as Map).cast<String, Object?>(),
            isReplay: true,
          ),
      ],
      answers: (json['answers']! as Map).cast<String, Object?>(),
    );
  }
}

/// A finished replay that never grows: [received] from the start, and each
/// request answered from the recording or refused.
class _RecordedAttachment implements RunAttachment {
  _RecordedAttachment({required this.received, required this.answers});

  @override
  final List<InspectorEvent> received;

  final Map<String, Object?> answers;

  @override
  Stream<InspectorEvent> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    var answer = answers[recordedChannelRequestKey(channel, method, params)];
    if (answer is Map) return answer.cast<String, Object?>();
    throw RunRefusal(recordedRunRefusal);
  }

  @override
  Future<Map<String, Object?>?> details(int eventId) async => null;

  @override
  Future<void> close() async {}
}
