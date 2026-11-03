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

/// How long an app's start, `ana.0`, lasts while nobody touches the app:
/// what it sends in that time is its start's.
const worldStartWindow = Duration(seconds: 10);

/// What a reload of a world is named by, as its own step: `reload.2` is the
/// second since the world opened, and the world's own.
const worldReloadPrefix = 'reload';

/// The channel a world guest names its steps on: one event per gesture,
/// `{step, verb, target}`.
const worldStepsChannel = 'world/steps';

/// The channel a world guest reports the requests it stamped on:
/// `{step, method, url, how}`, `how` being `zone` or `window`.
const worldRequestsChannel = 'world/requests';

/// The channel a world types into a person's app on: `type {text}` fills the
/// app's focused field, answering `{typed}` — false when nothing has focus.
/// `fill {text, group}` does too, and fills the rest of the field's
/// `AutofillGroup` from `group`, by kind, answering `{filled}`: how many
/// fields it filled.
const worldInputChannel = 'world/input';

/// The channel a world guest reports its focused text field on, each time
/// focus moves: `{kind, group}` — the field's [FieldKind] and those of the
/// other fields in its `AutofillGroup` — or `{}` when no field has focus.
const worldFocusChannel = 'world/focus';

/// What a text field in a person's app is for, as a phone's autofill reads
/// it: what the world offers to fill it with. Its name is how the
/// [worldFocusChannel] spells it.
enum FieldKind {
  /// An address or a username: every person's address is offered.
  email,

  /// The person's own password.
  password,

  /// The person's name.
  name,

  /// A phone number: every person's.
  phone,

  /// A one-time code: the last one the person received.
  code,

  /// Anything else, which is offered nothing.
  other;

  /// [name] back into a kind; [other] for one this world does not know.
  static FieldKind of(Object? name) =>
      values.asNameMap()[name] ?? FieldKind.other;
}

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
