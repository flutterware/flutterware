import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';
import '../ui/popover.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'device/device_settings.dart';

/// The device's live state, over the picture it changes.
///
/// A View in the house sense: it takes a list of [DeviceSetting] and two
/// callbacks and reads nothing of its own. The host that owns the
/// [DeviceSettings] backend does the reads and the writes and hands the answers
/// down — which is what makes every state below renderable in the catalog
/// without a device anywhere.
///
/// Drawn as a strip over the Screen pane rather than as a seventh tab, and the
/// reason is the second dev-stack study's finding 12: a tab strip is exclusive,
/// so opening *Device* would close *Screen* and put a control on one page whose
/// only visible result is on another. Designed in
/// `docs/superpowers/specs/2026-08-24-run-device-strip-design.md`; the
/// capability table it draws is
/// `2026-08-24-run-device-tab-capability-findings.md`.
class DeviceStrip extends StatelessWidget {
  const DeviceStrip({
    super.key,
    required this.settings,
    this.onSet,
    this.busy = const {},
    this.reading = false,
    this.notice,
    this.enabled = true,
  });

  /// Every setting the target reports, refusals included. Empty for a target
  /// with no backend at all, where [notice] is the whole of what the strip has
  /// to say.
  final List<DeviceSetting> settings;

  /// Writes one setting. Null while there is nobody to write to — a run that
  /// has died, or a target this build cannot reach.
  final void Function(DeviceSettingId id, String value)? onSet;

  /// Writes in flight. Their chips stay on their previous value and stop
  /// responding, because the only honest thing to draw between a write and its
  /// re-read is what the device last said.
  final Set<DeviceSettingId> busy;

  /// A read is in flight. The values already on screen are drawn muted rather
  /// than replaced by a spinner: they were true a moment ago, and a spinner in
  /// a chip's slot makes the bar's furniture move every time it refreshes.
  final bool reading;

  /// One sentence under the bar, when the strip has something to say that no
  /// single chip can hold — a target with no backend, or an explanation of the
  /// refusals. A [DeviceSettingState.notObserved] row supplies its own; this is
  /// for what the *strip* knows and a setting does not.
  final String? notice;

  /// False while the run cannot be written to. The chips stay visible and stop
  /// responding — hiding them would move the page's furniture around every time
  /// a build started, which is the rule the view tabs above already follow.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var chips = deviceChips(settings);
    // The strip's own news, and a setting's, in one slot. A `notObserved` row
    // is the case the slot exists for: the device confirms a value the app does
    // not carry, which is permanent rather than pending and cannot be said by a
    // chip 90 pixels wide.
    var unobserved = settings
        .where((s) => s.state == DeviceSettingState.notObserved)
        .firstOrNull;
    var line = unobserved == null
        ? notice
        : '${_nameOf(unobserved.id)} is set on the device and the app does not '
              'carry it.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // No chips and nothing on the way is a target with no backend —
        // macOS today. The bar is not drawn empty there: a 36-pixel band with
        // no control in it is furniture claiming to be one, and the [_Notice]
        // under it already names the mechanism that would work. Drawn while the
        // first read is in flight, so the ordinary case fills a bar that is
        // already there rather than pushing the picture down a second later.
        if (chips.isNotEmpty || reading)
          Container(
            height: 36,
            color: colors.panel,
            // Scrolling, like the previews top bar this is modelled on, and
            // for the same reason: a bar one row tall whose contents are not
            // its author's to count. It folded into a `+3` control for three
            // rounds instead, on the argument that what is off the end of this
            // bar is the device's own state rather than another axis to pick —
            // which does not survive being drawn, because a fold hides it just
            // as thoroughly and invents a control to do it with. Novel where
            // the app already had an answer, and the novelty was the cost:
            // every one of that control's three bugs was somebody asking what
            // it was for.
            //
            // The padding rides inside the scroll view so the last chip clears
            // the edge instead of being clipped against it.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
              child: Row(
                spacing: FwSpacing.sm,
                children: [
                  for (var chip in chips)
                    _Chip(
                      chip: chip,
                      reading: reading,
                      busy: chip.settings.any((s) => busy.contains(s.id)),
                      onSet: enabled ? onSet : null,
                    ),
                ],
              ),
            ),
          ),
        if (line case var text?) _Notice(text: text, amber: unobserved != null),
        Divider(height: 1, color: colors.line),
      ],
    );
  }
}

