/// What a world guest and the world that reads it agree on — no Flutter, so
/// the owner, which may be `fw` or the MCP server, can import it.
library;

/// The channel a world guest names its steps on: one event per gesture,
/// `{step, verb, target}`.
const worldStepsChannel = 'world/steps';

/// The channel a world guest reports the requests it stamped on:
/// `{step, method, url, how}`, `how` being `zone` or `window`.
const worldRequestsChannel = 'world/requests';

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
