/// The scenario replay page: a project's scenarios, run on the fake clock in
/// a browser and stopped at the step a request names.
///
/// `fw` writes the entry point that calls [runScenarioReplay] and builds it.
/// Nothing else imports this library.
library;

export 'src/scenarios/replay_page.dart' show ReplayFile, runScenarioReplay;
export 'src/scenarios/replay_protocol.dart';
