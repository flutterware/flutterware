import 'dart:io';

import 'package:flutterware/comparison_report.dart';

import '../embedder/tester_host.dart';
import '../utils/flutter_sdk.dart';

/// The machine this comparison is running on, as the report records it.
ComparisonHost currentComparisonHost() => ComparisonHost(
  os: Platform.operatingSystem,
  cpus: Platform.numberOfProcessors,
  rasterizer: hostRasterizer(),
);

/// What decides how [sdk] draws on this machine, for a cache key: the SDK's
/// identity and the rasterizer the tester is started with.
///
/// The rasterizer because a picture drawn by Metal and one drawn by Skia's
/// software backend are not the same picture, and both used to be filed under
/// one key — a cache restored onto a runner with `FW_SOFTWARE_RENDERING` set,
/// or carried from a macOS machine to a Linux one, served pictures another
/// rasterizer had drawn.
String renderKeyOf(FlutterSdkPath sdk) => '${sdk.identity}@${hostRasterizer()}';
