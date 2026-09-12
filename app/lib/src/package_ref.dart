import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'utils/flutter_sdk.dart';

/// One package on disk, and the ambient handles a service needs to work on it.
///
/// The pure half of what [Project] used to be. `Project` was a god-object: it
/// declared a field for every service, so *importing* it pulled the drawing and
/// test_runner models — and therefore `package:flutter` — into the closure of
/// anything that merely wanted a path. That is what kept `fw` from linking a
/// plugin at all (`test/tools/projection_dump_test.dart` records the symptom).
///
/// Services take this instead. It carries no services, so it cannot spread.
///
/// Distinct from `Pkg` in `package:flutterware`: `Pkg` is what
/// `tool/flutterware.dart` *declares*, this is the resolved runtime handle.
class PackageRef {
  PackageRef(this.context, String path, this.flutterSdkPath)
    : directory = Directory(path);

  final AppContext context;
  final Directory directory;
  final FlutterSdkPath flutterSdkPath;

  /// Absolute already is absolute: `Directory.absolute` asks the platform
  /// for the working directory, and a recorded project's root is spelled in
  /// full on a platform that has none.
  String get absolutePath =>
      p.isAbsolute(directory.path) ? directory.path : directory.absolute.path;

  @override
  String toString() => 'PackageRef($absolutePath)';
}