// ── the derivation ───────────────────────────────────────────────────────────

/// One control on the bar, over the settings behind it.
///
/// Five chips over eight settings: the four accessibility flags share a chip,
/// because they are off on a real phone and are each other's neighbours — the
/// same grouping `ScenarioAxes.anyAccessibility` already makes. The grouping key
/// is [DeviceSetting.noun], which the backends already assign, so a backend that
/// adds a setting decides for itself whether it is a chip or a flag.
class DeviceChip {
  DeviceChip({
    required this.noun,
    required this.name,
    required this.value,
    required this.state,
    required this.atDefault,
    required this.settings,
    this.scope,
  });

  /// The muted qualifier — `Theme`, `Text`, `Turn`, `Lang`, `A11y`. Drawn
  /// because the mockup settled it: `large`, `off` and `2 on` are unreadable
  /// alone, and no 12px glyph supplies the missing noun.
  final String noun;

  /// The full name, for the tooltip and the picker's title.
  final String name;

  /// What the chip shows. `—` for a value nothing answered with, which is not
  /// the same as a default.
  final String value;

  final DeviceSettingState state;

  /// Every setting behind it is on the platform's own default, so the chip
  /// draws quiet. A strip where nothing has been touched should read as
  /// untouched, which is what makes one that has read as loud with no colour
  /// added anywhere.
  final bool atDefault;

  /// `per-app` where the mechanism is scoped to the app under test — the
  /// difference between changing your run and changing the developer's phone.
  final String? scope;

  /// One, or the flags sharing a noun. Never empty.
  final List<DeviceSetting> settings;

  /// A chip over several settings is a group of flags, and its picker draws a
  /// row each rather than a list of values.
  bool get isGroup => settings.length > 1;
}

/// The chips [settings] amounts to, in the order the backend reported them.
///
/// Pure, so the strip's rendering and the demo's cases derive identically and
/// the count in the chip cannot disagree with the picker under it — the fifth
/// entry in the design's list of where the bugs would come from.
List<DeviceChip> deviceChips(List<DeviceSetting> settings) {
  var byNoun = <String, List<DeviceSetting>>{};
  for (var setting in settings) {
    byNoun.putIfAbsent(setting.noun, () => []).add(setting);
  }
  return [for (var entry in byNoun.entries) _chipOver(entry.key, entry.value)];
}

DeviceChip _chipOver(String noun, List<DeviceSetting> settings) {
  var reachable = settings
      .where((s) => s.state != DeviceSettingState.unavailable)
      .toList();
  var group = settings.length > 1;
  return DeviceChip(
    noun: noun,
    name: group ? 'Accessibility' : _nameOf(settings.single.id),
    value: switch (reachable) {
      // Every flag refused on this target, or the one setting unavailable:
      // a dash, and the picker carries the reason. A refusal is a row and not
      // an absence — its absence would read as an oversight.
      [] => '—',
      // A group is flags, and what is worth reading at a glance is how many are
      // on. A count of *on*, never of observed: the mockup's `1 of 2 seen`
      // conflated the two, and a flag refused on this target is not counted at
      // all — it is listed in the picker with its reason.
      [_, _, ...] => switch (reachable.where((s) => s.value == 'on').length) {
        0 => 'off',
        var on => '$on on',
      },
      [var only] => only.display ?? only.value ?? '—',
    },
    state: switch (reachable) {
      [] => DeviceSettingState.unavailable,
      _ when reachable.any((s) => s.state == DeviceSettingState.notObserved) =>
        DeviceSettingState.notObserved,
      _ when reachable.any((s) => s.state == DeviceSettingState.asked) =>
        DeviceSettingState.asked,
      _ => DeviceSettingState.set,
    },
    // A value nothing answered with is not a default, so a group with an
    // unknown flag in it is not quiet either.
    atDefault: reachable.isNotEmpty && reachable.every((s) => s.atDefault),
    scope: reachable.any((s) => s.scope == DeviceScope.app) ? 'per-app' : null,
    settings: settings,
  );
}

/// The long name a picker's title and a tooltip use.
///
/// Wording rather than model, which is why it is here and not on
/// [DeviceSetting]: the backends already carry the four-letter noun the bar
/// needs, and the spelled-out version is a decision about English.
String _nameOf(DeviceSettingId id) => switch (id) {
  DeviceSettingId.brightness => 'Appearance',
  DeviceSettingId.textScale => 'Text size',
  DeviceSettingId.orientation => 'Rotation',
  DeviceSettingId.language => 'Locale',
  DeviceSettingId.boldText => 'Bold text',
  DeviceSettingId.highContrast => 'High contrast',
  DeviceSettingId.invertColors => 'Invert colours',
  DeviceSettingId.disableAnimations => 'Reduce motion',
};

