import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/devbar.dart';

import '../../../channels/panels.dart';
import '../../../utils/value_stream.dart';
import 'file_store.dart';
import 'knobs.dart';
import 'store.dart';
import 'ui.dart';

/// A plugin for the Devbar to manage variables.
///
/// Descriptor mode as well as widget: it keeps its own tab in the overlay
/// *and* mirrors every variable to the host as a knob, because a feature flag
/// is a variable and turning one on from the cockpit is what the bridge is
/// for. See `docs/superpowers/specs/2026-08-11-devbar-run-bridge-design.md`
/// § Decision 4.
class VariablesPlugin implements DevbarPlugin, DevbarPanelSource {
  final DevbarState devbar;
  final _variables = ValueStream<List<DevbarVariable>>([]);
  final Map<String, dynamic> overrides;
  final VariablesStore store;

  VariablesPlugin._(
    this.devbar, {
    Map<String, dynamic>? overrides,
    VariablesStore? store,
    this.title,
  }) : overrides = overrides ?? {},
       store = store ?? InMemoryVariablesStore() {
    devbar.ui.addTab(Tab(text: panelLabel), VariablesPanel(this));
  }

  /// Kept, not just consumed: [panelLabel] names the cockpit's tab with the
  /// same word the overlay's tab uses.
  final String? title;

  static Future<VariablesPlugin> Function(DevbarState) init({
    Map<String, dynamic>? values,
    VariablesStore? store,
    Future<VariablesStore> Function()? storeFactory,
    FutureOr<String> Function()? filePath,
    String? title,
  }) {
    return (devbar) async {
      if (store == null) {
        if (storeFactory != null) {
          store = await storeFactory();
        } else if (filePath != null) {
          store = await FileVariableStore.load(File(await filePath()));
        }
      }
      return VariablesPlugin._(
        devbar,
        overrides: values,
        store: store,
        title: title,
      );
    };
  }

  DevbarVariable<bool> checkbox(
    String key, {
    String? description,
    bool defaultValue = false,
  }) {
    return add(
      DevbarVariableDefinition<bool>(
        key,
        defaultValue: defaultValue,
        description: description,
      ),
    );
  }

  DevbarVariable<String> text(
    String key, {
    String? description,
    String defaultValue = '',
  }) {
    return add(
      DevbarVariableDefinition(
        key,
        defaultValue: defaultValue,
        description: description,
      ),
    );
  }

  DevbarVariable<T> slider<T extends num>(
    String key, {
    String? description,
    required T defaultValue,
    required T min,
    required T max,
    required T step,
  }) {
    return add(
      DevbarSliderVariableDefinition<T>(
        key,
        defaultValue: defaultValue,
        description: description,
        min: min,
        max: max,
        step: step,
      ),
    );
  }

  DevbarVariable<T> picker<T>(
    String key, {
    String? description,
    required T defaultValue,
    required Map<T, String> options,
    T? Function(Object)? fromJson,
  }) {
    return add(
      DevbarPickerVariableDefinition<T>(
        key,
        defaultValue: defaultValue,
        description: description,
        fromJson: fromJson,
        options: options,
      ),
    );
  }

  DevbarVariable<T> add<T>(
    DevbarVariableDefinition<T> definition, {
    FeatureFlagValue<T>? flagValue,
  }) {
    var variable = DevbarVariable<T>(this, definition, flagValue: flagValue);
    _variables.add([..._variables.value, variable]);
    return variable;
  }

  void addVariable<T>(DevbarVariable<T> variable) {
    _variables.add([..._variables.value, variable]);
  }

  void remove(DevbarVariable variable) {
    variable._value.dispose();
    _variables.add(_variables.value.whereNot((s) => s == variable).toList());
  }

  Stream<List<DevbarVariable>> get variables => _variables.stream;
  List<DevbarVariable> get currentVariables => _variables.value;

  @override
  String get panelId => 'flags';

  @override
  String get panelLabel => title ?? 'Settings';

  Panel? _panel;

  /// The knobs currently declared, and the subscription watching each one's
  /// value.
  final _mirrored = <String, StreamSubscription<Object?>>{};

  @override
  void describePanel(Panel panel) {
    _panel = panel;
    panel.action(presetAction, _preset);
    _mirror();
    // The set is not fixed: a variable appears when the widget declaring it
    // builds and goes when that widget unmounts, so the panel has to follow
    // rather than snapshot.
    _variablesSubscription = _variables.stream.listen((_) => _mirror());
  }

  StreamSubscription<List<DevbarVariable>>? _variablesSubscription;

  void _mirror() {
    var panel = _panel;
    if (panel == null) return;
    var live = <String, DevbarVariable>{
      for (var variable in _variables.value) variable.key: variable,
    };

    for (var gone in _mirrored.keys.toList()) {
      if (live.containsKey(gone)) continue;
      unawaited(_mirrored.remove(gone)!.cancel());
      panel.removeKnob(gone);
    }

    for (var entry in live.entries) {
      if (_mirrored.containsKey(entry.key)) continue;
      var variable = entry.value;
      var described = describeVariable(variable);
      if (described == null) continue;
      panel.knob(
        described,
        read: () => describeVariable(variable)?.value,
        write: (value) => writeVariable(variable, value),
      );
      // A value can move without the set moving — the app changing its own
      // flag, or another attacher setting it. Announcing lets the host re-read
      // rather than show what it last happened to fetch.
      _mirrored[entry.key] = variable.value.listen((_) => panel.announce());
    }
  }

