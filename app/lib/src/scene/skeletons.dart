// What the tool writes when it makes a folder a group or starts a library:
// the two skeletons, kept apart from the readers because a reader is on the
// pure surface and a skeleton spells Flutter imports in its text.
import 'group_file.dart';
import 'tokens_file.dart';
import 'tokens_library.dart';

/// The skeleton a folder gets on the way to its first scene: nothing
/// declared yet, a bare wrapper.
///
/// This is the only file in the system a person writes by hand, so it is the
/// only one that keeps a comment — four lines, one per slot. The rest of what
/// used to be here (what a group is, what the editor does to the folder, why
/// an argument is named with a string) is documentation, and documentation
/// retyped into every project is not documentation, it is noise you cannot
/// correct centrally.
String emitGroupSkeleton() =>
    '''
$sceneGroupFileMarker
// widgets   the app's widgets a scene may place, with their arguments
// exports   the app's own values, named for the scenes — any type
// libraries the *$sceneTokensFileSuffix these scenes read, imported above
// wrap      what the canvas is mounted under — the app's theme
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

final $sceneGroupSymbol = SceneGroup(
  widgets: [],
  exports: [],
  libraries: [],
  wrap: (child) => MaterialApp(debugShowCheckedModeBanner: false, home: child),
);
''';

/// The skeleton `New library` writes: an empty library, the editor's own
/// from its first byte.
String emitTokensSkeleton(String symbol) =>
    emitTokensLibrary(const [], symbol: symbol);
