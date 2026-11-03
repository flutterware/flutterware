// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/world.dart';

import 'open_world.dart' show WorldRefusal;
import 'world_trace.dart';

/// The field that has focus in a person's app, as the app said on
/// [worldFocusChannel].
class WorldField {
  const WorldField(this.kind, {this.group = const []});

  /// Null for `{}`: no field has focus.
  static WorldField? fromJson(Map<String, Object?> json) {
    if (json['kind'] == null) return null;
    return WorldField(
      FieldKind.of(json['kind']),
      group: [
        for (var kind in json['group'] as List? ?? const []) FieldKind.of(kind),
      ],
    );
  }

  final FieldKind kind;

  /// The kinds of the other fields in its `AutofillGroup`.
  final List<FieldKind> group;

  /// Whether it is half of a sign-in form: an address and a password in one
  /// `AutofillGroup`, which one pick fills together.
  bool get signIn => switch (kind) {
    FieldKind.email => group.contains(FieldKind.password),
    FieldKind.password => group.contains(FieldKind.email),
    _ => false,
  };
}

/// One thing a focused field can be filled with: a person's address, their
/// password, the last code they received.
class WorldOffer {
  const WorldOffer({
    required this.kind,
    required this.label,
    required this.value,
    this.person,
    this.group = const {},
    this.message,
  });

  /// What it is: an address, a password, a code.
  final FieldKind kind;

  /// What it fills, as its step names it: `Nurse's address`.
  final String label;

  /// What goes into the focused field.
  final String value;

  /// Whose it is; null for a code, which is the message's.
  final String? person;

  /// The rest of a sign-in form, by kind: the password that goes with an
  /// address.
  final Map<FieldKind, String> group;

  /// The message a code came in, which [OpenWorld.pick] delivers the way
  /// Enter code does.
  final String? message;

  /// Whether it is a password, which nobody should see on the screen.
  bool get secret => kind == FieldKind.password;
}

/// What [field], focused in [person]'s app, can be filled with, by its kind:
/// every person's address or phone number with [person]'s first, [person]'s
/// own password and name, and for a code field the last code [person]
/// received. Nothing for a field of no kind the world knows.
///
/// In a sign-in form an address comes with its owner's password and a
/// password with its owner's address, so one pick fills both.
List<WorldOffer> offersFor(
  String person,
  WorldField field,
  List<Person> people, {
  List<OutboxMessage> received = const [],
}) {
  var self = people.where((p) => p.name == person).firstOrNull;
  var everyone = [?self, ...people.where((p) => p.name != person)];
  var signIn = field.signIn;
  return switch (field.kind) {
    FieldKind.email || FieldKind.phone => [
      for (var each in everyone) ?_offer(each, field.kind, signIn: signIn),
    ],
    FieldKind.password || FieldKind.name => [
      if (self != null) ?_offer(self, field.kind, signIn: signIn),
    ],
    FieldKind.code => [
      for (var message in received)
        if (message.code case var code?)
          WorldOffer(
            kind: FieldKind.code,
            value: code,
            label: message.kind == 'sms'
                ? 'the code from the SMS'
                : 'the code from the ${message.kind}',
            message: message.id,
          ),
    ].take(1).toList(),
    FieldKind.other => const [],
  };
}

/// [person]'s value of [kind], named as its step will be; null when they
/// were not given one. In a sign-in form, it brings the other half along.
WorldOffer? _offer(Person person, FieldKind kind, {required bool signIn}) {
  var name = person.name;
  var value = switch (kind) {
    FieldKind.email => person.email,
    FieldKind.password => person.password,
    FieldKind.phone => person.phone,
    FieldKind.name => person.name,
    _ => null,
  };
  if (value == null) return null;
  var other = !signIn
      ? null
      : switch (kind) {
          FieldKind.email => (FieldKind.password, person.password),
          FieldKind.password => (FieldKind.email, person.email),
          _ => null,
        };
  if (other case (var otherKind, var otherValue?)) {
    return WorldOffer(
      kind: kind,
      person: name,
      value: value,
      label: "$name's address and password",
      group: {otherKind: otherValue},
    );
  }
  return WorldOffer(
    kind: kind,
    person: name,
    value: value,
    label: switch (kind) {
      FieldKind.email => "$name's address",
      FieldKind.password => "$name's password",
      FieldKind.phone => "$name's phone number",
      _ => "$name's name",
    },
  );
}

/// What a person's value is called after a dot, in `Nurse.email`: what
/// `worlds fill` takes.
const fillableFields = ['email', 'password', 'name', 'phone'];

/// [value] as `worlds fill` reads it, for [field]: `Nurse.email` is Nurse's
/// address — with Nurse's password, in a sign-in form — and anything else
/// is typed as it is, which is null here. Refused when it names a person
/// who is not there, or a value they were not given.
WorldOffer? offerNamed(String value, List<Person> people, WorldField? field) {
  var dot = value.lastIndexOf('.');
  if (dot <= 0) return null;
  var what = value.substring(dot + 1);
  if (!fillableFields.contains(what)) return null;
  var name = value.substring(0, dot);
  var person = people.where((p) => p.name == name).firstOrNull;
  if (person == null) {
    throw WorldRefusal(
      'Nobody in this world is called $name: '
      '${people.map((p) => p.name).join(', ')}.',
    );
  }
  return _offer(person, FieldKind.of(what), signIn: field?.signIn ?? false) ??
      (throw WorldRefusal(
        '$name has no $what in this world. Give them one where the script '
        "declares them: w.person('$name', $what: ...).",
      ));
}

/// What a fill did: [label] typed into the field that had focus in
/// [person]'s app, as the step [step].
class WorldFill {
  const WorldFill({
    required this.person,
    required this.label,
    required this.fields,
    this.step,
    this.at,
  });

  final String person;

  /// What it filled, as the step names it: `Nurse's address`.
  final String label;

  /// How many fields it filled: two for a sign-in form.
  final int fields;

  /// The step it was on the person's app: `manager.4`. Null from a guest
  /// built before fills were steps.
  final String? step;
  final DateTime? at;

  /// `manager.4 filled Nurse's address`.
  String get said => '${step ?? person} filled $label';
}
