/// The contract a render point is declared in: [WidgetRender] and
/// [DocumentRender] descriptors, the wire-safe [RenderOptions], and the
/// result and warning types.
///
/// This is the library the app and the server *share* — typically through a
/// third package of the team's own that both import. It touches neither
/// Flutter nor `dart:io`, so a package importing it still compiles for the
/// web; the server's door, which spawns guests, is
/// `package:flutterware/render_client.dart`, and the app binds
/// implementations through `package:flutterware/render.dart`.
library;

export 'src/render/contract.dart';
