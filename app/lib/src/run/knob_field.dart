import 'package:material_ui/material_ui.dart';

import '../plugins/native/run_results.dart';
import '../ui/design/spacing.dart';
import '../ui/design/tokens.dart';
import '../ui/picker.dart';
import '../ui/tappable.dart';

/// One knob: what it is on the left, what it is set to on the right.
///
/// One widget, two hosts — the New run page fills these in before a launch,
/// and the running app's Knobs tab edits the same knobs afterwards. A knob that
/// looked like a text field in one place and a dropdown in the other would be
/// two controls for one value.
///
/// Two columns, because a knob is a name and a value. Stacked full-width
/// they read as an unfinished form: an 810px box holding `10.0.0.49`, and four
/// of them with nothing lining up. The label column is fixed so the controls
/// line up down the pane — the same reason [FieldRow] fixes its own, and the
/// same reason the New run page caps its column at 560.
///
/// The control follows the *signature's* type, never the value's: a `bool`
/// parameter is a switch even when nobody has set it, and an enum is a dropdown
/// of its own constants rather than a field you can misspell into.
///
/// A kind that is not a picker can still have options. `Knob('apiHost',
/// from: ValueSource.hostAddresses)` is a `String` parameter — kind `string`,
/// so a text field — and its whole reason for existing is the list underneath
/// it: this machine's LAN addresses, so "point the app at my dev machine" is a
/// click rather than a trip to `ifconfig`. Chips rather than a dropdown,
/// because unlike an enum's constants these are suggestions and typing
/// something else is allowed.
class KnobField extends StatefulWidget {
  const KnobField({
    super.key,
    required this.knob,
    required this.value,
    required this.onChanged,
    this.interfaceOf,
  });

  final RunKnobEntry knob;

  /// What is set now, or null for "left alone" — which is not the same as
  /// empty, and is why the default is a hint rather than a filled-in value.
  final String? value;

  /// Null clears the override, putting the knob back on whatever the project
  /// works out for it. **Reachable for every kind**: a text field can be
  /// emptied, but a switch and a dropdown have no empty, so without the reset
  /// beside them a picker could be moved off its default and never back.
  final ValueChanged<String?> onChanged;

  /// The interface an offered value was found on — `en0` — when it is one of
  /// this machine's addresses. Five bare IPv4s say nothing about which one the
  /// phone can reach; `en0` next to one of them does.
  final String? Function(String)? interfaceOf;

  /// Wide enough for a parameter name and its kind without wrapping, narrow
  /// enough to leave the control the better half in a 560px column.
  static const labelWidth = 190.0;

  /// A value is a host, a port, a flag. None of them wants 800px, and a row of
  /// boxes that wide stops looking like a list of settings.
  static const controlWidth = 340.0;

  @override
  State<KnobField> createState() => _KnobFieldState();
}

class _KnobFieldState extends State<KnobField> {
  /// Held here rather than left to `initialValue`, because a chip and the reset
  /// both change the value from outside the field and `initialValue` is read
  /// once. Without it a tap updated the form's state and left the box showing
  /// the old value.
  late final _text = TextEditingController(text: widget.value ?? '');