  /// Names a value for a key whether or not anything has declared it yet.
  Map<String, Object?> _preset(Map<String, Object?> args) {
    var name = args['name'];
    if (name is! String || name.isEmpty) {
      throw ArgumentError('preset needs a `name`');
    }
    overrides[name] = args['value'];
    // Anything already declared under that key re-computes now; anything
    // declared later picks it up on the way in.
    for (var variable in _variables.value) {
      if (variable.key == name) variable._update();
    }
    _panel?.announce();
    return {'preset': name, 'declared': live(name)};
  }

  /// Whether anything has declared [name] in this run.
  bool live(String name) =>
      _variables.value.any((variable) => variable.key == name);

  void _storeValue(DevbarVariable devbarVariable, Object? editorValue) {
    store[devbarVariable.definition.key] = editorValue;
  }

  @override
  void dispose() {
    unawaited(_variablesSubscription?.cancel());
    for (var subscription in _mirrored.values) {
      unawaited(subscription.cancel());
    }
    _mirrored.clear();
    for (var variable in _variables.value) {
      variable._value.dispose();
    }
    _variables.dispose();
  }
}

class DevbarVariable<T> {
  final VariablesPlugin service;
  late final ValueStream<T> _value;
  final DevbarVariableDefinition<T> definition;
  final FeatureFlagValue<T>? flagValue;

  DevbarVariable(this.service, this.definition, {required this.flagValue}) {
    assert(T != dynamic);
    _value = ValueStream<T>(_computedValue);
  }

  String get key => definition.key;

  String? get description => definition.description;

  T get defaultValue => definition.defaultValue;

  T? get storeValue {
    var value = service.store[definition.key];
    if (value is T) {
      return value;
    } else if (definition.fromJson case var fromJson? when value != null) {
      try {
        return fromJson(value);
      } catch (e) {
        print('Fail to read value for ${definition.key}: $e');
        return null;
      }
    }
    return null;
  }

  set storeValue(T? value) {
    service._storeValue(this, value);
    _update();
  }

  T? get overrideValue {
    var value = service.overrides[definition.key];
    if (value == null) return null;
    if (value is! T) {
      throw Exception(
        'Devbar initial value for ${definition.key} is not of type $T',
      );
    }
    return value;
  }

  T get _computedValue =>
      storeValue ??
      overrideValue ??
      flagValue?.value ??
      definition.defaultValue;

  void _update() {
    var computed = _computedValue;

    if (computed != _value.value) {
      _value.add(computed);
    }
  }

  void remove() {
    service.remove(this);
  }

  Stream<T> get value => _value.stream;

  T get currentValue => _value.value;

  static DevbarVariableDefinition<T> picker<T>(
    String key, {
    String? description,
    required T defaultValue,
    required Map<T, String> options,
    T? Function(Object)? fromJson,
  }) {
    return DevbarPickerVariableDefinition<T>(
      key,
      defaultValue: defaultValue,
      description: description,
      options: options,
    );
  }

  static DevbarVariableDefinition<String> text(
    String key, {
    String? description,
    String defaultValue = '',
  }) {
    return DevbarVariableDefinition<String>(
      key,
      defaultValue: defaultValue,
      description: description,
    );
  }

  static DevbarVariableDefinition<bool> checkbox(
    String key, {
    String? description,
    bool defaultValue = false,
  }) {
    return DevbarVariableDefinition<bool>(
      key,
      defaultValue: defaultValue,
      description: description,
    );
  }

  static DevbarVariableDefinition<T> slider<T extends num>(
    String key, {
    String? description,
    required T defaultValue,
    required T min,
    required T max,
    required T step,
  }) {
    return DevbarSliderVariableDefinition<T>(
      key,
      defaultValue: defaultValue,
      description: description,
      min: min,
      max: max,
      step: step,
    );
  }
}

class DevbarVariableDefinition<T> {
  final String key;
  final String? description;
  final T defaultValue;
  final T? Function(Object)? fromJson;

  DevbarVariableDefinition(
    this.key, {
    required this.description,
    required this.defaultValue,
    this.fromJson,
  });

  DevbarVariable<T> addVariable(VariablesPlugin plugin) => plugin.add<T>(this);
}

class DevbarSliderVariableDefinition<T extends num>
    extends DevbarVariableDefinition<T> {
  final T min;
  final T max;
  final T step;

  DevbarSliderVariableDefinition(
    super.key, {
    required super.defaultValue,
    required super.description,
    super.fromJson,
    required this.min,
    required this.max,
    required this.step,
  });

  bool get isInt => T == int;
}

class DevbarPickerVariableDefinition<T> extends DevbarVariableDefinition<T> {
  final Map<T, String> options;

  DevbarPickerVariableDefinition(
    super.key, {
    required super.defaultValue,
    required super.description,
    super.fromJson,
    required this.options,
  });
}

extension VariablesPluginDevbarExtension on DevbarState {
  VariablesPlugin get variables => plugin<VariablesPlugin>();
}
