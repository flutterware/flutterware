/// The device capsule in the preview panel's top bar, and the menu it drops.
///
/// Its own file because it is one control with one subject — what the guest is
/// staged as — and because a control that cannot be reached from outside
/// `catalog_view.dart` cannot be put in the catalog. `demos/staged_device.dart`
/// is the entry that renders it in every state it takes; that is also how its
/// icons were chosen, rather than by reloading the whole studio to look at two
/// glyphs.
library;

import 'package:material_ui/material_ui.dart';

import '../address/address_scope.dart';
import '../ui/design/design.dart';
import '../ui/tappable.dart';
import 'catalog_devices.dart';
import 'catalog_session.dart';

/// What the guest is staged as, as one control: the device, which way up it is,
/// and whether it is drawn inside a body.
///
/// One capsule, because it is one subject. These were three controls with
/// the axis strip between them — picker and rotation at the left, the frame
/// toggle at the far right past the capture button — and the last one read as a
/// property of the panel rather than of the phone. Everything here writes
/// staging or the address; everything to the right of the strip acts on the
/// picture instead.
///
/// Nothing here is ever hidden. Every segment goes dim rather than absent,
/// so moving between a phone and a window does not reflow the bar under the
/// pointer — which is the rule the rotation already followed and the frame
/// toggle did not, appearing and disappearing on the far end as the pick
/// changed.
class StagedDevice extends StatelessWidget {
  const StagedDevice({
    super.key,
    required this.device,
    required this.orientation,
    required this.declared,
    required this.staging,
    required this.keyboard,
    required this.keyboardUp,
  });

  /// The upright device, or null for the panel — which is not a device and has
  /// neither another way up nor a body.
  final Device? device;

  final ScreenOrientation? orientation;

  /// The devices the entry's canvas names, head first.
  final List<Device> declared;

  final CatalogStaging staging;

  /// What the address asks the keyboard to do.
  final KeyboardMode keyboard;

  /// Whether one is actually up — which in [KeyboardMode.auto] is the app's
  /// answer rather than anything this control knows.
  final bool keyboardUp;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var line = VerticalDivider(width: 1, thickness: 1, color: colors.line);
    var radius = context.radii.radiusSmall;
    return Container(
      height: 24,
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(radius),
      ),
      // **A second radius, one pixel smaller, and not `clipBehavior`.** A
      // `Container` that clips takes the border's *outer* path, so a segment
      // filling its box paints over the border through the arc — the line runs
      // along the straight edges and then disappears around the corner. The
      // child belongs inside the border, so it is clipped to the shape the
      // border leaves: the same corner, minus the pixel the border occupies.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DevicePicker(device: device, declared: declared),
            line,
            _RotateSegment(device: device, orientation: orientation),
            line,
            _FrameSegment(device: device, staging: staging),
            line,
            _KeyboardSegment(
              device: device,
              orientation: orientation,
              mode: keyboard,
              up: keyboardUp,
            ),
          ],
        ),
      ),
    );
  }
}

/// One square of [StagedDevice] — an icon that says its own state by lighting
/// up, and goes to [FwPalette.mut3] when there is nothing for it to act on.
///
/// The lit fill is the shared language of the two toggles beside each other,
/// which is why the rotation stopped inverting to solid ink for landscape: two
/// adjacent switches saying "on" two different ways read as two unrelated
/// controls that happen to touch.
class _StagedToggle extends StatelessWidget {
  const _StagedToggle({
    required this.icon,
    required this.on,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;

  /// Whether the thing this switches is *in effect* — not whether it differs
  /// from the default. The frame is on until you turn it off, and a switch that
  /// lit only when you had changed something would be dark for the state it is
  /// describing.
  final bool on;

  final String tooltip;

  /// Null disables the segment, tooltip and all — it still says why.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tappable(
        onTap: onTap,
        child: _SegmentFace(icon: icon, on: on, enabled: onTap != null),
      ),
    );
  }
}

