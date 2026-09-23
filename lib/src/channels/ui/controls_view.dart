/// Knobs and actions: the two halves of a panel you can *do* something with.
///
/// A knob switches on [KnobKind], exactly as the catalog's knob panel does —
/// same vocabulary, same control per kind, so someone who has driven the
/// previews panel already knows this one.
library;

import 'package:material_ui/material_ui.dart';

import '../../plugins/action.dart';
import '../../ui_catalog/knob.dart';
import 'style.dart';

class ControlsView extends StatelessWidget {
  const ControlsView({
    super.key,
    required this.knobs,
    required this.actions,
    this.onKnob,
    this.onAction,
    this.busy = const {},
    this.results = const {},
  });

  final List<KnobDescriptor> knobs;
  final List<PluginAction> actions;
  final void Function(String name, Object? value)? onKnob;
  final void Function(String actionId, Map<String, Object?> args)? onAction;

  /// Action ids currently running.
  final Set<String> busy;

  /// The last thing each action answered — or the error it threw.
  final Map<String, String> results;

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    if (knobs.isEmpty && actions.isEmpty) {
      return PanelSurface(
        child: Center(
          child: Text(
            'This panel offers no controls',
            style: style.body.copyWith(color: style.muted),
          ),
        ),
      );
    }
    return PanelSurface(
      child: ListView(
        padding: const EdgeInsets.all(PanelStyle.lg),
        children: [
          if (knobs.isNotEmpty) ...[
            Text('Values'.toUpperCase(), style: style.micro),
            const PanelGap(PanelStyle.md),
            for (var knob in knobs)
              KnobControl(
                knob: knob,
                onChanged: onKnob == null
                    ? null
                    : (value) => onKnob!(knob.name, value),
              ),
          ],
          if (actions.isNotEmpty) ...[
            if (knobs.isNotEmpty) const PanelGap(PanelStyle.xl),
            Text('Actions'.toUpperCase(), style: style.micro),
            const PanelGap(PanelStyle.md),
            for (var action in actions)
              ActionControl(
                action: action,
                running: busy.contains(action.id),
                result: results[action.id],
                onRun: onAction == null
                    ? null
                    : (args) => onAction!(action.id, args),
              ),
          ],
        ],
      ),
    );
  }
}

/// One knob, as the control its [KnobKind] calls for.
class KnobControl extends StatelessWidget {
  const KnobControl({super.key, required this.knob, this.onChanged});

