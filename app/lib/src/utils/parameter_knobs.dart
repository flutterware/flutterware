import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutterware/channels.dart';

import 'enum_lookup.dart';

/// Turns a function's optional parameters into the knobs a panel can render.
///
/// The signature is the declaration. A catalog demo and a run entry point
/// ask the identical question of the identical AST — *what can somebody vary
/// here, and how should it be drawn* — so they ask it in one place. Two
/// implementations would be two behaviours for one word.
///
/// Produces [KnobDescriptor]s rather than a model of its own, which is what
/// that type was built for: *"A declaration read straight off a demo's
/// parameter list would produce the same descriptors without running
/// anything… The panel should not be able to tell the difference."*
///
/// [onSkipped] is called for a parameter that cannot be drawn, so the caller
/// can say so in whatever it uses for diagnostics. Skipping silently would
/// leave a control missing with nothing to explain it; guessing a control would
/// be worse, which is [KnobKind]'s own rule.
List<ParameterKnob> knobsFromParameters(
  FormalParameterList? parameters, {
  required String file,
  required EnumLookup lookup,
  void Function(String parameter, String reason)? onSkipped,
}) {
  var knobs = <ParameterKnob>[];
  for (var parameter in parameters?.parameters ?? const <FormalParameter>[]) {
    // A required parameter is not a knob: there is no value to fall back to, so
    // it cannot be left alone. **What to do about one is the caller's**, and the
    // two callers differ — a demo with any is not a catalog entry at all
    // (`CatalogScanner`), while an entry point with one is a launch that has to
    // be refused by name (`scanEntrypointKnobs`). Skipping quietly here and
    // asserting somebody else had already refused was wrong for entry points,
    // and the symptom was a wrapper that cast `main` to `Function()` and died.
    if (parameter.isRequired) continue;
    var name = parameter.name?.lexeme;
    if (name == null || name.isEmpty) continue;

    // Flat, not nested: analyzer 13.x dropped the `DefaultFormalParameter`
    // wrapper and `SimpleFormalParameter`, and `FormalParameter` itself now
    // carries the type, the name and the default clause.
    var defaultValue = parameter.defaultClause?.value;
    var type = parameter.type;

    // `key` is not a knob and never will be, so it is skipped in silence rather
    // than reported as undrawable. Every demo widget written as a class has one
    // — and annotating the constructor is what the README recommends for moving
    // an existing catalog — so the diagnostic was right in the letter and
    // arrived once per entry. A warning that fires on all of them is how a real
    // one gets missed. Both spellings: `super.key` writes no type at all, and
    // `Key? key` writes one no control fits.
    if (name == 'key' && (type == null || _isKey(type))) continue;

    var kind = _kindOf(type);
    if (kind != null) {
      knobs.add(
        ParameterKnob(
          KnobDescriptor(
            name: name,
            kind: kind,
            value: _literal(defaultValue),
            defaultValue: _literal(defaultValue),
          ),
          defaultSource: _unevaluatedSource(defaultValue),
        ),
      );
      continue;
    }

    if (type is! NamedType) {
      onSkipped?.call(name, 'has no type to draw a control from. $_drawable');
      continue;
    }

    // A type with arguments (`List<String>`) or a bare `dynamic` cannot be an
    // enum, so searching for one and reporting it missing would send somebody
    // looking for a declaration that was never the point.
    if (type.typeArguments != null || type.name.lexeme == 'dynamic') {
      onSkipped?.call(name, 'is `${type.toSource()}`. $_drawable');
      continue;
    }

    var found = lookup.lookup(
      file: file,
      name: type.name.lexeme,
      prefix: type.importPrefix?.name.lexeme,
    );
    if (!found.found) {
      // Both halves, because a parse cannot tell a `Duration` from an enum it
      // failed to find — and advice about exporting an enum, given about a
      // `Duration`, sends somebody looking for a file that does not exist.
      onSkipped?.call(
        name,
        'is `${type.toSource()}`. $_drawable If it is an enum: '
        '${found.problem}',
      );
      continue;
    }
    // A picker's options are the constant names, so its value is one too —
    // `Backend.dev` is offered and stored as `dev`. The wrapper turning it back
    // into an enum is the only thing that needs the type.
    knobs.add(
      ParameterKnob(
        KnobDescriptor(
          name: name,
          kind: KnobKind.picker,
          value: _enumConstant(defaultValue),
          defaultValue: _enumConstant(defaultValue),
          options: found.values,
        ),
        // Verbatim, prefix included: this is what the generated wrapper writes
        // in front of the constant, and it only compiles if it is spelled the
        // way the entry point spells it.
        enumType: type.toSource(),
        // A picker reads its default off the *end* of whatever was written
        // (`_enumConstant`), so `Backend.dev` and a constant that happens to
        // hold one are indistinguishable here — both end in a name. Only the
        // ones that came back with nothing carry their source.
        defaultSource: _enumConstant(defaultValue) == null
            ? _unevaluatedSource(defaultValue)
            : null,
      ),
    );
  }
  return knobs;
}