/// What every segment looks like: one square, one glyph, three states.
///
/// Shared rather than copied because the capsule's whole readability rests on
/// its segments agreeing — the lit fill is the language that says *on* across
/// all of them, and a fourth segment that invented its own would read as an
/// unrelated control that happens to touch the others.
class _SegmentFace extends StatelessWidget {
  const _SegmentFace({
    required this.icon,
    required this.on,
    required this.enabled,
  });

  final IconData icon;
  final bool on;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // The wash rather than a colour of our own: the fill here is state, and a
    // hover that changed it would be the segment claiming to have been
    // pressed. The capsule clips, so the overlay takes its rounded end.
    return Container(
      width: 26,
      alignment: Alignment.center,
      color: enabled && on ? colors.accentSoft : colors.bg,
      child: Icon(
        icon,
        size: FwIconSize.sm,
        color: !enabled
            ? colors.mut3
            : on
            ? colors.accent
            : colors.ink,
      ),
    );
  }
}

/// Turns the picked device on its side.
///
/// Beside the picker, not inside it. Orientation is a state of the device
/// you already chose, so "iPad" and "iPad (landscape)" as two rows would make
/// the list say they are different devices — which is the modelling this
/// deliberately does not use, and the list would grow by one row per rotatable
/// entry to say it.
///
/// The glyph turns with the device and the fill says landscape twice over; the
/// size beside the capsule is the confirmation the axis landed — `810×1080`
/// becomes `1080×810`.
class _RotateSegment extends StatelessWidget {
  const _RotateSegment({required this.device, required this.orientation});

  /// The upright device, or null for the panel — which has no other way up.
  final Device? device;

  final ScreenOrientation? orientation;

  @override
  Widget build(BuildContext context) {
    var enabled = device?.canRotate ?? false;
    var landscape = enabled && orientation == ScreenOrientation.landscape;
    return _StagedToggle(
      // **The action, not the device.** The segment beside this one draws a
      // phone, so a phone here made the pair read as one control drawn twice —
      // and every *rotate* glyph with a diagonal in it (`screen_rotation`,
      // `rotate_90_degrees_ccw`) reads as a slashed circle at 16pt, which says
      // "forbidden". A plain circular arrow says turn and nothing else —
      // picked by rendering thirteen candidate pairs at 16pt and looking at
      // them, which is the only way a glyph this size gets decided.
      //
      // The cost is that the glyph no longer says *which* way up it is. The
      // lit fill says it, and the size beside the capsule turns over with it.
      icon: Icons.rotate_right,
      on: landscape,
      tooltip: !enabled
          ? '${device?.label ?? 'The panel'} does not rotate'
          : landscape
          ? 'Back to portrait'
          : 'Rotate to landscape',
      onTap: enabled
          // Portrait clears the parameter rather than writing itself: the
          // default belongs in nobody's address, and a link that says
          // nothing about orientation has to keep meaning what it meant.
          ? () => AddressScope.write(context).setParam(
              'orientation',
              landscape ? null : ScreenOrientation.landscape.name,
            )
          : null,
    );
  }
}

/// Draws the device's body around the preview, or takes it away.
///
/// Off for anything with no silhouette, which is the panel and every window
/// size: [canBeFramed] is the same question the canvas asks before it reaches
/// for a body, so the switch cannot claim a picture it would not change. It was
/// live for a window before, and pressing it did nothing at all.
class _FrameSegment extends StatelessWidget {
  const _FrameSegment({required this.device, required this.staging});

  final Device? device;
  final CatalogStaging staging;

  @override
  Widget build(BuildContext context) {
    var enabled = device != null && canBeFramed(device!);
    var on = enabled && staging.frameVisible;
    return _StagedToggle(
      // The device itself, because that is literally what this draws — and it
      // is the only phone in the capsule now, the rotation beside it having
      // become the action instead.
      icon: Icons.phone_iphone,
      on: on,
      tooltip: !enabled
          ? '${device?.label ?? 'Fit'} is drawn without a body'
          : on
          ? 'Hide the frame'
          : 'Show the frame',
      onTap: enabled
          ? () => staging.frameVisible = !staging.frameVisible
          : null,
    );
  }
}

