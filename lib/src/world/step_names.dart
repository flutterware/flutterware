/// What a world guest, a world's script and the world that reads them agree
/// on — no Flutter, so the owner, which may be `fw` or the MCP server, and the
/// script can import it.
library;

/// The zone key a step travels under — in an app, around a gesture's
/// callbacks; in a world's script, around an action. The same symbol a
/// server's adapter puts [worldStepHeader] under (`FlutterwareServer.stepKey`),
/// so a server hosted in the script reads one key either way.
const worldStepKey = #fwStep;

/// Whose a world's own actions are: `world.3` is its third action run. Not a
/// person — nobody's phone — but it steps like one.
const worldActionsOwner = 'world';

/// The channel a world guest names its steps on: one event per gesture,
/// `{step, verb, target}`.
const worldStepsChannel = 'world/steps';

/// The channel a world guest reports the requests it stamped on:
/// `{step, method, url, how}`, `how` being `zone` or `window`.
const worldRequestsChannel = 'world/requests';

/// The channel a world types into a person's app on: `type {text}` fills the
/// app's focused field, answering `{typed}` — false when nothing has focus.
const worldInputChannel = 'world/input';

/// The header a request carries its step in — what a server's adapter puts
/// in the zone as `FlutterwareServer.stepKey`.
const worldStepHeader = 'x-fw-step';

/// What [person]'s steps are named by: `Ben` → `ben`, so `ben.3`; `Dr Kay` →
/// `dr-kay`. A header value, and short.
String worldStepPrefix(String person) {
  var slug = person
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'guest' : slug;
}

/// The prefix of [step] — whose it is — or null for a step no guest named.
String? worldStepOwner(String step) {
  var dot = step.lastIndexOf('.');
  return dot <= 0 ? null : step.substring(0, dot);
}