  final KnobDescriptor knob;
  final ValueChanged<Object?>? onChanged;

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PanelStyle.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(knob.name, style: style.bodyStrong)),
              // Which knobs somebody has touched is the first question anyone
              // asks of a screen full of them.
              if (!knob.isDefault)
                _Pill(label: 'overridden', color: style.accent, style: style),
            ],
          ),
          if (knob.description != null) ...[
            const PanelGap(PanelStyle.xxs),
            Text(knob.description!, style: style.caption),
          ],
          const PanelGap(PanelStyle.sm),
          _control(context, style),
        ],
      ),
    );
  }

  Widget _control(BuildContext context, PanelStyle style) {
    switch (knob.kind) {
      case KnobKind.boolean:
        return Row(
          children: [
            Switch(value: knob.value == true, onChanged: onChanged),
            const PanelGap(PanelStyle.md),
            Text(knob.value == true ? 'on' : 'off', style: style.caption),
          ],
        );
      case KnobKind.picker:
        return DropdownButtonFormField<String>(
          initialValue: knob.options.contains(knob.value)
              ? knob.value! as String
              : null,
          isDense: true,
          decoration: _fieldDecoration(style),
          items: [
            for (var option in knob.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: onChanged == null ? null : (v) => onChanged!(v),
        );
      case KnobKind.integer:
      case KnobKind.number:
        var isInt = knob.kind == KnobKind.integer;
        // Bounded is a slider, unbounded is a field — the rule
        // `KnobDescriptor` already documents, kept identical here.
        if (knob.min != null && knob.max != null) {
          var min = knob.min!.toDouble();
          var max = knob.max!.toDouble();
          var current = (knob.value is num ? knob.value! as num : min)
              .toDouble()
              .clamp(min, max);
          var step = knob.step?.toDouble();
          return Row(
            children: [
              Expanded(
                child: Slider(
                  value: current,
                  min: min,
                  max: max,
                  divisions: step != null && step > 0
                      ? ((max - min) / step).round().clamp(1, 1000)
                      : null,
                  onChanged: onChanged == null
                      ? null
                      : (v) => onChanged!(isInt ? v.round() : v),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  isInt ? '${current.round()}' : current.toStringAsFixed(2),
                  style: style.mono,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          );
        }
        return _TextControl(
          initial: '${knob.value ?? ''}',
          style: style,
          keyboard: TextInputType.number,
          onSubmit: onChanged == null
              ? null
              : (text) {
                  var parsed = isInt
                      ? int.tryParse(text)
                      : double.tryParse(text);
                  if (parsed != null) onChanged!(parsed);
                },
        );
      case KnobKind.string:
        return _TextControl(
          initial: '${knob.value ?? ''}',
          style: style,
          onSubmit: onChanged,
        );
    }
  }
}

/// One action: a button, or a form and a button when it takes parameters.
class ActionControl extends StatefulWidget {
  const ActionControl({
    super.key,
    required this.action,
    this.onRun,
    this.running = false,
    this.result,
  });

  final PluginAction action;
  final void Function(Map<String, Object?> args)? onRun;
  final bool running;
  final String? result;

  @override
  State<ActionControl> createState() => _ActionControlState();
}

class _ActionControlState extends State<ActionControl> {
  // Allocated once, not in build: a rebuild while somebody is typing must not
  // reset the field under them.
  late final Map<String, TextEditingController> _text = {
    for (var parameter in widget.action.parameters)
      if (parameter.kind != ActionParameterKind.boolean)
        parameter.id: TextEditingController(text: parameter.defaultValue ?? ''),
  };
  late final Map<String, Object?> _values = {
    for (var parameter in widget.action.parameters)
      if (parameter.kind == ActionParameterKind.boolean)
        parameter.id: parameter.defaultValue == 'true',
  };

  @override
  void dispose() {
    for (var controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _ready => widget.action.parameters
      .where((p) => p.required && p.kind != ActionParameterKind.boolean)
      .every((p) => (_text[p.id]?.text ?? '').isNotEmpty);

  Map<String, Object?> _args() => {
    for (var parameter in widget.action.parameters)
      parameter.id: switch (parameter.kind) {
        ActionParameterKind.boolean => _values[parameter.id],
        ActionParameterKind.integer =>
          int.tryParse(_text[parameter.id]!.text) ?? 0,
        _ => _text[parameter.id]!.text,
      },
  };

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    var action = widget.action;
    return Container(
      margin: const EdgeInsets.only(bottom: PanelStyle.lg),
      padding: const EdgeInsets.all(PanelStyle.lg),
      decoration: BoxDecoration(
        color: style.raised,
        borderRadius: BorderRadius.circular(PanelStyle.radius),
        border: Border.all(
          color: action.danger ? style.bad.withValues(alpha: 0.4) : style.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(action.label, style: style.bodyStrong)),
              if (action.danger)
                _Pill(label: 'danger', color: style.bad, style: style),
            ],
          ),
          if (action.description != null) ...[
            const PanelGap(PanelStyle.xxs),
            Text(action.description!, style: style.caption),
          ],
          for (var parameter in action.parameters) ...[
            const PanelGap(PanelStyle.md),
            _Parameter(
              parameter: parameter,
              controller: _text[parameter.id],
              value: _values[parameter.id],
              onBool: (v) => setState(() => _values[parameter.id] = v),
              onText: () => setState(() {}),
              style: style,
            ),
          ],
          const PanelGap(PanelStyle.md),
          Row(
            children: [
              FilledButton(
                onPressed: widget.onRun == null || widget.running || !_ready
                    ? null
                    : () => widget.onRun!(_args()),
                style: action.danger
                    ? FilledButton.styleFrom(backgroundColor: style.bad)
                    : null,
                child: widget.running
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(action.confirm ? '${action.label}…' : action.label),
              ),
              if (widget.result != null) ...[
                const PanelGap(PanelStyle.lg),
                Expanded(
                  child: Text(
                    widget.result!,
                    style: style.mono.copyWith(color: style.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Parameter extends StatelessWidget {
  const _Parameter({
    required this.parameter,
    required this.controller,
    required this.value,
    required this.onBool,
    required this.onText,
    required this.style,
  });

  final ActionParameter parameter;
  final TextEditingController? controller;
  final Object? value;
  final ValueChanged<bool> onBool;
  final VoidCallback onText;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    var label = parameter.required
        ? parameter.label
        : '${parameter.label} (optional)';
    switch (parameter.kind) {
      case ActionParameterKind.boolean:
        return Row(
          children: [
            Checkbox(
              value: value == true,
              onChanged: (v) => onBool(v ?? false),
            ),
            const PanelGap(PanelStyle.xs),
            Text(label, style: style.body),
          ],
        );
      case ActionParameterKind.choice:
        return DropdownButtonFormField<String>(
          initialValue: parameter.defaultValue,
          isDense: true,
          decoration: _fieldDecoration(style).copyWith(labelText: label),
          items: [
            for (var option in parameter.options)
              DropdownMenuItem(
                value: option.value,
                child: Text(option.label ?? option.value),
              ),
          ],
          onChanged: (v) {
            controller?.text = v ?? '';
            onText();
          },
        );
      case ActionParameterKind.string:
      case ActionParameterKind.integer:
        return TextField(
          controller: controller,
          onChanged: (_) => onText(),
          keyboardType: parameter.kind == ActionParameterKind.integer
              ? TextInputType.number
              : null,
          style: style.body,
          decoration: _fieldDecoration(style)
              .copyWith(labelText: label, helperText: parameter.description),
        );
    }
  }
}

class _TextControl extends StatefulWidget {
  const _TextControl({
    required this.initial,
    required this.style,
    required this.onSubmit,
    this.keyboard,
  });

  final String initial;
  final PanelStyle style;
  final ValueChanged<String>? onSubmit;
  final TextInputType? keyboard;

  @override
  State<_TextControl> createState() => _TextControlState();
}

class _TextControlState extends State<_TextControl> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: widget.onSubmit != null,
      keyboardType: widget.keyboard,
      style: widget.style.body,
      // Committed on submit or on losing focus, never per keystroke: each
      // change is a round trip into the app.
      onSubmitted: widget.onSubmit,
      onTapOutside: (_) {
        FocusScope.of(context).unfocus();
        if (_controller.text != widget.initial) {
          widget.onSubmit?.call(_controller.text);
        }
      },
      decoration: _fieldDecoration(widget.style),
    );
  }
}

InputDecoration _fieldDecoration(PanelStyle style) => InputDecoration(
  isDense: true,
  contentPadding: const EdgeInsets.symmetric(
    horizontal: PanelStyle.md,
    vertical: PanelStyle.md,
  ),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(PanelStyle.radiusSmall),
  ),
  labelStyle: style.caption,
  helperStyle: style.micro,
);

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, required this.style});

  final String label;
  final Color color;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PanelStyle.sm,
        vertical: PanelStyle.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: style.micro.copyWith(color: color)),
    );
  }
}
