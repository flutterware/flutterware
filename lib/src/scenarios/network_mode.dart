/// What a scenario's http requests reach.
///
/// A scenario runs under fake time, and `flutter_test` answers every request
/// with an empty 400 — so an app that loads an avatar renders a blank box and
/// says nothing about why. This is the setting that decides what happens
/// instead, and it is said in the same places [Shots] is: the project's
/// `fw.network(...)`, a folder's `runScenarios(network: ...)`, one run's
/// `--network=`, one `scenario(network: ...)`.
///
/// **Nearest wins**, and those four are the ladder in order — so a run reaches
/// past a folder and the project, and a `scenario(network: ...)` reaches past
/// all three. A run flag is not a master switch, with one exception:
/// `--network=record` reaches a scenario that says `replay`, because both name
/// the same recording. Against a scenario that says `off` or `live` it records
/// nothing, and says so on stderr rather than leaving an empty store to be
/// discovered later.
///
/// Whatever the mode, a `s.network` stub always beats it — the mode governs
/// what happens to the requests the scenario did not state an answer for.
///
/// It lives in its own file, like [Shots], because the CLI reads it to
/// validate an argument and must not reach Flutter to do so, while the
/// funnel that acts on it is nothing but Flutter.
library;

enum ScenarioNetwork {
  /// Nothing leaves the process.
  ///
  /// A request nothing stubbed fails **immediately**, with a message naming
  /// the url and how to answer it, and lands on the step as a network event.
  ///
  /// It does not fail the scenario. A decorative avatar is not a reason to
  /// throw away a flow's other twelve assertions, and a scenario that wants
  /// the picture says so with a stub, with [replay] or with [live]. That takes
  /// a filter to hold: an `Image.network` with no `errorBuilder` has no error
  /// listener of its own, so the throw reaches `FlutterError.reportError`,
  /// which in a test binding is what turns a test red — see the
  /// `ScenarioNetworkRefusal` clause in `_runScenario`. Without it, adopting
  /// this version would turn red every suite with an unguarded network image
  /// on screen, including the https ones that drew a blank frame and passed
  /// before any of this existed.
  ///
  /// The default, and an improvement on what it replaces even for a suite that
  /// never configures anything: `flutter_test`'s own answer hangs rather than
  /// fails when the url is https.
  off,

  /// Requests go out, and what comes back is whatever the network says today.
  ///
  /// The easy mode and the honest one — the app talks to the thing it talks
  /// to. It costs the property every other default here exists to protect:
  /// two runs of the same suite are no longer the same run, an aeroplane or a
  /// rate limit turns a green suite red, and the image cache is emptied per
  /// scenario by design, so a suite pays its round trips once *per scenario*
  /// rather than once.
  live,

  /// Requests are answered from the recording committed beside the scenarios,
  /// and nothing leaves the process.
  ///
  /// What [record] wrote, played back — offline, in microseconds, and
  /// byte-identically. This is the mode a suite lives in: the author writes
  /// the scenario as though the network were simply there, records once, and
  /// commits what came back, and every run after that reproduces it with no
  /// connection at all.
  ///
  /// A request the recording does not hold is **refused**, naming the url and
  /// the command that would record it, and the scenario **fails** when its
  /// body is over, listing every such url. Answering it with a 404, or with
  /// silence, would put the store's gaps into the pictures instead of into the
  /// output — and so would a green result over them. A recorded error status
  /// is not a gap: it replays as what the server said.
  ///
  /// `--network=record` reaches a scenario that says this about itself; see
  /// [record].
  replay,

  /// Requests go out, and what comes back is written to the recording.
  ///
  /// Always out, never partly from the store: "refresh what I have" and "fill
  /// in what I am missing" are the same command otherwise, and the one you
  /// wanted is whichever you did not get. What it fetches it overwrites; what
  /// it does not ask for it leaves, so one endpoint can be refreshed by
  /// running one scenario. What comes back unchanged is not rewritten, so a
  /// re-record shows in a diff only where the network moved.
  ///
  /// As a run's `--network=record` it also reaches a scenario that says
  /// `replay` about itself — refreshing a recording is what that scenario's
  /// mode is for.
  ///
  /// The caller is handed the bytes that were written, not the bytes off the
  /// wire, so a `record` run and the `replay` runs after it draw the same
  /// pictures.
  record,
}

/// [raw] as a mode, or a refusal listing the ones there are.
///
/// Refused rather than defaulted: a typo that quietly means `off` is a suite
/// whose pictures are all blank for a reason nothing on the screen says.
ScenarioNetwork parseScenarioNetwork(String raw) =>
    ScenarioNetwork.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => throw ArgumentError.value(
        raw,
        'network',
        'Not a network mode. One of: ${scenarioNetworkNames.join(', ')}',
      ),
    );

/// Every mode's name, in the order they are worth offering in.
const scenarioNetworkNames = ['off', 'replay', 'record', 'live'];
