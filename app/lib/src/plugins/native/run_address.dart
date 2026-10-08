/// How the run cockpit writes itself into an address, and how it reads itself
/// back out.
///
/// Both directions in one file, like `server_address.dart`: the address is
/// written by run chips and tab buttons, and read by the panel deciding what to
/// show. The round trip is the contract.
///
/// The shapes:
///
///     …/flutterware.run                  the runs, first one shown
///     …/flutterware.run/new              the page that starts one
///     …/flutterware.run/<key>            a run, on its screen
///     …/flutterware.run/<key>/screen     the same, said out loud
///     …/flutterware.run/<key>/logs       its output
///
/// `<key>` is [runHandleKey] — `app-` and twelve hex characters. It hashes
/// the worktree, the device and the entry point, which means it is *stable
/// across relaunch*: stop Staging on the iPhone, start it again, and the same
/// address still names it. That is the whole reason a run gets an address at
/// all. Nothing durable points at a single process, because a run is
/// ephemeral — what agents write down for the long term are journeys, and
/// those are deliberately last.
///
/// The tab list is open on purpose. `Screen` and `Logs` arrive with the inspect
/// slice; `Data` is a devbar plugin reporting into the cockpit later. `Network`
/// was reserved for one too, and became native instead — the VM's http profile
/// answers with no app cooperation, and that reach beat the plugin route.
///
/// There is no `tree` tab, and there was one for a day. The Screen tab is a
/// split — the picture on the left, the widget tree filling the rest — and
/// pulling the tree out into a third tab separated the two things you look at
/// together. An address written against that build reads back as the screen,
/// which is where the tree now is.
///
/// [RunViewKind.byName] answers null for a tab this build has never heard of,
/// and the panel falls back rather than throwing — an address is a thing people
/// type, and one from a newer build should degrade to the run rather than to an
/// error.
library;

/// Which pane of one run the address names.
enum RunViewKind {
  /// The picture and the widget tree, side by side.
  screen,

  /// The run's journal — every tool step, with its screenshot. Readable even
  /// while the app is building or after it died: the journal is a file.
  steps,

  logs,

  /// The app's HTTP traffic, read from the VM's own http profile — present
  /// for every debug run, no devbar required.
  network,

  /// What the *app* reports about itself — the devbar plugins that declared a
  /// panel. `Screen` is what flutterware can see of a run; this is what the
  /// app chose to say.
  panels,

  /// The values this run's `main` was called with, changeable here because
  /// the launch form is a different page and starting again there is a
  /// rebuild.
  knobs;

  static RunViewKind? byName(String name) {
    for (var kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// A place in the cockpit: a run and one of its panes, or the page that starts
/// a new one.
class RunPlace {
  const RunPlace(this.runKey, {this.view = RunViewKind.screen}) : isNew = false;

  /// The page that starts a run. Not a run, so it has no key and no pane.
  const RunPlace.newRun()
    : runKey = null,
      view = RunViewKind.screen,
      isNew = true;

  /// The default: whichever run the panel picks, on its screen.
  const RunPlace.first()
    : runKey = null,
      view = RunViewKind.screen,
      isNew = false;

  /// `app-03109c1723af`, or null when no particular run is named.
  final String? runKey;

  final RunViewKind view;

  /// True for `…/new`.
  final bool isNew;

  @override
  bool operator ==(Object other) =>
      other is RunPlace &&
      other.runKey == runKey &&
      other.view == view &&
      other.isNew == isNew;

  @override
  int get hashCode => Object.hash(runKey, view, isNew);

  @override
  String toString() => 'RunPlace(${runSegmentsOf(this).join('/')})';
}

/// The segment naming the page that starts a run.
const newRunSegment = 'new';

/// The segments naming one run's pane.
///
/// `screen` is written out rather than left implicit. A tab strip whose first
/// tab produces a shorter address than the others makes "copy this address"
/// mean something different depending on which tab you were on.
List<String> runSegments(
  String runKey, {
  RunViewKind view = RunViewKind.screen,
}) => [runKey, view.name];

List<String> runSegmentsOf(RunPlace place) {
  if (place.isNew) return const [newRunSegment];
  if (place.runKey case var key?) return runSegments(key, view: place.view);
  return const [];
}

/// The inverse of [runSegments].
///
/// A tail this build does not know — a tab added by a plugin, a typo — reads
/// back as the run on its screen rather than as nothing. Losing the pane is a
/// smaller lie than losing the run.
RunPlace runPlace(List<String> segments) {
  if (segments.isEmpty || segments.first.isEmpty) return const RunPlace.first();
  if (segments.first == newRunSegment) return const RunPlace.newRun();
  var view = segments.length >= 2 && segments[1].isNotEmpty
      ? RunViewKind.byName(segments[1]) ?? RunViewKind.screen
      : RunViewKind.screen;
  return RunPlace(segments.first, view: view);
}
