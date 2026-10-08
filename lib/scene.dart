/// The Flutter half of the scene system: motion playback and the bridges
/// between the pure authoring core (`package:flutterware/scene_authoring.dart`)
/// and Flutter's types.
///
/// This library never exports the authoring vocabulary, so a file can import
/// it next to `material.dart` without a name colliding.
///
/// **Experimental.** This surface still moves with the editor and is not yet
/// a supported API.
library;

export 'src/scene/flutter_bridge.dart';
export 'src/scene/host.dart';
export 'src/scene/layered_text.dart';
export 'src/scene/player.dart';
export 'src/scene/shader_programs.dart' show precacheSceneShaders;
export 'src/scene/view.dart';