/// Raises the software keyboard, or lets the demo decide.
///
/// A menu rather than a toggle, because it has three states and they have
/// names. The other two segments are switches — the device is framed or it
/// is not — and this one is not: *automatic* is a third thing, and it is the
/// default. A cycling icon would have made the two forced states and the
/// default indistinguishable until you had clicked twice to find out.
///
/// The fill still says one thing and says it the way its neighbours do:
/// lit when a keyboard is actually up. In [KeyboardMode.auto] that is the
/// app's answer rather than the address's — a form with a field focused lights
/// this without anybody having chosen anything, which is exactly the fact
/// worth putting on the bar.
///
/// Dark on anything with no measured keyboard: every desktop size, and `Fit`,
/// which is not a device. Raising a keyboard there would mean inventing a
/// height, which is the one thing the measured table exists not to do.
class _KeyboardSegment extends StatelessWidget {
  const _KeyboardSegment({
    required this.device,
    required this.orientation,
    required this.mode,
    required this.up,
  });

  /// The upright device — turned here, because a phone's landscape keyboard is
  /// not its portrait one and the height is what the menu shows.
  final Device? device;

  final ScreenOrientation? orientation;
  final KeyboardMode mode;
  final bool up;

  @override
  Widget build(BuildContext context) {
    var height = device?.oriented(orientation).keyboard ?? 0;
    var enabled = height > 0;
    var face = _SegmentFace(
      // The keyboard, and the *hidden* keyboard when it is forced down — the
      // one state the fill cannot say, because dark already means "nothing is
      // up" and forced-down means "nothing may come up".
      icon: mode == KeyboardMode.down ? Icons.keyboard_hide : Icons.keyboard,
      on: enabled && up,
      enabled: enabled,
    );
    if (!enabled) {
      return Tooltip(
        message: '${device?.label ?? 'Fit'} has no software keyboard',
        child: face,
      );
    }
    return Tooltip(
      message: switch (mode) {
        KeyboardMode.auto =>
          up
              ? 'Keyboard up — the demo has a field focused'
              : 'Keyboard follows the demo',
        KeyboardMode.up => 'Keyboard held up (${height.round()}\u2009pt)',
        KeyboardMode.down => 'Keyboard held down',
      },
      child: Popover<KeyboardMode>(
        selected: mode,
        // Automatic clears the parameter rather than writing itself, like the
        // rotation beside it: the default belongs in nobody's address, and a
        // link that says nothing about the keyboard has to keep meaning what
        // it meant before there was one.
        onSelected: (value) => AddressScope.write(
          context,
        ).setParam('keyboard', value == KeyboardMode.auto ? null : value.name),
        groups: [
          (
            heading: null,
            items: [
              (
                value: KeyboardMode.auto,
                label: 'Automatic',
                detail: 'on focus',
              ),
              (
                value: KeyboardMode.up,
                label: 'Shown',
                // The measurement, where the other rows say a rule. It is the
                // number the layout has to survive, and the only place in the
                // GUI it is written down.
                detail: '${height.round()} pt',
              ),
              (value: KeyboardMode.down, label: 'Hidden', detail: 'never'),
            ],
          ),
        ],
        child: face,
      ),
    );
  }
}

