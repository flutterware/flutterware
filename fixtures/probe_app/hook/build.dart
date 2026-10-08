// The example's build hook, for the third 3D probe: converts the glTF under
// `assets/` into `flutter_scene_generated/` at build time — the asset
// pipeline `dart run flutter_scene:init` sets up, written by hand so the
// probe's dependency is visible. `loadScene('assets/models/probe_rig.glb')`
// then reads the converted `.fsceneb` rather than parsing the glTF at run time.
import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    buildScenes(buildInput: input, buildOutput: output);
  });
}