/// The constants a chip is drawn with.
///
/// All that is left of a `DeviceChipMetrics` that also *measured* one: a
/// [TextPainter] over the same styles, so a fold could decide how many fitted.
/// The bar scrolls now, so nothing needs to know a chip's width before it is
/// laid out — see [DeviceStrip.build].
class DeviceChipMetrics {
  DeviceChipMetrics._();

  /// Horizontal padding inside a chip, per side.
  static const chipPadding = FwSpacing.sm;

  /// The border a chip paints once its value has departed from the default.
  static const chipBorder = 1.0;

  /// Between a chip's own parts.
  static const innerGap = FwSpacing.xs;

  static const caretSize = 12.0;
  static const flagSize = 11.0;
  static const dotSize = 6.0;
}

// ── the bar's parts ──────────────────────────────────────────────────────────

/// One control. A noun, a value and a caret — everything else about its state
/// is carried by weight and tint, so the anatomy never moves between states.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.chip,
    required this.reading,
    required this.busy,
    required this.onSet,
  });

  final DeviceChip chip;
  final bool reading;
  final bool busy;
  final void Function(DeviceSettingId id, String value)? onSet;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var unavailable = chip.state == DeviceSettingState.unavailable;
    var unobserved = chip.state == DeviceSettingState.notObserved;
    // A value being re-read is drawn as a value that has not been touched: it
    // was true a moment ago, and the alternative is a bar that dims every time
    // somebody presses refresh.
    var quiet = chip.atDefault || unavailable || reading || busy;

    var ink = switch (chip.state) {
      DeviceSettingState.unavailable => colors.mut3,
      _ when quiet => colors.mut,
      _ => colors.ink,
    };

    return Popover(
      side: PopoverSide.bottom,
      content: (context, controller) => DeviceSheet(
        children: [
          DevicePicker(chip: chip, onSet: onSet, onDone: controller.close),
        ],
      ),
      // **The tip is inside the tappable, not around it**, and both halves of
      // that are deliberate. [_HoverTip] rather than a bare [Tooltip], because
      // a chip is a region that *appears* under a stationary pointer — the bar
      // is drawn empty while the first read is in flight and the chips arrive
      // half a second later — and [Tooltip] opens on the synthetic enter that
      // follows. Inside rather than around, because arming re-parents whatever
      // is directly below it, and a [Tappable] that loses its state mid-press
      // loses the press with it.
      anchor: (context, controller) => Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: _HoverTip(
          message: unavailable
              ? '${chip.name} — no mechanism on this target'
              : '${chip.name}: ${chip.value}',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(
              horizontal: DeviceChipMetrics.chipPadding,
            ),
            decoration: BoxDecoration(
              color: unobserved ? colors.statusFill(colors.amber) : null,
              // No border while the value is the platform's own. Study 2's
              // finding 13: a frame that exists only to give a hairline an edge
              // to be. Five bordered boxes saying nothing has happened is a
              // busy rendering of a quiet fact — the border arrives when the
              // value departs from the default, which is when there is
              // something to frame. Its width is in the measurement either way,
              // so the bar does not reflow when one appears.
              border: Border.all(
                width: DeviceChipMetrics.chipBorder,
                color: unobserved
                    ? colors.statusBorder(colors.amber)
                    : chip.atDefault || unavailable
                    ? Colors.transparent
                    : colors.line2,
              ),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            // `min`, and it is load-bearing: with the default `max` the inner
            // row fills whatever the parent offers, which drew `Theme Light` in
            // a box three times its own width. The measured fold means nothing
            // here ever has to elide.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: DeviceChipMetrics.innerGap,
              children: [
                Text(
                  chip.noun,
                  style: context.type.caption.copyWith(
                    color: unavailable ? colors.mut3 : colors.mut,
                  ),
                ),
                Text(
                  chip.value,
                  maxLines: 1,
                  style: context.type.caption.copyWith(
                    color: ink,
                    fontWeight: quiet || unobserved
                        ? FontWeight.w400
                        : FontWeight.w600,
                  ),
                ),
                if (chip.scope case var scope?)
                  Text(
                    scope,
                    style: context.type.micro.copyWith(color: colors.mut2),
                  ),
                if (chip.state == DeviceSettingState.asked) const _AskedDot(),
                if (unobserved)
                  Icon(
                    Icons.error_outline,
                    size: DeviceChipMetrics.flagSize,
                    color: colors.amber,
                  ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: DeviceChipMetrics.caretSize,
                  color: unavailable ? colors.mut3 : colors.mut,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The write has landed and nothing has confirmed it yet. Deliberately not a
/// spinner: a disagreement between the device and the app can be permanent, and
/// a spinner that never stops is how a permanent one gets read as a slow one.
class _AskedDot extends StatelessWidget {
  const _AskedDot();

  @override
  Widget build(BuildContext context) => Container(
    width: DeviceChipMetrics.dotSize,
    height: DeviceChipMetrics.dotSize,
    decoration: BoxDecoration(
      color: context.colors.accent,
      shape: BoxShape.circle,
    ),
  );
}

/// One sentence under the bar, present only when there is news.
///
/// A strip that prints a line every good day has spent a line saying nothing —
/// the dev-stack card's rule, one slot whose meaning changes per state without
/// moving.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.amber});

  final String text;
  final bool amber;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      color: amber ? colors.statusFill(colors.amber) : colors.panel2,
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          Icon(
            amber ? Icons.error_outline : Icons.info_outline,
            size: 13,
            color: amber ? colors.amber : colors.mut2,
          ),
          Expanded(
            child: Text(
              text,
              style: context.type.caption.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }
}

// ── the picker ───────────────────────────────────────────────────────────────

/// The floating card a picker sits in. Bespoke rather than `PopoverMenuSurface`
/// because this is not a menu: it holds a warning, a field and a verb button,
/// and a surface that clips its rows to 360px would hide the sentence that
/// makes the click safe.
///
/// Public, with [DevicePicker], for one reason: a popover only exists while
/// something is holding it open, so a preview that could not build one directly
/// could not photograph the surface where every cost and every refusal is
/// written.
class DeviceSheet extends StatelessWidget {
  const DeviceSheet({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: 288,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line2),
        borderRadius: BorderRadius.circular(context.radii.radius),
        boxShadow: context.elevation.md,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var (i, child) in children.indexed) ...[
                  if (i > 0) Divider(height: 1, color: context.colors.line),
                  child,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One chip's picker. **This is where the cost lives** — stated above the
/// options and repeated on the verb, so it is read before the click rather than
/// discovered by it. The bar itself carries no cost marker, because five
/// controls with five different costs is five glyphs nobody has a legend for.
class DevicePicker extends StatefulWidget {
  const DevicePicker({
    super.key,
    required this.chip,
    required this.onSet,
    required this.onDone,
  });

  final DeviceChip chip;
  final void Function(DeviceSettingId id, String value)? onSet;
  final VoidCallback onDone;

  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  /// What is picked but not yet written. Null until something is touched, so
  /// the current value stays selected without being copied into state — where
  /// a re-read arriving underneath would leave the sheet showing the old one.
  String? _picked;

  /// What is picked but not yet written, per flag, for a group.
  ///
  /// Its own map rather than [_picked] because a group is several settings and
  /// one button: flipping two flags and pressing `Set` once is what a picker
  /// with a verb on it promises.
  final _pickedFlags = <DeviceSettingId, String>{};

  /// The typed one, for a setting whose options are suggestions rather than the
  /// whole set — see [DeviceSetting.openOptions]. Any BCP-47 tag is a locale,
  /// and neither platform can enumerate them.
  TextEditingController? _typed;

  @override
  void dispose() {
    _typed?.dispose();
    super.dispose();
  }

  DeviceSetting get _only => widget.chip.settings.single;

  void _write(DeviceSettingId id, String value) {
    widget.onSet?.call(id, value);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    var chip = widget.chip;
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: FwSpacing.sm,
        children: [
          Text(chip.name, style: context.type.sectionLabel),
          if (chip.isGroup) ..._flags(context) else ..._single(context),
        ],
      ),
    );
  }

  /// A group is flags, and it picks and then applies like every other picker.
  ///
  /// Written first as write-on-tap, on the argument that a flag is one bit and
  /// every flag on both targets is a free write. That was wrong for a reason
  /// no measurement would have found: it made this the only control on the
  /// strip whose click was final, so the one popover with several things in it
  /// was also the one where you could not change your mind. One button, and it
  /// applies only what moved.
  List<Widget> _flags(BuildContext context) {
    var reachable = [
      for (var setting in widget.chip.settings)
        if (setting.state != DeviceSettingState.unavailable) setting,
    ];
    var refused = [
      for (var setting in widget.chip.settings)
        if (setting.state == DeviceSettingState.unavailable) setting,
    ];
    return [
      for (var setting in reachable) ...[
        Text(
          _nameOf(setting.id),
          style: context.type.caption.copyWith(color: context.colors.ink),
        ),
        Wrap(
          spacing: FwSpacing.xs,
          runSpacing: FwSpacing.xs,
          children: [
            for (var option in setting.options)
              _Option(
                label: option,
                selected: option == (_pickedFlags[setting.id] ?? setting.value),
                onTap: () => setState(() => _pickedFlags[setting.id] = option),
              ),
          ],
        ),
        _footnote(context, setting, compact: true),
      ],
      if (refused.isNotEmpty) _RefusedFlags(settings: refused),
      Align(
        alignment: Alignment.centerRight,
        child: _Confirm(
          label: 'Set',
          onTap: widget.onSet == null
              ? null
              : () {
                  // Only what moved. Each is its own write, its own re-read and
                  // its own journal entry — there is no batch, and a partial
                  // failure has no honest shape to be reported in.
                  for (var setting in reachable) {
                    var picked = _pickedFlags[setting.id];
                    if (picked != null && picked != setting.value) {
                      widget.onSet!(setting.id, picked);
                    }
                  }
                  widget.onDone();
                },
        ),
      ),
    ];
  }

  List<Widget> _single(BuildContext context) {
    var setting = _only;
    if (setting.state == DeviceSettingState.unavailable) {
      return [_Refusal(setting: setting)];
    }
    var open = setting.openOptions;
    // The field is the value when the options are only suggestions, so a
    // suggestion fills it rather than replacing it. Drawn as an either/or
    // first — chips when there were options, a field when there were none —
    // and the consequence was that on Android, where the only "option" is the
    // locale already in force, the picker offered exactly one choice and no
    // way to type another or to clear it.
    var typed = open
        ? _typed ??= TextEditingController(text: setting.value ?? '')
        : null;
    var selected = _picked ?? setting.value;
    var suggestions = [
      for (var option in setting.options)
        _Option(
          label: option,
          selected: open ? typed!.text.trim() == option : option == selected,
          onTap: () => setState(() {
            if (open) {
              typed!.text = option;
            } else {
              _picked = option;
            }
          }),
        ),
      if (setting.clearLabel case var label?)
        _Option(
          label: label,
          selected: open && typed!.text.trim().isEmpty,
          onTap: () => setState(() => typed!.clear()),
        ),
    ];
    return [
      ?_cost(context, setting.cost),
      if (open)
        _Field(
          controller: typed!,
          // Typing changes which suggestion reads as selected, and the clear
          // chip is a suggestion.
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) => _write(setting.id, value.trim()),
        ),
      if (suggestions.isNotEmpty)
        Wrap(
          spacing: FwSpacing.xs,
          runSpacing: FwSpacing.xs,
          children: suggestions,
        ),
      _footnote(context, setting),
      Align(
        alignment: Alignment.centerRight,
        child: _Confirm(
          label: _verb(setting),
          onTap: widget.onSet == null
              ? null
              : () {
                  var value = open ? typed!.text.trim() : selected;
                  if (value == null) return;
                  // An empty value is a real instruction where the platform has
                  // an off position, and nothing at all where it does not.
                  if (value.isEmpty && setting.clearLabel == null) return;
                  _write(setting.id, value);
                },
        ),
      ),
    ];
  }

  /// The sentence above the options. Null when the write is free, which is nine
  /// of the measured cells — which is why it is not always drawn.
  Widget? _cost(BuildContext context, DeviceCost cost) {
    var line = switch (cost) {
      DeviceCost.free => null,
      DeviceCost.takesFocus =>
        'This goes through the device window’s own menu, so it takes your '
            'keyboard focus for a moment.',
      DeviceCost.relaunchesApp =>
        'The device takes it and the running app will not see it until it is '
            'launched again.',
      DeviceCost.restartsApp =>
        'The platform tears the app down and starts it again to apply this.',
    };
    if (line == null) return null;
    var colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: FwSpacing.xs,
      children: [
        Icon(Icons.warning_amber_rounded, size: 13, color: colors.warningText),
        Expanded(
          child: Text(
            line,
            style: context.type.caption.copyWith(color: colors.warningText),
          ),
        ),
      ],
    );
  }

  /// Where the value came from, and from which command. The provenance line is
  /// the whole reason [DeviceProvenance] exists: three measured settings accept
  /// a write, hand it straight back from a `defaults read`, and are never seen
  /// by the app — so a value that is only an echo has to say so somewhere, and
  /// this is the somewhere.
  Widget _footnote(
    BuildContext context,
    DeviceSetting setting, {
    bool compact = false,
  }) {
    var colors = context.colors;
    var style = context.type.micro.copyWith(color: colors.mut2);
    var provenance = [
      if (setting.scope == DeviceScope.app) 'per-app' else 'device-wide',
      ?switch (setting.provenance) {
        DeviceProvenance.answered => null,
        DeviceProvenance.written => 'as written',
        DeviceProvenance.derived => 'from the app’s own geometry',
        DeviceProvenance.unknown => 'nothing answered',
      },
    ].join(' · ');
    // **In a group, the same three lines are three lines too many.** A single
    // picker has one footnote and room for it; a group has one per flag, and
    // with a 36-character simulator UDID in each command that came to ten lines
    // of grey around two switches. So the provenance — the part that is two
    // words and the reason the field exists — stays on the card, and the
    // command and the measurement go one hover away, the way a refused flag's
    // sentence does.
    if (compact) {
      var hidden = [?setting.command, ?setting.note].join('\n\n');
      if (hidden.isEmpty) return Text(provenance, style: style);
      return _HoverTip(
        message: hidden,
        // [Wrap] rather than [Row]: the card is a fixed 288 and a `min` row
        // takes its natural width whatever that is, so `device-wide · as
        // written` and its icon overflowed by 6.8px. Flowing to a second line
        // is the right answer over eliding — the two words are the whole point
        // of the line.
        child: Wrap(
          spacing: FwSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              provenance,
              style: style.copyWith(
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationColor: colors.mut3,
              ),
            ),
            Icon(Icons.info_outline, size: 10, color: colors.mut3),
          ],
        ),
      );
    }
    // Three lines and not one paragraph. Drawn as one first, and the rendering
    // settled it: a simulator UDID is 36 characters, so `xcrun simctl spawn
    // A97ABCFD-… defaults read -g AppleLanguages` ran to three lines of grey
    // and swallowed the two words that carry the meaning. The provenance leads,
    // the command sets itself apart as a command, and the measurement follows.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.xxs,
      children: [
        Text(provenance, style: style),
        if (setting.command case var command?)
          Text(
            command,
            style: context.type.micro.copyWith(
              fontFamily: 'monospace',
              color: colors.mut3,
            ),
          ),
        if (setting.note case var line?) Text(line, style: style),
      ],
    );
  }

  String _verb(DeviceSetting setting) => switch (setting) {
    _ when setting.id == DeviceSettingId.orientation => 'Rotate',
    _ when setting.cost == DeviceCost.relaunchesApp => 'Set and relaunch',
    _ => 'Set',
  };
}