  @override
  void didUpdateWidget(KnobField old) {
    super.didUpdateWidget(old);
    var value = widget.value ?? '';
    if (value != _text.text) _text.text = value;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  RunKnobEntry get _knob => widget.knob;

  /// Whether this knob has been moved off what it would be anyway.
  bool get _set => widget.value != null;

  /// A required knob with nothing set and nothing computed for it — the state
  /// a launch is refused in.
  ///
  /// Reads off [RunKnobEntry.defaultValue] rather than repeating the core's
  /// rule: a required knob is reported *without* the parameter's placeholder
  /// default precisely so that a default here means somebody or something
  /// chose one.
  bool get _unanswered =>
      _knob.required && widget.value == null && _knob.defaultValue == null;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: KnobField.labelWidth,
          child: Padding(
            // Down onto the control's own text baseline, so the name reads as
            // belonging to the box beside it rather than floating above it.
            padding: const EdgeInsets.only(top: FwSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _knob.label ?? _knob.name,
                        style: context.type.bodyStrong.copyWith(
                          // Bright once it has been moved, so what you changed
                          // is legible at a glance against what you did not —
                          // the rule the catalog's knob strip already follows.
                          color: _set ? colors.ink : colors.mut,
                        ),
                      ),
                    ),
                    if (_knob.kind case var kind?) ...[
                      const Gap(FwSpacing.sm),
                      Text(
                        kind,
                        style: context.type.micro.copyWith(color: colors.mut3),
                      ),
                    ],
                    // Amber while it is the thing stopping the launch, and
                    // quiet once something has answered for it — the same
                    // reading the Start button below is doing, said where the
                    // empty field is.
                    if (_knob.required) ...[
                      const Gap(FwSpacing.sm),
                      Text(
                        'required',
                        style: context.type.micro.copyWith(
                          color: _unanswered ? colors.amber : colors.mut3,
                        ),
                      ),
                    ],
                  ],
                ),
                if (_knob.description case var description?) ...[
                  const Gap(FwSpacing.xxs),
                  Text(
                    description,
                    style: context.type.caption.copyWith(color: colors.mut3),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Gap(FwSpacing.lg),
        // `Align` first, then the cap. A `ConstrainedBox` directly under
        // `Expanded` does nothing: `enforce` lets the parent's tight width win,
        // so the field stretched the whole pane and the cap read as applied.
        // Align loosens, the cap then binds, and `stretch` fills what is left.
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: KnobField.controlWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: _control(context)),
                      // Only when there is an override to drop. Always-on it
                      // would be a control that does nothing most of the time.
                      if (_set) ...[
                        const Gap(FwSpacing.sm),
                        Tappable(
                          onTap: () => widget.onChanged(null),
                          child: Padding(
                            padding: const EdgeInsets.all(FwSpacing.xs),
                            child: Text(
                              'Reset',
                              style: context.type.micro.copyWith(
                                color: colors.mut,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_knob.kind != 'picker' &&
                      _knob.kind != 'boolean' &&
                      _knob.options.isNotEmpty) ...[
                    const Gap(FwSpacing.xs),
                    Wrap(
                      spacing: FwSpacing.xs,
                      runSpacing: FwSpacing.xxs,
                      children: [
                        for (var option in _knob.options)
                          _OptionChip(
                            label: option,
                            note: widget.interfaceOf?.call(option),
                            selected: widget.value == option,
                            onTap: () => widget.onChanged(option),
                          ),
                      ],
                    ),
                  ],
                  if (_knob.problem case var problem?) ...[
                    const Gap(FwSpacing.xs),
                    Text(
                      problem,
                      style: context.type.caption.copyWith(color: colors.amber),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _control(BuildContext context) => switch (_knob.kind) {
    'boolean' => Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Toggle(
            value: (widget.value ?? _knob.defaultValue) == 'true',
            onChanged: (on) => widget.onChanged('$on'),
          ),
          const Gap(FwSpacing.sm),
          Text(
            (widget.value ?? _knob.defaultValue) == 'true' ? 'true' : 'false',
            style: context.type.caption.copyWith(color: context.colors.mut),
          ),
        ],
      ),
    ),
    // Only what the enum declares — there is no "other" to type, because
    // there is no other constant to name — and only a value the list actually
    // holds: a script source can compute one for an enum knob that is not
    // among its constants, and the picker shows `Choose…` for it rather than
    // pretending it is.
    'picker' => FwPicker<String>(
      choices: [
        for (var option in _knob.options)
          FwChoice(value: option, label: option),
      ],
      selected: _knob.options.contains(widget.value ?? _knob.defaultValue)
          ? widget.value ?? _knob.defaultValue
          : null,
      onChanged: widget.onChanged,
    ),
    // No kind means there is no parameter to set: a config naming one that is
    // not there, or a `required` one that cannot be a knob at all. Both already
    // carry a [RunKnobEntry.problem] saying so, and a field beside it would be
    // precisely the control-that-does-nothing the problem is complaining about.
    null => const SizedBox.shrink(),
    _ => TextFormField(
      controller: _text,
      // The default is shown rather than filled in, so leaving the field alone
      // and leaving it at its default are the same thing — the rule the define
      // form already followed.
      //
      // Falling back to how the default is *written* when there is no value to
      // show for it. A parameter defaulted to a `const` — which is most of them
      // in a project whose values came from `--dart-define`, since that is what
      // `String.fromEnvironment` is — showed an empty hint, indistinguishable
      // from a parameter with no default at all. `ServerUrls.localPort` is not
      // a value and is not offered as one; it is the line the reader wrote, and
      // it tells them the field is already covered.
      decoration: InputDecoration(
        hintText: _knob.defaultValue ?? _knob.defaultSource,
        isDense: true,
      ),
      keyboardType: switch (_knob.kind) {
        'integer' || 'number' => TextInputType.number,
        _ => TextInputType.text,
      },
      onChanged: (text) => widget.onChanged(text.isEmpty ? null : text),
    ),
  };
}

/// A switch at the weight of the fields around it.
///
/// Material's own is a 52×32 filled pill, which beside a hairline text field is
/// the heaviest thing on the pane and the least important. The anatomy is the
/// catalog knob strip's, copied inline rather than shared — the house rule for
/// a panel borrowing its sibling's look.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Semantics(
      container: true,
      toggled: value,
      // A [Switch] carries these for free; a hand-rolled one has to say so, or
      // the control becomes invisible to everything that is not a pair of eyes.
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          // The visible track is 14 tall; the target is the whole row height,
          // so it can be hit without aiming.
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: SizedBox(
            height: 28,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: 26,
                height: 14,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: value ? colors.accent : colors.bg,
                  border: Border.all(
                    color: value ? colors.accent : colors.line,
                  ),
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: value ? colors.panel : colors.mut,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One offered value, small enough to read as a suggestion.
///
/// The old chip was an `ActionChip` at default size — a rounded box as heavy as
/// the field above it, so four addresses looked like four buttons rather than a
/// list to pick from.
class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// The interface, for an address. Null for anything else.
  final String? note;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.sm,
          vertical: FwSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : colors.panel2,
          borderRadius: BorderRadius.circular(context.radii.pill),
          border: Border.all(color: selected ? colors.accent : colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.type.micro.copyWith(
                color: selected ? colors.accentDark : colors.ink2,
              ),
            ),
            if (note case var interface?) ...[
              const Gap(FwSpacing.xxs),
              Text(
                interface,
                style: context.type.micro.copyWith(color: colors.mut3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
