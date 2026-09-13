/// The translations plugin over a recording: the live core and the live
/// panel, handed a [TranslationSource] that answers from what
/// `tool/demo/record.dart` kept rather than from the package's directory.
///
/// Three things the plugin reads, and the recording holds each as the plugin
/// asks for it. The catalogs are the text of every file each declared glob
/// matched, keyed by the glob, because a recording cannot walk one. The
/// export is `keys.json` verbatim with its `shots/` tree beside it, under a
/// directory the recorded source names as the export's own — so the panel
/// joins shot paths under it exactly as it does on disk, and what it builds is
/// a recording path. Nothing here names a real directory.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutterware/translations.dart';
// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';

import '../plugins/native/translations_core.dart';
import '../translations/loader.dart';
import 'recording.dart';

/// Where the translations core reads from when the project is a recording —
/// `TranslationsCore(source: …)`.
class RecordedTranslationSource extends TranslationSource {
  const RecordedTranslationSource(this.recording);

  final Recording recording;

  @override
  CatalogReader catalogsUnder(String packageRoot) => (filesGlob) async {
    var path = recordedTranslationCatalogsPath(_packagePathOf(packageRoot));
    // Through `Future.value`, for the reason `recordedIconScanner` gives: a
    // synchronous end must still resume this function on a microtask.
    var text = await Future.value(recording.readString(path));
    if (text == null) {
      throw StateError(
        'This recording has no translation catalogs for "$packageRoot" '
        '(looked for $path).',
      );
    }
    var json = jsonDecode(text) as Map<String, Object?>;
    var globs = json['globs'] as Map<String, Object?>? ?? const {};
    return switch (globs[filesGlob]) {
      Map files => files.cast<String, String>(),
      // A glob the recording did not walk matched nothing, which is what the
      // live reader says of a glob that matches nothing.
      _ => const {},
    };
  };

  @override
  String exportDirectoryIn(String packageRoot) =>
      recordedTranslationExportDir(_packagePathOf(packageRoot));

  @override
  Future<({TranslationExport export, DateTime at})?> readExport(
    String directory,
  ) async {
    var text = await Future.value(
      recording.readString('$directory/$translationExportFile'),
    );
    if (text == null) return null;
    return (
      export: TranslationExport.fromJson(
        jsonDecode(text) as Map<String, Object?>,
        directory: directory,
      ),
      // A recording carries no clock: the export was written at the instant
      // everything else in it renders at.
      at: pinnedClockOrigin,
    );
  }

  @override
  Future<Uint8List?> readShot(String path) =>
      // The panel joined the path with the platform's separator, and the
      // recording is addressed with `/` on every platform.
      Future.value(recording.readBytes(path.replaceAll(r'\', '/')));
}

/// The recorded project has one package at `.`, which the core addresses by
/// its absolute root.
String _packagePathOf(String packageRoot) {
  if (packageRoot == recordedProjectRoot) return '.';
  var prefix = '$recordedProjectRoot/';
  return packageRoot.startsWith(prefix)
      ? packageRoot.substring(prefix.length)
      : packageRoot;
}
