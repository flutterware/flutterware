import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../ui/action_button.dart';
import '../ui/menu.dart';
import '../ui/popover.dart' show PopoverAlign;
import '../ui/panel_header.dart' show panelGutter;
import '../ui/picker.dart';
import '../ui/segmented.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'open_world.dart';
import 'world_person.dart' show PersonDot;

/// How the open world is looked at: everyone's apps side by side, or what
/// happened in it, in order.
enum WorldView { phones, timeline }

/// The open world's one toolbar: on the left what can be done to it — its
/// knobs, each a restart with a new value, then a menu of its actions, run
/// in the world as it is — and on the right how it is looked at, and who is
/// in view: everyone, or one person.
class WorldToolbar extends StatelessWidget {
  const WorldToolbar({
    super.key,
    required this.world,
    required this.enabled,
    required this.focus,
    required this.colorOf,
    required this.onFocus,
    required this.view,
    required this.onView,
  });

  final OpenWorld world;

  /// False while the world is moving: nothing to act on yet.
  final bool enabled;

  /// The person in focus; null for everyone.
  final String? focus;
  final Color Function(String person) colorOf;
  final ValueChanged<String?> onFocus;
  final WorldView view;
  final ValueChanged<WorldView> onView;

  static const height = 44.0;

  /// What a picker adds to its longest option: its padding and chevron.
  static const _pickerChrome = 48.0;

