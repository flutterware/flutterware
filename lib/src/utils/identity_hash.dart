/// Values that mean nothing outside the process that minted them.
///
/// Its own file because it is shared, and the sharing is the point: an
/// identity hash is noise on a widget's properties, on a scenario target and
/// on an app event alike, and three copies of one rule is three chances to fix
/// only two of them. Plain Dart, like both of its callers.
///
/// Read the entries below as a list of **incidents** rather than of patterns.
/// Every one of them is a bug somebody paid for, and the next reader deciding
/// whether a sixth belongs needs to know what the other five cost. Two rules
/// govern an addition:
///
/// 1. **Anchor on the exact syntactic shape the emitter produces**, never on
///    "digits look like noise". That discipline is what keeps
///    `ValueKey('build#a1b2c')` — the author's own value, and the only thing
///    telling two of those apart — intact.
/// 2. **Only what no project can make deterministic.** A project's own
///    `Uuid()` and `DateTime.now()` do not belong here; those are bugs to
///    report, not noise to hide.
library;

/// `ScrollController#cf895(offset 0.0)` → `ScrollController#(offset 0.0)`,
/// and `[#a1b2c]` → `[#]`.
///
/// `describeIdentity` and `shortHash` render an object as its type followed by
/// five hex characters of `hashCode`, which the VM assigns per allocation. The
/// same controller therefore spells itself differently in every process and
/// after every rebuild, and [InspectNode] exists to be *carried between*
/// processes — so a value that means nothing outside the one that minted it
/// cannot travel in it. Left in, it cost a previews comparison 21 entries
/// reported as changed with nothing changed about them.
///
/// Anchored on a **type-shaped** token — uppercase or `_` initial, generics
/// allowed — or on the `[` of a bare `UniqueKey`, because that is precisely
/// what `describeIdentity` emits. A lower-case word before the `#` is nobody's
/// hash: `ValueKey('build#a1b2c')` is the author's own value, and the only
/// thing telling two of those apart, so it keeps every character.
///
/// **Unless the bracket already opened with a type.** `GlobalObjectKey` and
/// `ObjectKey` spell themselves as their own type, a space, and
/// `describeIdentity` of the object they identify — so the token before the
/// `#` is the *value's* runtime type and may be anything at all, lower-case
/// included: `[GlobalObjectKey int#8cc0b]`. That one slipped through
/// the rule above and cost a consumer every scenario of a `go_router` app
/// reported as changed, forever: `_CustomNavigator` keys itself with a
/// `GlobalObjectKey` over an `int`, so it is in the tree of every routed
/// screen and in none of the previews, which mount a widget directly. The
/// first alternative below admits a lower-case type token, and only where a
/// type-shaped one has already opened the bracket — which is what keeps
/// `ValueKey`'s `[<'build#a1b2c'>]` out of it.
///
/// Both the fields that carry a rendered object go through here — a widget's
/// [InspectNode.properties] and its resolved [InspectNode.textStyle] — which
/// is the point of doing it beside [shortenPropertyValue] rather than at each
/// call site. [InspectNode.splitKey] uses it for the same reason on keys.
String withoutIdentityHash(String value) => value
    .replaceAllMapped(_identityHash, (match) => '${match[1]}#')
    .replaceAll(_autofillId, 'EditableText-')
    .replaceAllMapped(_closureToken, (match) => "'${match[1]}@'");

final _identityHash = RegExp(
  r'(\[[_A-Z][A-Za-z0-9_]*(?:<[^#\]]*>)? [^#\]]*'
  r'|\['
  r'|[_A-Z][A-Za-z0-9_]*(?:<[^#]*>)?)#[0-9a-f]{5}(?![0-9a-f])',
);

/// `EditableText-873965551` → `EditableText-`.
///
/// `EditableTextState.autofillId` is its type and its `hashCode`, so every
/// text field on screen spells itself differently in every process. Measured
/// on a real 128-scenario suite it was **266 of the 402** run-to-run
/// differences in the events channel — the framework's own, reducible by
/// nobody downstream, and reached only because a `TextInput.setClient` message
/// carries the id in its arguments.
///
/// Deliberately literal rather than a general `Type-<hashCode>` rule. A
/// decimal run after a capitalised word is the shape of a great many real
/// values — `SKU-4491` — where five hex characters after one is the shape of
/// almost nothing else. This is the only instance anybody has proven; the next
/// one earns its own line here.
final _autofillId = RegExp(r'\bEditableText-\d+');

/// `from Function '_imageBuilder@21460559':.` → `from Function '_imageBuilder@':.`
///
/// Dart mangles a **private** member's name with a token derived from its
/// library, and prints the mangled form in `Closure.toString()`. So a widget
/// holding a private callback — `octo_image`'s `imageBuilder` is the reported
/// case — renders a number in its properties that no reader can use and that
/// two compilations need not agree on.
///
/// Worse than run-to-run noise: base and head *are* two compilations, so this
/// is a **permanent** false positive on the tree channel, reported on every
/// comparison forever. The same failure mode the `GlobalObjectKey` entry above
/// cost somebody, arriving by a different road.
///
/// Only the token goes. Measured, a closure prints no `line:col` to strip and
/// an anonymous one prints no name at all (`Closure: (Object?) => Object?`),
/// so there is nothing else here that moves. The quotes on both sides are what
/// make this safe: an `@` between an identifier and a digit run, inside the
/// quotes the framework itself wrote.
final _closureToken = RegExp(r"'([A-Za-z_$][A-Za-z0-9_$]*)@\d+'");
