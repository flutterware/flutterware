/// The pure-Dart side of the render story: a [RenderPool] spawns resident
/// guests from a directory produced by `fw render bundle` and invokes the
/// app's render points fully typed.
///
/// ```dart
/// var renders = await RenderPool.start(bundle: '/opt/acme/render', warm: 2);
/// var svg = await renders.svg(monthlyChart, ChartRequest(...),
///     size: const RenderSize(412, 230));
/// ```
///
/// Nothing behind this library imports Flutter, so a server that imports it
/// never loads a widget — but the package it ships in is a Flutter package,
/// so resolving it takes a Flutter SDK on the machine that runs `pub get`.
/// That is the same bargain `package:flutterware/server.dart` already makes,
/// and it stops at resolution: the deployed image needs nothing but the
/// bundle directory, which carries its own `flutter_tester`.
library;

export 'render_contract.dart';
export 'src/render/client.dart' show RenderException, RenderPool;
export 'src/render/protocol.dart'
    show
        BundleFont,
        RenderBundleManifest,
        RenderPointInfo,
        RenderPointKind,
        renderProtocolVersion;