  static double _textWidth(String words, TextStyle style) {
    var painter = TextPainter(
      text: TextSpan(text: words, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    var width = painter.width;
    painter.dispose();
    return width;
  }

  /// As wide as [knob]'s longest option needs.
  static double _knobWidth(BuildContext context, WorldKnob knob) =>
      _pickerChrome +
      knob.options
          .map((option) => _textWidth(option, context.type.body))
          .fold(0.0, max);

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var knobs = [
      for (var knob in world.knobs.values)
        if (knob.options.isNotEmpty) knob,
    ];
    var left = [
      for (var knob in knobs) _knob(context, knob),
      if (knobs.isNotEmpty && world.actions.isNotEmpty)
        Container(width: 1, height: 20, color: colors.line),
      // However many the script declares, one button: a row of them grew
      // past the bar.
      if (world.actions.isNotEmpty)
        Menu(
          entries: [
            for (var MapEntry(key: action, value: description)
                in world.actions.entries)
              MenuItem(
                action,
                detail: description,
                icon: Icons.play_arrow_rounded,
                onSelected: enabled
                    ? () => unawaited(world.invoke(action))
                    : null,
              ),
          ],
          maxWidth: 360,
          builder: (context, controller) => FwActionButton(
            label: 'Actions',
            icon: Icons.play_arrow_rounded,
            iconColor: colors.accent,
            trailingIcon: Icons.expand_more,
            acknowledges: false,
            onPressed: enabled ? () async => controller.toggle() : null,
          ),
        ),
    ];
    return Container(
      height: height,
      padding: const EdgeInsets.only(left: panelGutter, right: FwSpacing.lg),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.symmetric(horizontal: BorderSide(color: colors.line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          var views = [
            FwSegment(
              WorldView.phones,
              'Phones',
              leading: Icon(
                Icons.devices_other,
                size: FwIconSize.sm,
                color: colors.ink2,
              ),
              tooltip: 'All the apps, side by side',
            ),
            FwSegment(
              WorldView.timeline,
              'Timeline',
              leading: Icon(
                Icons.view_timeline_outlined,
                size: FwIconSize.sm,
                color: colors.ink2,
              ),
              tooltip: 'Everything that happened, in order',
            ),
          ];
          var used =
              _widthOf(context, knobs, actions: world.actions.isNotEmpty) +
              FwSegmented.trayInset +
              views
                  .map((view) => FwSegmented.widthOf(context, view))
                  .fold(0.0, (a, b) => a + b) +
              FwSpacing.lg;
          return Row(
            children: [
              for (var (i, control) in left.indexed) ...[
                if (i > 0) const SizedBox(width: FwSpacing.sm),
                control,
              ],
              const Spacer(),
              FwSegmented<WorldView>(
                segments: views,
                selected: view,
                onChanged: onView,
              ),
              if (world.people.isNotEmpty) ...[
                const SizedBox(width: FwSpacing.lg),
                _PeopleSwitch(
                  people: world.people.keys.toList(),
                  focus: focus,
                  colorOf: colorOf,
                  onFocus: onFocus,
                  room: constraints.maxWidth - used - FwSpacing.xxl,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// How wide the left of the bar is drawn: what the switch cannot have.
  double _widthOf(
    BuildContext context,
    List<WorldKnob> knobs, {
    required bool actions,
  }) {
    var text = _textWidth;
    var widths = [
      for (var knob in knobs)
        text(knob.name, context.type.bodyMuted) +
            FwSpacing.sm +
            _knobWidth(context, knob),
      if (knobs.isNotEmpty && actions) 1.0,
      // Its padding, its two icons and their gaps, then its word.
      if (actions)
        2 * FwSpacing.lg +
            2 * FwIconSize.sm +
            FwSpacing.xs +
            FwSpacing.xxs +
            text('Actions', context.type.caption),
    ];
    return widths.fold(0.0, (a, b) => a + b) +
        (widths.length - 1).clamp(0, 99) * FwSpacing.sm;
  }

  Widget _knob(BuildContext context, WorldKnob knob) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(knob.name, style: context.type.bodyMuted),
      const SizedBox(width: FwSpacing.sm),
      SizedBox(
        width: _knobWidth(context, knob),
        child: Tooltip(
          message: [
            ?knob.description,
            'Changing this restarts the world.',
          ].join('\n'),
          child: FwPicker<String>(
            choices: [
              for (var option in knob.options)
                FwChoice(value: option, label: option),
            ],
            selected: knob.value,
            onChanged: (value) {
              if (!enabled || value == knob.value) return;
              unawaited(world.restart({...world.knobValues, knob.name: value}));
            },
          ),
        ),
      ),
    ],
  );
}

/// Everyone, or one person: as many as the bar has room for, the rest in a
/// menu at the end — and the one in focus always among those shown.
class _PeopleSwitch extends StatelessWidget {
  const _PeopleSwitch({
    required this.people,
    required this.focus,
    required this.colorOf,
    required this.onFocus,
    required this.room,
  });

  final List<String> people;
  final String? focus;
  final Color Function(String person) colorOf;
  final ValueChanged<String?> onFocus;

  /// How wide it may be drawn.
  final double room;

  /// What the menu of the rest takes: `+12 ▾`.
  static const _moreWidth = 56.0;

  FwSegment<String?> _segment(String person) =>
      FwSegment(person, person, leading: PersonDot(colorOf(person)));

  @override
  Widget build(BuildContext context) {
    var everyone = FwSegment<String?>(
      null,
      'Everyone',
      leading: Icon(
        Icons.grid_view,
        size: FwIconSize.sm,
        color: context.colors.ink2,
      ),
    );
    var used = FwSegmented.trayInset + FwSegmented.widthOf(context, everyone);
    var shown = <String>[];
    for (var (i, person) in people.indexed) {
      var width = FwSegmented.widthOf(context, _segment(person));
      var more = i < people.length - 1 ? _moreWidth : 0;
      if (used + width + more > room) break;
      shown.add(person);
      used += width;
    }
    // The one in focus is never behind the menu: it takes the last place.
    if (focus case var focus? when !shown.contains(focus) && shown.isNotEmpty) {
      shown[shown.length - 1] = focus;
    }
    var rest = [
      for (var person in people)
        if (!shown.contains(person)) person,
    ];
    return FwSegmented<String?>(
      segments: [everyone, for (var person in shown) _segment(person)],
      selected: focus,
      onChanged: onFocus,
      trailing: rest.isEmpty
          ? null
          : Menu(
              align: PopoverAlign.end,
              entries: [
                for (var person in rest)
                  MenuItem(person, onSelected: () => onFocus(person)),
              ],
              builder: (context, controller) => Tooltip(
                message: '${rest.length} more',
                child: Tappable(
                  onTap: controller.toggle,
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall - 2,
                  ),
                  child: SizedBox(
                    height: 24,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FwSpacing.md,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '+${rest.length}',
                            style: context.type.bodySmall.copyWith(
                              color: context.colors.ink2,
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: FwIconSize.sm,
                            color: context.colors.mut,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