/// What a target cannot do, and what to run instead.
///
/// Drawn rather than hidden: the absence of a control reads as an oversight,
/// and the reason is the useful half — *"Android accepts
/// `high_text_contrast_enabled` and reads it straight back, and no Flutter app
/// sees it. Measured 2026-08-24."*
class _Refusal extends StatelessWidget {
  const _Refusal({required this.setting});

  final DeviceSetting setting;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.xs,
      children: [
        Text(
          setting.refusal ?? 'No mechanism on this target.',
          style: context.type.caption.copyWith(color: colors.mut2),
        ),
        if (setting.command case var command?)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.sm,
              vertical: FwSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: colors.panel2,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: SelectableText(
              command,
              style: context.type.micro.copyWith(
                fontFamily: 'monospace',
                color: colors.ink2,
              ),
            ),
          ),
      ],
    );
  }
}

/// A tooltip that waits for the pointer to actually **move onto** it.
///
/// [Tooltip] opens on `onEnter`, and a mouse region that appears *underneath* a
/// stationary pointer gets a synthetic enter on the very next frame — so
/// opening a popover under the cursor made a paragraph-sized black box appear
/// over it, unprompted, 300ms later. Reported by the first person to use it,
/// and visible in the run journal as taps *on* a tooltip nobody asked for.
///
/// `onHover` fires on movement inside the region and never on that synthetic
/// entry, so arming on it is the difference between *the pointer is here* and
/// *somebody put the pointer here*. Once armed the real [Tooltip] mounts under
/// the pointer and behaves normally, which is what was wanted all along.
class _HoverTip extends StatefulWidget {
  const _HoverTip({
    required this.message,
    required this.child,
    this.waitDuration = const Duration(milliseconds: 300),
  });