/// One parameter's knob, plus what only a code generator needs.
///
/// The descriptor is the wire shape and goes to panels unchanged. [enumType]
/// never leaves this process: a picker's value is a bare constant name, and
/// turning `staging` back into `m.Backend.staging` is the wrapper's job alone.
class ParameterKnob {
  const ParameterKnob(this.knob, {this.enumType, this.defaultSource});

  final KnobDescriptor knob;

  /// The parameter's type as written — `Backend`, `m.Backend`. Null unless the
  /// knob is a picker.
  final String? enumType;

  /// The default clause **as written**, for a default this cannot evaluate —
  /// `ServerUrls.localPort`, `_port`, `defaultTimeout`.
  ///
  /// Set only when there is a default and no value for it, which is what
  /// keeps it from being source text where a value belongs. A knob with a
  /// literal default has [KnobDescriptor.defaultValue] and this is null; a
  /// knob with no default at all has neither. The pair says the third thing:
  /// there *is* a default, here is how it is spelled, and nothing here can
  /// tell you what it comes to.
  ///
  /// A blank was the wrong answer to that, and reported by a consumer
  /// whose entry points look like the common case rather than an exotic one:
  /// the values knobs replace are usually already `String.fromEnvironment`
  /// constants, because that is what a `--dart-define` build reads, and a
  /// constant is a reference rather than a literal. Their form showed nothing
  /// for a parameter that plainly had a default two lines away.
  ///
  /// Deliberately not evaluated. Following `ServerUrls.localPort` to its
  /// declaration is a lookup this could do — [EnumLookup] already walks
  /// first-party files for enums — but an enum is a closed question (find the
  /// declaration, list the names) where a const initialiser is an open one:
  /// `int.fromEnvironment(…, defaultValue: 8086)` today, then `a + b`, then a
  /// const constructor, then a getter, each a new branch in something that is
  /// not a compiler. Resolution answers all of it and costs 5.5s on an entry
  /// point that imports Flutter — see [scanEntrypointKnobs], and note that
  /// this scan runs on every knob change, where the whole feature is 262ms.
  /// A project that needs the *value* has `from:` for it.
  final String? defaultSource;

  String get name => knob.name;
}

/// What a knob can be, said once.
///
/// The bound is the **control, not the literal**: the wrapper could write
/// `const Duration(seconds: 5)` perfectly well, and there would still be
/// nothing to edit it with. `KnobKind` is the whole vocabulary a panel can
/// draw, so it is the whole vocabulary a knob can have.
const _drawable =
    'A knob can be a String, bool, int, double, num or an enum; those are the '
    'controls a panel can draw.';

/// Whether a `key` parameter's written type is Flutter's own.
///
/// By name rather than by resolution, like everything else here: this is a
/// parse. The pair is what earns the silence — a parameter called `key` that is
/// something else entirely is an undrawable knob like any other, and gets said.
bool _isKey(TypeAnnotation type) =>
    type is NamedType && type.name.lexeme == 'Key';

/// The kind a built-in type draws as, or null for anything that is not one.
///
/// Nullability is not a kind: `String?` is still a text field, it just starts
/// empty. `num` draws as a number for the same reason `double` does — the
/// distinction matters to the compiler and not to the control.
KnobKind? _kindOf(TypeAnnotation? type) =>
    switch (type is NamedType ? type.name.lexeme : null) {
      'String' => KnobKind.string,
      'bool' => KnobKind.boolean,
      'int' => KnobKind.integer,
      'double' || 'num' => KnobKind.number,
      _ => null,
    };

/// A default expression's value, when it is a literal we can carry.
///
/// Anything else — a const constructor, an expression — becomes null, which
/// reads as "no default" and is the honest answer: the panel would otherwise
/// show source text where a value belongs.
Object? _literal(Expression? expression) => switch (expression) {
  SimpleStringLiteral(:var value) => value,
  BooleanLiteral(:var value) => value,
  IntegerLiteral(:var value) => value,
  DoubleLiteral(:var value) => value,
  _ => null,
};

/// How a default is written, for the ones [_literal] cannot turn into a value.
///
/// Null when there is no default at all, and null when there is one this could
/// read — a caller that has the value does not want the spelling as well, and
/// putting the source anywhere the value belongs is the thing this is careful
/// not to do. See [ParameterKnob.defaultSource].
///
/// Trimmed of nothing and interpreted in no way: whatever the author wrote is
/// exactly what they will recognise.
String? _unevaluatedSource(Expression? expression) =>
    expression == null || _literal(expression) != null
    ? null
    : expression.toSource();

/// The constant name out of `Backend.dev`, `m.Backend.dev` or a bare `dev`.
///
/// Taken off the end rather than parsed into shapes: every spelling of an enum
/// constant ends in the constant, and the prefix in front of it is exactly what
/// a picker does not want.
String? _enumConstant(Expression? expression) {
  if (expression == null) return null;
  var source = expression.toSource();
  var last = source.split('.').last.trim();
  return last.isEmpty ? null : last;
}
