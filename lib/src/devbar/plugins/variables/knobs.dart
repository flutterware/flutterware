/// The variables plugin, described as a panel: every devbar variable becomes a
/// knob, and a feature flag is a variable.
///
/// The app owns the list (owner, 2026-08-11: *"only devbar can report the
/// available flags"*). A flag does not exist until the widget declaring it
/// builds, so what is reported here grows as the user navigates — there is
/// nothing static to promise, and a static list would go out of date. What the
/// host may do about that is [presetAction]: name a value for a
/// flag that has not appeared yet, and have it apply the instant one does.
library;

import 'package:collection/collection.dart';

import '../../../plugins/action.dart';
import '../../../ui_catalog/knob.dart';
import 'plugin.dart';

/// Pre-sets a value for a key whether or not anything has declared it.
///
/// The host's half of mirroring variables as knobs. It lands in
/// [VariablesPlugin.overrides] — session-scoped, never the persisted store —
/// because the cockpit is the thing that remembers wishes across runs, and a
/// value written into the app's own store would outlive the intent of whoever
/// asked for it.
const presetAction = PluginAction(
  'preset',
  'Pre-set a value',
  description:
      'Applies to a variable that has not been declared yet, the moment it is.',
  parameters: [
    ActionParameter('name', 'Name'),
    ActionParameter('value', 'Value'),
  ],
);

/// What the wire calls a variable whose kind cannot be described.
///
/// A knob rendered as the wrong control is worse than one the panel admits it
/// cannot show — the rule `KnobDescriptor` already states. A variable of some
/// exotic type is simply left out of the panel and stays editable in the
/// overlay.
KnobDescriptor? describeVariable(DevbarVariable variable) {
  var definition = variable.definition;
  var value = variable.currentValue;

  if (definition is DevbarPickerVariableDefinition) {
    var options = definition.options;
    return KnobDescriptor(
      name: variable.key,
      kind: KnobKind.picker,
      // Only the labels cross the wire — the values behind them are the app's,
      // and only the app can turn a label back into one.
      value: options[value],
      defaultValue: options[definition.defaultValue],
      options: options.values.toList(),
      description: variable.description,
    );
  }

  if (definition is DevbarSliderVariableDefinition) {
    return KnobDescriptor(
      name: variable.key,
      kind: definition.isInt ? KnobKind.integer : KnobKind.number,
      value: value,
      defaultValue: definition.defaultValue,
      min: definition.min,
      max: definition.max,
      step: definition.step,
      description: variable.description,
    );
  }

  var kind = switch (definition.defaultValue) {
    bool() => KnobKind.boolean,
    int() => KnobKind.integer,
    double() => KnobKind.number,
    String() => KnobKind.string,
    _ => null,
  };
  if (kind == null) return null;
  return KnobDescriptor(
    name: variable.key,
    kind: kind,
    value: value,
    defaultValue: definition.defaultValue,
    description: variable.description,
  );
}

/// Applies a knob value from the host to [variable].
///
/// Coerces rather than trusts: JSON has one number type, so an `int` variable
/// reached over the wire arrives as whatever the sender happened to encode. A
/// picker arrives as a *label* and is refused when it names no option — better
/// than clearing a value because a stale panel sent a stale choice.
void writeVariable(DevbarVariable variable, Object? value) {
  var definition = variable.definition;

  if (definition is DevbarPickerVariableDefinition) {
    var match = definition.options.entries.firstWhereOrNull(
      (entry) => entry.value == value,
    );
    if (match == null) return;
    (variable as dynamic).storeValue = match.key;
    return;
  }

  var wanted = definition.defaultValue;
  var coerced = value;
  if (wanted is int && value is num) {
    coerced = value.toInt();
  } else if (wanted is double && value is num) {
    coerced = value.toDouble();
  } else if (wanted is bool && value is! bool) {
    coerced = value == true || value == 'true';
  } else if (wanted is String && value is! String) {
    coerced = value?.toString();
  }
  (variable as dynamic).storeValue = coerced;
}
