/// Reading a scenario as a **take**, so a reel can be edited from it.
///
/// A scenario says what it did through `s.film` and `s.title` (exported from
/// `flutter_test.dart`, where a scenario is written). This is the other end:
/// what an *edit* reads, in the package that renders the reel.
library;

export 'src/scenarios/cues.dart';
export 'src/scenarios/reel.dart';
export 'src/scenarios/scene_stage.dart';
export 'src/scenarios/stage.dart';
export 'src/scenarios/take.dart';
