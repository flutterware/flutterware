//@flutterware:scenes=1
// The fixture group: what the fixture scenes may place and read, declared
// the way an app declares it.
//
// The test's second grader reads this: the generator writes `scene_args.dart`
// from it, the compiler checks `sample.scene.dart` against that, and the
// parser reads the same file back.
import 'package:material_ui/material_ui.dart' show Color, FontWeight, TextStyle;
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import 'sample.tokens.dart';
import 'sample_widget.dart' as app;

final scenes = SceneGroup(
  libraries: [sampleTokens],
  // The app's own, by name: what the exports tests read and the generated
  // getters convert.
  exports: [
    const Token<Color>('accent', Color(0xFF0000FF)),
    const Token<TextStyle>(
      'heading',
      TextStyle(fontSize: 40, fontWeight: FontWeight.w800),
    ),
  ],
  widgets: [
    ExternalWidget(
      'SampleChip',
      args: [const Arg<String>('label', 'chip'), const Arg<double>('weight')],
      build: (a) => app.SampleChip(label: a.text('label') ?? 'chip'),
    ),
  ],
);
