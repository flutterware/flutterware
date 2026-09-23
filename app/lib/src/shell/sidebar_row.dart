import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/native_plugin.dart';
import '../ui/menu.dart';
import '../ui/popover.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';

/// The room a status is guaranteed even when the label wants the whole row.
///
/// Sized to keep a status *visible*, not to keep it complete — that is the
/// difference between a floor and the flat cap this replaced. Without one, a
/// long enough label leaves the status nothing, and nothing does not read as
/// "no status", it reads as a row that lost one. With one set any higher, the
/// status stops yielding and starts competing, which is the arrangement that
/// truncated `fixtures/probe_app` down to `examples/…`.
const _statusFloor = 48.0;

/// How a row [available] wide — [reserved] of it already spoken for by the
/// row's fixtures — splits between a label and a status, given what each of
/// them wants.
///
/// The label is served first, and served whole. It gets its natural width
/// and the status takes everything left, so `app · compiling the catalog…`
/// reads in full instead of truncating beside three empty centimetres of rail.
/// That was the cost of the flat cap this replaced: a constant cannot know
/// that the label beside it is three characters long.
///
/// The one thing that outranks the label is [_statusFloor], and only because
/// a status shrunk to nothing reads as a row that lost one rather than as a
/// row with nothing to say.
///
/// Returns what the *status* may take; the label is a flex child and takes
/// whatever is left, which is what keeps the statuses pinned in one column
/// down the right edge whatever the names say.
double _statusCap(
  double available,
  double reserved, {
  required double labelWants,
  required double statusWants,
}) {
  var room = available - reserved;
  if (room <= 0) return 0;
  var cap = room - labelWants;
  // The floor, and then the status's own appetite — in that order, so a short
  // status is never padded out to the floor and a long one is never starved
  // below it.
  var floor = statusWants < _statusFloor ? statusWants : _statusFloor;
  if (cap < floor) cap = floor;
  if (cap > statusWants) cap = statusWants;
  return cap > room ? room : cap;
}

/// How wide [text] wants to be on one line, in the ambient text scale.
///
/// The rows measure rather than guess because the split above is about what
/// two specific strings want, and a `Flexible` allotment answers a different
/// question: it divides the row by a ratio fixed before either string is known.
double _textWidth(BuildContext context, String text, TextStyle style) {
  var painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  var width = painter.width;
  painter.dispose();
  return width;
}

/// A status, laid out so it can never take a row hostage: one line, capped at
/// [maxWidth], ellipsised past it — and, when it *is* ellipsised, a tooltip
/// carrying the whole of it.
///
/// The tooltip is the same bargain the worktree tabs strike with a long name:
/// the row keeps its shape and the full text is one hover away. Conditional
/// because an unconditional one would pop a box repeating a status you are
/// already reading, on every row of the rail.
///
/// A plugin writes its own status — third-party ones included — so this is
/// enforced rather than assumed. Before it, a plugin that put a runner's log
/// line here got the row: the sidebar showed `[tester] flutterw…` and the
/// worktree switcher set the worktree's name one letter per line.
class StatusText extends StatelessWidget {
  const StatusText(this.status, {super.key, required this.maxWidth});

  final Status status;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    var style = context.type.micro.copyWith(
      color: toneColor(context.colors, status.tone),
    );
    var text = Text(
      status.message,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      textAlign: TextAlign.end,
      style: style,
    );
    // Measured against the same cap the box enforces, so what gets a tooltip is
    // exactly what loses characters.
    var clipped = _textWidth(context, status.message, style) > maxWidth;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: clipped ? Tooltip(message: status.message, child: text) : text,
    );
  }
}

/// The one row shape the sidebar's top level uses — Overview, Changes, and a
/// row per plugin. A filled selection, no border, so selecting never changes
/// anyone's size.
///
/// The status is pinned to the row's right edge, so down the rail the statuses
/// form a column whatever the labels say — a status floating at whatever point
/// the label's flex share happened to end was the arrangement this replaced,
/// and it read as misalignment rather than as a decision. How wide it gets to
/// be is [_statusCap]: the label is served first, and the status takes the
/// rest.
class SidebarRow extends StatelessWidget {
  const SidebarRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.status = Status.none,
    this.actions = const [],
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Status status;

