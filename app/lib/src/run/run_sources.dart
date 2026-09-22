import 'channel_client.dart';
import 'connection.dart';
import 'handle.dart';
import 'inspect.dart';
import 'refusal.dart';
import 'run_files.dart';

/// Where the run plugin learns what it knows about runs.
///
/// Three doors, and they are the whole of what the cockpit reads: the run's
/// files, the app behind a handle, and that app's channels. [RunSources.live]
/// is the machine; a recording answers the same three from what one real
/// session left behind, so the core and the panel above them are the shipped
/// ones over either.
///
/// What is not a door refuses over a recording, with [readOnly] as its
/// sentence: launching, reloading, booting a device and driving an app all
/// change the machine, and a recording has no machine to change.
class RunSources {
  const RunSources({
    required this.files,
    required this.apps,
    required this.channels,
    this.runDir,
    this.readOnly,
  });

  /// The machine: the disk, the VM service, `flutter run` and the daemon.
  const RunSources.live({this.runDir})
    : files = const DiskRunFiles(),
      apps = const LiveRunApps(),
      channels = const LiveRunChannels(),
      readOnly = null;

  final RunFiles files;
  final RunApps apps;
  final RunChannels channels;

  /// Where the handles, the logs and the journals are. Null for the machine's
  /// own run dir.
  final String? runDir;

  /// Why nothing here can change what is running — non-null over a recording.
  /// Such a core starts no daemon and polls nothing, and every action that
  /// would launch, reload, boot or drive refuses with this sentence.
  final String? readOnly;
}

/// The app behind a handle: whether it answers, and what is on its screen.
abstract class RunApps {
  const RunApps();

  /// Whether the app and its launcher are still there. Opens a socket on the
  /// machine, so it belongs to live tracking and to actions — never to a
  /// report.
  Future<RunProbe> probe(RunHandle handle);

  /// One reading of the app — see [RunInspector.read].
  Future<InspectRead> read(
    RunHandle handle, {
    bool tree = true,
    bool screenshot = true,
    bool semantics = false,
    bool summary = true,
  });
}

class LiveRunApps extends RunApps {
  const LiveRunApps();

  @override
  Future<RunProbe> probe(RunHandle handle) => probeRunHandle(handle);

  @override
  Future<InspectRead> read(
    RunHandle handle, {
    bool tree = true,
    bool screenshot = true,
    bool semantics = false,
    bool summary = true,
  }) => withRunInspector(
    handle,
    (inspector) => inspector.read(
      tree: tree,
      screenshot: screenshot,
      semantics: semantics,
      summary: summary,
      preferGuest: true,
    ),
  );
}

/// Opens a connection for reading rather than for driving, for the length of
/// [body].
///
/// Waits for no registration, and that is the point. Reload and restart have
/// to wait for the `flutter run` to register them; the inspector is the
/// *app's* own and exists the moment its isolate does. So everything built on
/// this keeps working on a run whose launcher has died — the surviving half of
/// the two-tier split.
Future<T> withRunInspector<T>(
  RunHandle handle,
  Future<T> Function(RunInspector inspector) body,
) async {
  var connection = await RunConnection.connect(_serviceOf(handle));
  try {
    return await body(RunInspector(connection));
  } finally {
    await connection.close();
  }
}

String _serviceOf(RunHandle handle) =>
    handle.vmService ??
    (throw RunRefusal(
      '${handle.entrypointLabel} has no VM service yet — it is still '
      'building. Watch ${handle.logPath}.',
    ));

/// The app's channels: the panels its devbar reports, their state and feeds.
abstract class RunChannels {
  const RunChannels();

  /// Attaches as [peer], or throws when the app reports no channels. [peer]
  /// is the attachment's own queue on the app side, so two attachers never
  /// race for one.
  Future<RunAttachment> attach(RunHandle handle, {required String peer});
}

class LiveRunChannels extends RunChannels {
  const LiveRunChannels({this.connect = RunConnection.connect});

  /// How a VM service is reached — a fake one in a test.
  final Future<RunConnection> Function(String wsUri) connect;

  @override
  Future<RunAttachment> attach(RunHandle handle, {required String peer}) async {
    var connection = await connect(_serviceOf(handle));
    try {
      return await RunChannelClient.attach(
        connection,
        peer: peer,
        ownsConnection: true,
      );
    } on Object {
      await connection.close();
      rethrow;
    }
  }
}
