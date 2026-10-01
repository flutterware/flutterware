import 'dart:core' as core;
import 'dart:core';

import 'package:flutter/widgets.dart';

import 'knob.dart';

/// The controls an entry declares by asking for them while it builds.
///
/// A knob is a read with a default, not a declaration. Nothing registers
/// one: `context.knobs.bool('Edit mode', false)` *is* the declaration, and the
/// same call answers with `false` where nothing is hosting — a real app, a
/// test, Flutter's own previewer. That is what makes it safe to leave in a
/// widget that ships.
///
/// This base class is that unhosted answer. [EditableKnobs] is the hosted one.
class Knobs {
  /// What a knob answers with when no [KnobsProvider] is above it.
  static final unanswered = Knobs();

  String string(String name, String defaultValue) {
    return defaultValue;
  }

  core.num num(
    String name,
    core.num defaultValue, {
    core.num? min,
    core.num? max,
  }) {
    return defaultValue;
  }

  core.int int(
    String name,
    core.int defaultValue, {
    core.int? min,
    core.int? max,
  }) {
    return defaultValue;
  }

  core.double double(
    String name,
    core.double defaultValue, {
    core.double? min,
    core.double? max,
  }) {
    return defaultValue;
  }

  core.bool bool(String name, core.bool defaultValue) {
    return defaultValue;
  }

  /// A choice between named options, label to value.
  ///
  /// [swatch] and [icon] put a colour dot or a glyph before each label on a
  /// catalog page. [style] is how the picker is drawn: a segmented control
  /// puts every option on show, for a choice like Light and Dark.
  T picker<T>(
    String name,
    Map<String, T> values,
    T defaultValue, {
    Color Function(T value)? swatch,
    IconData Function(T value)? icon,
    PickerStyle style = PickerStyle.dropdown,
  }) {
    return defaultValue;
  }

  DateTime? nullableDateTime(
    String name,
    DateTime? defaultValue, {
    core.bool dateOnly = false,
  }) {
    return defaultValue;
  }

  DateTime dateTime(
    String name,
    DateTime defaultValue, {
    core.bool dateOnly = false,
  }) {
    return defaultValue;
  }

  void button(String name, String text, VoidCallback onTap) {}
}

class EditableKnobs implements Knobs {
  final void Function() onRefresh;
  final void Function() onAdded;
  final knobs = <String, Knob>{};

  EditableKnobs({required this.onRefresh, required this.onAdded});

  /// The names declared since [beginPass], or null when no pass is open.
  ///
  /// A knob exists because a build asked for it, which makes a build the only
  /// thing that can retire one: a knob renamed or deleted in the source is
  /// simply never asked for again, and without a pass to notice that, it
  /// lingers in [knobs] as a control that reads nothing.
  Set<String>? _pass;

  /// Starts recording which knobs a build declares.
  ///
  /// Between this and [endPass], [knobs] is the *union* of the last build
  /// and this one — a knob is only known to be gone once the pass closes.
  void beginPass() => _pass = <String>{};

  /// Drops every knob the pass did not declare, and answers how many went.
  core.int endPass() {
    var declared = _pass;
    _pass = null;
    if (declared == null) return 0;
    var retired = [
      for (var name in knobs.keys)
        if (!declared.contains(name)) name,
    ];
    for (var name in retired) {
      var knob = knobs.remove(name);
      knob?.removeListener(_onRefresh);
      knob?.dispose();
    }
    // Re-ordered to match the build, not the order things were first seen: a
    // knob belongs in the panel where the demo asks for it, so one inserted
    // halfway through a build appears halfway down rather than at the bottom.
    // Without this a rename reads as a knob that moved as well as changed.
    var ordered = {for (var name in declared) name: ?knobs[name]};
    knobs
      ..clear()
      ..addAll(ordered);
    return retired.length;
  }

  T _addKnob<T extends Knob>(String name, T Function() putIfAbsent) {
    _pass?.add(name);
    var existingKnob = knobs[name];
    T knob;
    if (existingKnob is T) {
      knob = existingKnob;
    } else {
      if (existingKnob != null) {
        existingKnob.dispose();
        existingKnob = null;
      }

      knob = putIfAbsent();
      knob.addListener(_onRefresh);
      knobs[name] = knob;

      onAdded();
    }
    return knob;
  }

  void _onRefresh() {
    onRefresh();
  }

  @override
  String string(String name, String defaultValue) {
    var knob = _addKnob(name, () => StringKnob())..defaultValue = defaultValue;

    return knob.requiredValue;
  }