  final String message;

  /// Counted from arming, so it is time the pointer spent **inside** rather
  /// than time it spent anywhere.
  final Duration waitDuration;

  /// Kept stateless where the tip wraps something stateful.
  ///
  /// Arming changes this subtree's depth — a [Tooltip] appears above it — so
  /// whatever is directly below loses its element and its state. Harmless for
  /// text; not for a [Tappable] mid-press, which is why [_Chip] puts its tip
  /// *inside* the tappable rather than around it.
  final Widget child;

  @override
  State<_HoverTip> createState() => _HoverTipState();
}

class _HoverTipState extends State<_HoverTip> {
  var _armed = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onHover: (_) {
      if (!_armed) setState(() => _armed = true);
    },
    // Disarmed on the way out, so the next time this appears under a
    // stationary pointer it is as quiet as the first.
    onExit: (_) {
      if (_armed) setState(() => _armed = false);
    },
    child: _armed
        ? Tooltip(
            message: widget.message,
            waitDuration: widget.waitDuration,
            child: widget.child,
          )
        : widget.child,
  );
}

/// The flags this target refuses, on one line, with the reason a hover away.
///
/// [_Refusal] draws the whole measured sentence and its by-hand command, which
/// is right when a refusal is the *only* thing in the popover. In a group it is
/// not: iOS refuses two of four and Android one of three, and three paragraphs
/// and two command boxes turned a 288-pixel card into a wall that buried the
/// two switches it existed for. So the names stay — a missing control still
/// reads as an oversight — and the sentence moves into a tooltip, which is the
/// only thing in this app that can hold a paragraph without spending a
/// paragraph of space on it.
class _RefusedFlags extends StatelessWidget {
  const _RefusedFlags({required this.settings});