  /// Shown on hover, between the label and the status — a plugin's own
  /// openings. See [PluginRowCommand].
  final List<({String label, IconData icon, VoidCallback onTap})> actions;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var labelStyle = selected
        ? context.type.bodyStrong.copyWith(color: colors.accent)
        : context.type.body;
    return Tappable.builder(
      onTap: onTap,
      // The wash is the primitive's; the flag still reveals the row's actions.
      feedback: TapFeedback.overlay,
      builder: (context, hovered) => Container(
        margin: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: 1,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: FwIconSize.sm,
                  color: selected ? colors.accent : colors.mut,
                ),
                const Gap(FwSpacing.md),
              ],
              // The label takes the slack and yields, which is what pins
              // everything after it to the right edge.
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
              // Only on hover, and only then: a row that always carried its
              // buttons would put a `+` beside every plugin that has one,
              // which is a rail of controls rather than a list of places.
              if (hovered)
                for (var action in actions)
                  Tooltip(
                    message: action.label,
                    child: Tappable.builder(
                      onTap: action.onTap,
                      builder: (context, over) => Padding(
                        padding: const EdgeInsets.only(left: FwSpacing.xs),
                        child: Icon(
                          action.icon,
                          size: FwIconSize.md,
                          color: over ? colors.accent : colors.mut,
                        ),
                      ),
                    ),
                  ),
              if (!status.isEmpty) ...[
                const Gap(FwSpacing.sm),
                StatusText(
                  status,
                  maxWidth: _statusCap(
                    box.maxWidth,
                    (icon != null ? FwIconSize.sm + FwSpacing.md : 0) +
                        FwSpacing.sm,
                    labelWants: _textWidth(context, label, labelStyle),
                    statusWants: _textWidth(
                      context,
                      status.message,
                      context.type.micro,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One package of a plugin, hung off a rail rather than boxed. Selecting it is
/// what raises that package's work.
///
/// Takes what it draws, not the controller that knows it: the shell reads
/// selection and hands over commands, so this can be put in the catalog and
/// looked at in every state without a session behind it. See
/// `tool/catalog/demos/sidebar_row.dart`.
class SidebarChildRow extends StatelessWidget {
  const SidebarChildRow({
    super.key,
    required this.label,
    required this.status,
    required this.selected,
    required this.onTap,
    this.commands = const [],
  });

  final String label;
  final Status status;
  final bool selected;
  final VoidCallback onTap;

  /// What the ⋮ offers. Empty draws no ⋮ at all.
  final List<PluginChildCommand> commands;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var labelStyle = context.type.bodySmall.copyWith(
      color: selected ? colors.ink : colors.mut,
    );

    return Tappable.builder(
      onTap: onTap,
      // The wash is the primitive's; the rail is this row's own, which is why
      // the flag is still read here.
      feedback: TapFeedback.overlay,
      builder: (context, hovered) => Container(
        // The rail is always drawn — only its colour changes — so the row keeps
        // its geometry and nothing below it moves on selection.
        margin: const EdgeInsets.only(left: FwSpacing.xxl),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: selected
                  ? colors.accent
                  : hovered
                  ? colors.mut3
                  : colors.line,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.lg,
          FwSpacing.sm,
          FwSpacing.xl,
          FwSpacing.sm,
        ),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              // The name yields and takes the slack, which is what pins the
              // status to the right — the same column the plugin rows above
              // keep, so the rail reads as one aligned list rather than two
              // conventions. The ⋮ sits past it at the far edge either way.
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
              if (!status.isEmpty) ...[
                const Gap(FwSpacing.sm),
                // Whatever the name leaves, down to a floor: a row reading
                // "10 assets · 347 kB · 2 problems" and not *which package*
                // is worse than one that says neither.
                StatusText(
                  status,
                  maxWidth: _statusCap(
                    box.maxWidth,
                    FwSpacing.sm +
                        (commands.isNotEmpty ? 18 + FwSpacing.sm : 0),
                    labelWants: _textWidth(context, label, labelStyle),
                    statusWants: _textWidth(
                      context,
                      status.message,
                      context.type.micro,
                    ),
                  ),
                ),
              ],
              if (commands.isNotEmpty) ...[
                // Clear of the status. At 14px the glyph is mostly whitespace,
                // so set flush against a word it reads as punctuation on the
                // end of it rather than as a control of its own.
                const Gap(FwSpacing.sm),
                // Only under the pointer, and holding its box either way: a ⋮ on
                // every row is a column of dots down the sidebar, and a ⋮ that
                // appears by *widening* the row shifts the status you were
                // reading on the way to it.
                //
                // Square and explicit, so the tap target is the box rather than
                // the glyph — `Tappable` is opaque and adds no padding of its
                // own, which leaves 14px of dots to hit otherwise.
                SizedBox(
                  width: 18,
                  height: 18,
                  child: hovered || selected
                      ? _ChildCommandsButton(commands)
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The ⋮ on a sidebar child row.
class _ChildCommandsButton extends StatelessWidget {
  const _ChildCommandsButton(this.commands);

  final List<PluginChildCommand> commands;

  @override
  Widget build(BuildContext context) {
    return Menu(
      side: PopoverSide.bottom,
      align: PopoverAlign.end,
      entries: [
        for (var command in commands)
          MenuItem(
            command.label,
            icon: command.icon,
            danger: command.danger,
            // Captured from the *row*, not from the menu: the popover is gone
            // by the time this runs, and a dialog pushed onto a dead context
            // throws.
            onSelected: () => command.onSelected(context),
          ),
      ],
      builder: (context, controller) => Tappable(
        onTap: controller.toggle,
        child: Center(
          child: Icon(
            Icons.more_vert,
            size: FwIconSize.sm,
            color: context.colors.mut,
          ),
        ),
      ),
    );
  }
}
