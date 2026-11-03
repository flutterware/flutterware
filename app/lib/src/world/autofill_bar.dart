import 'dart:async';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show FieldKind;
import 'package:material_ui/material_ui.dart';

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'open_world.dart';
import 'world_autofill.dart';
import 'world_person.dart';

/// What the world can fill the field that has focus in [person]'s app with,
/// the way a phone's autofill offers it: every person's address for an
/// address field, their own password for a password, the last code they
/// received for a code. A pick is a step on their app, named as the rest are.
///
/// Nothing while no field has focus, or while the focused one is a kind the
/// world has nothing for.
class AutofillBar extends StatefulWidget {
  const AutofillBar({
    super.key,
    required this.world,
    required this.person,
    required this.colorOf,
    this.detailed = false,
  });

  final OpenWorld world;
  final String person;
  final Color Function(String? person) colorOf;

  /// See [AutofillOffers.detailed].
  final bool detailed;

  /// Its height under a device.
  static const height = AutofillOffers.height;

  @override
  State<AutofillBar> createState() => _AutofillBarState();
}

class _AutofillBarState extends State<AutofillBar> {
  /// Why the last pick did nothing, until focus moves.
  String? _refused;
  WorldField? _field;
  var _picking = false;

  Future<void> _pick(WorldOffer offer) async {
    setState(() {
      _picking = true;
      _refused = null;
    });
    try {
      await widget.world.pick(widget.person, offer, actor: 'human');
    } on WorldRefusal catch (refusal) {
      if (mounted) setState(() => _refused = refusal.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var field = widget.world.tracer?.fieldOf(widget.person);
    if (!identical(field, _field)) {
      _field = field;
      _refused = null;
    }
    var offers = widget.world.offers(widget.person);
    if (field == null || (offers.isEmpty && _refused == null)) {
      return const SizedBox.shrink();
    }
    return AutofillOffers(
      kind: field.kind,
      offers: offers,
      colorOf: widget.colorOf,
      refused: _refused,
      detailed: widget.detailed,
      onPick: _picking ? null : (offer) => unawaited(_pick(offer)),
    );
  }
}

/// [offers] for a focused field of [kind], drawn: under a device, a callout
/// pointing up at it in the accent its focus ring is drawn in, saying whose
/// each one is; in a panel, a row of them with their values.
class AutofillOffers extends StatelessWidget {
  const AutofillOffers({
    super.key,
    required this.kind,
    required this.offers,
    required this.colorOf,
    this.onPick,
    this.refused,
    this.detailed = false,
  });

  final FieldKind kind;
  final List<WorldOffer> offers;
  final Color Function(String? person) colorOf;

  /// Null while a pick is on its way.
  final ValueChanged<WorldOffer>? onPick;

  /// Why the last pick did nothing, said in place of the offers.
  final String? refused;

  /// Each value beside whose it is, for the room a panel has; under a device,
  /// only the names, with the value in a tooltip.
  final bool detailed;

  /// Its height under a device: a person's tag's, and the point that
  /// reaches up to the device.
  static const height = PersonTag.height + _Callout.caret;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.caption.copyWith(color: colors.warningText);
    var content = switch (refused) {
      var said? when detailed => Text(said, style: style),
      // Under a device the bar is one line, at the most a phone's width
      // before the stage shrinks it: the whole sentence is in the tooltip.
      var said? => Tooltip(
        message: said,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            said,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      null => _offers(),
    };
    var icon = Icon(_iconOf(kind), size: FwIconSize.sm, color: colors.mut);
    if (detailed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.xl,
          0,
          FwSpacing.xl,
          FwSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.xs),
              child: icon,
            ),
            const SizedBox(width: FwSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.xxs),
              child: Text('Fill in', style: context.type.bodyMuted),
            ),
            const SizedBox(width: FwSpacing.xs),
            Expanded(child: content),
          ],
        ),
      );
    }
    var accent = colors.accent;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _Callout(
          fill: Color.lerp(colors.bg, accent, 0.08)!,
          border: accent,
          radius: context.radii.radius,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.sm,
            _Callout.caret,
            FwSpacing.xs,
            0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconOf(kind), size: FwIconSize.sm, color: accent),
              const SizedBox(width: FwSpacing.xs),
              if (refused == null) ...[
                Text(
                  'Fill in',
                  style: context.type.body.copyWith(color: accent),
                ),
                const SizedBox(width: FwSpacing.xs),
              ],
              content,
            ],
          ),
        ),
      ),
    );
  }

  Widget _offers() {
    var chips = [
      for (var offer in offers)
        _Offer(
          offer: offer,
          color: offer.person == null ? null : colorOf(offer.person),
          detailed: detailed,
          onPick: switch (onPick) {
            var pick? => () => pick(offer),
            null => null,
          },
        ),
    ];
    if (detailed) {
      return Wrap(
        spacing: FwSpacing.xs,
        runSpacing: FwSpacing.xs,
        children: chips,
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: chips);
  }

  static IconData _iconOf(FieldKind kind) => switch (kind) {
    FieldKind.email => Icons.alternate_email,
    FieldKind.password => Icons.key_outlined,
    FieldKind.name => Icons.person_outline,
    FieldKind.phone => Icons.phone_outlined,
    FieldKind.code => Icons.pin_outlined,
    FieldKind.other => Icons.edit_outlined,
  };
}

/// One thing to fill the field with: whose it is, by their colour and name,
/// or the code itself.
class _Offer extends StatelessWidget {
  const _Offer({
    required this.offer,
    required this.color,
    required this.detailed,
    required this.onPick,
  });

  final WorldOffer offer;
  final Color? color;
  final bool detailed;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var name = offer.person ?? offer.value;
    // A password is never on the screen.
    var shown = offer.secret ? '••••••••' : offer.value;
    // A sign-in names the address it signs in with, never the password.
    var detail = offer.group.isEmpty
        ? shown
        : '${offer.kind == FieldKind.email ? offer.value : offer.group[FieldKind.email]} '
              'and password';
    return Tooltip(
      message: offer.secret || offer.person == null
          ? 'Fill in ${offer.label}'
          : 'Fill in ${offer.label}: $shown',
      child: Tappable(
        onTap: onPick,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.sm,
            vertical: FwSpacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (color case var color?) ...[
                PersonDot(color),
                const SizedBox(width: FwSpacing.xs),
              ],
              Text(name, style: context.type.bodyStrong),
              if (detailed && offer.person != null) ...[
                const SizedBox(width: FwSpacing.sm),
                Text(
                  detail,
                  style: context.type.body.copyWith(color: colors.ink2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A box with a point at the middle of its top edge, reaching up at the
/// device whose field the offers are for.
class _Callout extends CustomPainter {
  const _Callout({
    required this.fill,
    required this.border,
    required this.radius,
  });

  final Color fill;
  final Color border;
  final double radius;

  /// How far the point reaches above the box, and half its width.
  static const caret = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    var middle = size.width / 2;
    var shape = Path.combine(
      PathOperation.union,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, caret, size.width, size.height),
          Radius.circular(radius),
        ),
      ),
      Path()
        ..moveTo(middle - caret, caret + 1)
        ..lineTo(middle, 0)
        ..lineTo(middle + caret, caret + 1)
        ..close(),
    );
    canvas
      ..drawPath(shape, Paint()..color = fill)
      ..drawPath(
        shape,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke,
      );
  }

  @override
  bool shouldRepaint(_Callout old) =>
      old.fill != fill || old.border != border || old.radius != radius;
}
