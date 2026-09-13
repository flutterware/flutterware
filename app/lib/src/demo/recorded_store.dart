/// The store plugin over a recording: the live core and the live panel,
/// handed a [StoreSource] and an image door that answer from what
/// `tool/demo/record.dart` kept rather than from the package's export tree.
///
/// One file holds what the core reads — the pubspec's name and description,
/// and the manifest with every set's `output` spelled under the recording —
/// and the pictures sit beside it where that `output` says, so the panel
/// joins a set's image paths exactly as it does on disk and what it builds
/// is a recording path. The manifest is fetched once, on the panel's first
/// look, and answered from then on; the core says so when it lands.
library;

import 'dart:convert';

import 'package:flutterware/store_report.dart';

import '../plugins/native/store_core.dart';
import '../plugins/native/store_plugin.dart';
import 'recording.dart';

/// Where the store core reads from when the project is a recording —
/// `StoreCore(source: …)`.
class RecordedStoreSource extends StoreSource {
  RecordedStoreSource(this.recording);

  final Recording recording;

  Map? _pubspec;
  final _manifests = <String, StoreShotsReport>{};
  Future<void>? _loading;

  @override
  Map? pubspecOf(String packageRoot) => _pubspec;

  @override
  String defaultRootIn(String packageRoot) =>
      recordedStoreRootDir(_packagePathOf(packageRoot));

  @override
  StoreShotsReport? manifestOf(String output) => _manifests[output];

  @override
  Future<StoreShotsReport> readManifest(String output) async {
    await (_loading ??= _load());
    return _manifests[output] ?? const StoreShotsReport();
  }

  /// The one file, read once: it holds the pubspec and every app's sets.
  Future<void> _load() async {
    // Through `Future.value`, for the reason `recordedIconScanner` gives: a
    // synchronous end must still resume this function on a microtask.
    var text = await Future.value(recording.readString(recordedStorePath('.')));
    if (text == null) return;
    var json = jsonDecode(text) as Map<String, Object?>;
    _pubspec = json['pubspec'] as Map?;
    var manifest = json['manifest'] as Map<String, Object?>? ?? const {};
    if (manifest['version'] != storeShotsReportVersion) return;
    var sets = [
      for (var entry in manifest['sets'] as List? ?? const [])
        if (entry is Map)
          ?StoreShotsSet.fromJson(entry.cast<String, Object?>()),
    ];
    // Keyed by each set's own output, which is what the core asks by.
    for (var set in sets) {
      _manifests[set.output] =
          (_manifests[set.output] ?? const StoreShotsReport()).merge([set]);
    }
  }
}

/// The pictures of a recorded export — `StorePlugin(image: …)`.
StoreImage recordedStoreImage(Recording recording) =>
    // The panel joined the path with the platform's separator, and the
    // recording is addressed with `/` on every platform.
    (path) => recording.encodedImage(path.replaceAll(r'\', '/'));

/// The recorded project has one package at `.`, which the core addresses by
/// its absolute root.
String _packagePathOf(String packageRoot) {
  if (packageRoot == recordedProjectRoot) return '.';
  var prefix = '$recordedProjectRoot/';
  return packageRoot.startsWith(prefix)
      ? packageRoot.substring(prefix.length)
      : packageRoot;
}