/// Picks what the guest is sized to. "Fit" is the panel itself.
///
/// Hand-rolled rather than a [PopupMenuButton]: the stock menu gives every row
/// the same weight, so the platform headings read as disabled entries, and its
/// scale-from-nothing entrance belongs to a floating action button rather than
/// to a control that drops open under your cursor.
class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.device, this.declared = const []});

  /// What is on screen, already resolved. The picker holds nothing.
  final Device? device;

  /// The devices the entry's canvas names, head first.
  ///
  /// Offered at the top rather than merely defaulted to, which is the other
  /// half of "the list is the offered set": a card with a breakpoint in it is
  /// meant to survive a small phone *and* a large one, and a project that has
  /// written down which two should not have to find them again in a table of
  /// every phone ever made.
  final List<Device> declared;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Popover<Device?>(
      selected: device,
      // **The only place a device is chosen, and it writes the address.** It
      // used to set the staging and let the panel copy that into the address a
      // frame later; the copy came back stale and undid the pick.
      onSelected: (value) =>
          AddressScope.write(context)
              .setParam('device', value?.id ?? fitDeviceId),
      groups: [
        (
          heading: null,
          items: [(value: null, label: 'Fit', detail: 'the panel')],
        ),
        if (declared.isNotEmpty)
          (
            heading: 'Declared',
            items: [
              for (var d in declared)
                (value: d, label: d.label, detail: describeDevice(d)),
            ],
          ),
        for (var group in {for (var d in Devices.all) d.group})
          (
            heading: group,
            items: [
              for (var d in Devices.all.where((d) => d.group == group))
                (value: d, label: d.label, detail: describeDevice(d)),
            ],
          ),
      ],
      // Borderless: the capsule around the three segments draws the one border,
      // and a second inside it would box the name against its own switches.
      child: Container(
        padding: const EdgeInsets.only(left: FwSpacing.md, right: FwSpacing.xs),
        height: 24,
        color: colors.bg,
        child: Row(
          spacing: FwSpacing.xs,
          children: [
            Text(
              // Straight off the device now. It used to be a scan of the list
              // by `device_frame` identifier, because staging held that type
              // rather than ours.
              device?.label ?? 'Fit',
              style: context.type.caption.copyWith(color: colors.ink),
            ),
            Icon(Icons.expand_more, size: FwIconSize.sm, color: colors.mut),
          ],
        ),
      ),
    );
  }
}

typedef PopoverItem<T> = ({T value, String label, String detail});
typedef PopoverGroup<T> = ({String? heading, List<PopoverItem<T>> items});

/// A menu that drops open under its anchor.
class Popover<T> extends StatelessWidget {
  const Popover({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    required this.child,
  });

  final List<PopoverGroup<T>> groups;
  final T selected;
  final ValueChanged<T> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, FwSpacing.xs),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.colors.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: FwSpacing.sm),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            side: BorderSide(color: context.colors.line),
            borderRadius: BorderRadius.circular(context.radii.radius),
          ),
        ),
      ),
      builder: (context, controller, child) => InkWell(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: child,
      ),
      menuChildren: [
        for (var group in groups) ...[
          if (group.heading case var heading?)
            // A heading, not a disabled row: uppercase, muted and half-height,
            // so the eye takes it for a label rather than for something it is
            // not allowed to pick.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FwSpacing.lg,
                FwSpacing.md,
                FwSpacing.lg,
                FwSpacing.xxs,
              ),
              child: Text(
                heading.toUpperCase(),
                style: context.type.micro.copyWith(
                  color: context.colors.mut2,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          for (var item in group.items)
            PopoverRow(
              item: item,
              selected: item.value == selected,
              onTap: () => onSelected(item.value),
            ),
        ],
      ],
      child: child,
    );
  }
}

class PopoverRow<T> extends StatelessWidget {
  const PopoverRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final PopoverItem<T> item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(
          selected ? colors.accentSoft : Colors.transparent,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: FwSpacing.lg),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
      ),
      child: SizedBox(
        width: 200,
        child: Row(
          spacing: FwSpacing.lg,
          children: [
            Expanded(
              child: Text(
                item.label,
                style: context.type.bodySmall.copyWith(color: colors.ink),
              ),
            ),
            // The size, right-aligned in its own column: it is what you are
            // choosing between once you know the names.
            Text(
              item.detail,
              style: context.type.caption.copyWith(
                fontFamily: 'monospace',
                color: colors.mut,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