  @override
  core.num num(
    String name,
    core.num defaultValue, {
    core.num? min,
    core.num? max,
  }) {
    var knob = _addKnob(name, () => NumKnob<core.num>(0))
      ..defaultValue = defaultValue
      ..min = min
      ..max = max;

    return knob.requiredValue;
  }

  @override
  core.int int(
    String name,
    core.int defaultValue, {
    core.int? min,
    core.int? max,
  }) {
    var knob = _addKnob(name, () => NumKnob<core.int>(0))
      ..defaultValue = defaultValue
      ..min = min
      ..max = max;

    return knob.requiredValue;
  }

  @override
  core.double double(
    String name,
    core.double defaultValue, {
    core.double? min,
    core.double? max,
  }) {
    var knob = _addKnob(name, () => NumKnob<core.double>(0))
      ..defaultValue = defaultValue
      ..min = min
      ..max = max;

    return knob.requiredValue;
  }

  @override
  core.bool bool(String name, core.bool defaultValue) {
    var knob = _addKnob(name, () => BoolKnob())..defaultValue = defaultValue;
    return knob.requiredValue;
  }

  @override
  T picker<T>(
    String name,
    Map<String, T> options,
    T defaultValue, {
    Color Function(T value)? swatch,
    IconData Function(T value)? icon,
    PickerStyle style = PickerStyle.dropdown,
  }) {
    var knob = _addKnob(name, () => PickerKnob<T>(options: options))
      ..defaultValue = defaultValue
      ..options = options
      ..swatch = swatch
      ..icon = icon
      ..style = style;

    return knob.requiredValue;
  }

  @override
  DateTime? nullableDateTime(
    String name,
    DateTime? defaultValue, {
    core.bool dateOnly = false,
  }) {
    var knob = _addKnob(
      name,
      () => DateTimeKnob(isNullable: true, dateOnly: dateOnly),
    )..defaultValue = defaultValue;
    return knob.requiredValue;
  }

  @override
  DateTime dateTime(
    String name,
    DateTime defaultValue, {
    core.bool dateOnly = false,
  }) {
    var knob = _addKnob(
      name,
      () => DateTimeKnob(isNullable: false, dateOnly: dateOnly),
    )..defaultValue = defaultValue;
    return knob.requiredValue!;
  }

  @override
  void button(String name, String text, VoidCallback onPressed) {
    _addKnob(name, () => ActionButtonKnob(text: text, onPressed: onPressed))
      ..text = text
      ..onPressed = onPressed;
  }

  void dispose() {
    for (var knob in knobs.values) {
      knob.dispose();
    }
  }
}

sealed class Knob<T> with ChangeNotifier {
  Knob(this.defaultValue);

  T defaultValue;

  T? _value;

  T? get value => _value;
  set value(T? value) {
    _value = value;
    notifyListeners();
  }

  T get requiredValue => _value ?? defaultValue;
}

class StringKnob extends Knob<String> {
  StringKnob() : super('');
}

class BoolKnob extends Knob<bool> {
  BoolKnob() : super(false);
}

class NumKnob<T extends num> extends Knob<T> {
  T? min, max;

  NumKnob(super.defaultValue);

  bool get isInt => T == int;
}

class PickerKnob<T> extends Knob<T> {
  Map<String, T> options;
  Color Function(T value)? swatch;
  IconData Function(T value)? icon;
  PickerStyle style;

  PickerKnob({
    required this.options,
    this.swatch,
    this.icon,
    this.style = PickerStyle.dropdown,
  }) : super(options.values.first);

  // Resolved here, inside the class, so the call runs with the reified [T] —
  // calling [swatch]/[icon] through the raw `PickerKnob` type would fail
  // the function cast.
  Color? swatchFor(Object? value) => swatch?.call(value as T);

  IconData? iconFor(Object? value) => icon?.call(value as T);
}

/// Renders a picker option: its [PickerKnob.swatch] colour dot or
/// [PickerKnob.icon] (if set) before the [label]. Shared by the top bar
/// and the knobs panel so a picker looks the same in both.
Widget pickerOptionWidget(PickerKnob knob, String label, Object? value) {
  var swatch = knob.swatchFor(value);
  var icon = knob.iconFor(value);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (swatch != null) ...[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
      ],
      if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 8)],
      Text(label),
    ],
  );
}

class DateTimeKnob extends Knob<DateTime?> {
  final bool isNullable;
  final bool dateOnly;
  DateTimeKnob({required this.isNullable, required this.dateOnly})
    : super(null);
}

class ActionButtonKnob extends Knob {
  String text;
  VoidCallback onPressed;

  ActionButtonKnob({required this.text, required this.onPressed}) : super(null);
}