  final List<DeviceSetting> settings;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.micro.copyWith(color: colors.mut2);
    return Wrap(
      spacing: FwSpacing.sm,
      runSpacing: FwSpacing.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Not on this device:', style: style),
        for (var setting in settings)
          _HoverTip(
            message: setting.command == null
                ? setting.refusal ?? ''
                : '${setting.refusal}\n\n${setting.command}',
            child: Wrap(
              spacing: FwSpacing.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _nameOf(setting.id),
                  // Dotted, because that is what the rest of the world uses to
                  // say *there is more here* without drawing a control that
                  // does nothing when pressed.
                  style: style.copyWith(
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                    decorationColor: colors.mut3,
                  ),
                ),
                Icon(Icons.info_outline, size: 10, color: colors.mut3),
              ],
            ),
          ),
      ],
    );
  }
}

/// One offered value, at the weight the axis picker settled on: small enough to
/// read as a suggestion rather than as a row of buttons.
class _Option extends StatelessWidget {
  const _Option({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.sm,
          vertical: FwSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft2 : null,
          border: Border.all(color: selected ? colors.accent : colors.line),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(
          label,
          style: context.type.caption.copyWith(
            color: selected ? colors.accentDark : colors.mut,
          ),
        ),
      ),
    );
  }
}

/// A setting with no honest option list — Android's locale, where nothing
/// host-side can say which ones the app has.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: FwSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: colors.line2),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: context.type.caption.copyWith(color: colors.ink),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          hintText: 'fr-FR',
          hintStyle: context.type.caption.copyWith(color: colors.mut3),
        ),
      ),
    );
  }
}

/// The verb, carrying the cost — `Set`, `Rotate`, `Set and relaunch`.
class _Confirm extends StatelessWidget {
  const _Confirm({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var off = onTap == null;
    return Tappable(
      onTap: onTap,
      feedback: TapFeedback.onFill,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: off ? colors.mut3 : colors.accent,
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(
          label,
          style: context.type.button.copyWith(color: colors.panel),
        ),
      ),
    );
  }
}
