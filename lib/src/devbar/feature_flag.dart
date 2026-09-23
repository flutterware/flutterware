import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'devbar.dart';
import 'plugins/variables/plugin.dart';

class FeatureFlag<T> {
  final DevbarVariableDefinition<T> _definition;

  FeatureFlag(String name, T defaultValue, {String? description})
    : _definition = DevbarVariableDefinition<T>(
        name,
        defaultValue: defaultValue,
        description: description,
      ),
      assert(T != dynamic && T != Null);

  FeatureFlag._(this._definition) : assert(T != dynamic && T != Null);

  static FeatureFlag<T> picker<T>(
    String name,
    T defaultValue, {
    String? description,
    required Map<T, String> options,
    T? Function(Object)? fromJson,
  }) {
    return FeatureFlag<T>._(
      DevbarPickerVariableDefinition<T>(
        name,
        description: description,
        options: options,
        fromJson: fromJson,
        defaultValue: defaultValue,
      ),
    );
  }

  static FeatureFlag<T> slider<T extends num>(
    String name,
    T defaultValue, {
    required T min,
    required T max,
    required T step,
    String? description,
  }) {
    return FeatureFlag<T>._(
      DevbarSliderVariableDefinition<T>(
        name,
        description: description,
        min: min,
        max: max,
        step: step,
        defaultValue: defaultValue,
      ),
    );
  }

  String get name => _definition.key;
  String? get description => _definition.description;
  T get _defaultValue => _definition.defaultValue;

  DevbarVariable<T> _addVariable(
    VariablesPlugin service,
    FeatureFlagValue<T>? value,
  ) => service.add<T>(_definition, flagValue: value);

  FeatureFlagValue<T> withValue(T newValue) =>
      FeatureFlagValue<T>(this, newValue);

  FeatureFlagValue<T> get withDefaultValue => withValue(_defaultValue);

  T dependsOnValue(BuildContext context) {
    var holder = context.dependOnInheritedWidgetOfExactType<FeatureFlags>();
    if (holder != null) {
      var flagValue = holder.find(this);
      if (flagValue != null) {
        return flagValue.value;
      }
    }
    return _defaultValue;
  }

  T findValue(BuildContext context) {
    var holder = context.findAncestorWidgetOfExactType<FeatureFlags>();
    if (holder != null) {
      var flagValue = holder.find(this);
      if (flagValue != null) {
        return flagValue.value;
      }
    }
    return _defaultValue;
  }

  @override
  String toString() => 'FeatureFlag<$T>($name, value: $_defaultValue)';
}

class FeatureFlagValue<T> {
  final FeatureFlag flag;
  final T value;

  FeatureFlagValue(this.flag, this.value);

  @override
  String toString() => 'FeatureFlagValue<$T>(${flag.name}, value: $value)';
}

class FeatureFlags extends InheritedWidget {
  final Map<FeatureFlag, FeatureFlagValue> values;

  FeatureFlags._({required super.child, required this.values});

  static Widget merge({
    required Widget child,
    required List<FeatureFlagValue> flags,
  }) {
    return Builder(
      builder: (context) {
        var parent = context.dependOnInheritedWidgetOfExactType<FeatureFlags>();
        return FeatureFlags._(
          values: {
            if (parent != null) ...parent.values,
            for (var flag in flags) flag.flag: flag,
          },
          child: child,
        );
      },
    );
  }

  FeatureFlagValue<T>? find<T>(FeatureFlag<T> flag) {
    return values[flag] as FeatureFlagValue<T>?;
  }

  @override
  bool updateShouldNotify(covariant FeatureFlags oldWidget) {
    return true;
  }
}

class FeatureFlagDevbar extends StatelessWidget {
  final Widget child;

  const FeatureFlagDevbar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    var devbar = context.findAncestorWidgetOfExactType<Devbar>()!;
    return FeatureFlags.merge(
      child: _FlagToVariable(child: child),
      flags: devbar.flags,
    );
  }
}

class _FlagToVariable extends StatefulWidget {
  final Widget child;

  const _FlagToVariable({required this.child});

  @override
  _FlagToVariableState createState() => _FlagToVariableState();
}

class _FlagToVariableState extends State<_FlagToVariable> {
  final _flagValues = <FeatureFlag, FlagRegistration>{};
  late DevbarState _devbar;

  @override
  void initState() {
    super.initState();
    _devbar = DevbarState.of(context);
  }

  @override
  Widget build(BuildContext context) {
    var parentFlags = context
        .dependOnInheritedWidgetOfExactType<FeatureFlags>()!;

    var alreadyRegistered = {..._flagValues};
    for (var flag in parentFlags.values.values) {
      _register(flag);
      alreadyRegistered.remove(flag.flag);
    }
    for (var oldVariable in alreadyRegistered.values) {
      _unregister(oldVariable);
    }

    return FeatureFlags.merge(
      flags: _flagValues.values.map((v) => v.value).toList(),
      child: widget.child,
    );
  }

  void _register(FeatureFlagValue flagValue) {
    var flag = flagValue.flag;

    if (_flagValues.containsKey(flag)) {
      return;
    }

    // A devbar without the variables plugin still carries its flags — they
    // simply cannot be edited. This used to reach `plugin<VariablesPlugin>()`
    // unconditionally and throw `Bad state: No element`, which made passing
    // `flags:` a trap for any app that had not also installed that plugin.
    var service = _devbar.maybePlugin<VariablesPlugin>();
    if (service == null) {
      _flagValues[flag] = FlagRegistration(flagValue);
      return;
    }

    var variable = flag._addVariable(service, flagValue);

    flagValue = flag.withValue(variable.currentValue);

    // ignore: cancel_subscriptions
    var variableSubscription = variable.value.listen((newValue) {
      setState(() {
        _flagValues[flag]!.value = flag.withValue(newValue);
      });
    });

    _flagValues[flag] = FlagRegistration(
      flagValue,
      variable: variable,
      variableSubscription: variableSubscription,
    );
  }

  void _unregister(FlagRegistration registration) {
    var variable = registration.variable;
    if (variable != null) {
      _devbar.variables.remove(variable);
    }
    var variableSubscription = registration.variableSubscription;
    if (variableSubscription != null) {
      variableSubscription.cancel();
    }
  }

  @override
  void dispose() {
    for (var variable in _flagValues.values) {
      _unregister(variable);
    }
    super.dispose();
  }
}

class FlagRegistration {
  final DevbarVariable? variable;
  final StreamSubscription? variableSubscription;
  FeatureFlagValue value;

  FlagRegistration(this.value, {this.variable, this.variableSubscription});
}
