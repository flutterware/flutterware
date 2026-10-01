/// A picker in the preview panel — a knob's in the Controls tab, a shell's axis
/// in the top bar — and the box the knob controls sit in.
///
/// Its own file because a control that cannot be reached from outside
/// `catalog_view.dart` cannot be put in the catalog, and a segmented control
/// beside a row of fields is a question for a picture: `demos/knob_picker.dart`
/// renders both styles, beside the fields they share a row with.
library;

import 'package:flutterware/previews_guest.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart' show drawsSegments;
import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';
import '../ui/segmented.dart';
import 'staged_device.dart' show Popover;

/// A [KnobKind.picker], drawn the way its declaration asked — see
/// [PickerStyle].
///
/// One widget for knobs and axes because they are one descriptor, so a
/// `style: PickerStyle.segmented` cannot come to mean something different in
/// the top bar from what it means in the Controls tab.
class KnobPicker extends StatelessWidget {
  const KnobPicker({
    super.key,
    required this.knob,
    required this.value,
    required this.onChanged,
    this.markDefault = false,
  });

  final KnobDescriptor knob;

  /// The option drawn as chosen: the address's, while it and the guest's
  /// report disagree.
  final String? value;

  final ValueChanged<String?> onChanged;

  /// Whether the menu names the default option. The top bar's does, because
  /// an axis is set once for the whole catalog and read back much later.
  final bool markDefault;

  @override
  Widget build(BuildContext context) {
    if (drawsSegments(knob.style, knob.options.length)) {
      return FwSegmented<String>(
        segments: [for (var option in knob.options) FwSegment(option, option)],
        selected: value,
        onChanged: onChanged,
        dense: true,
      );
    }
    return Popover<String?>(
      selected: value,
      onSelected: onChanged,
      groups: [
        (
          heading: null,
          items: [
            for (var option in knob.options)
              (
                value: option,
                label: option,
                detail: markDefault && option == knob.defaultValue
                    ? 'default'
                    : '',
              ),
          ],
        ),
      ],
      child: KnobBox(
        child: Text(
          value ?? '—',
          style: context.type.caption.copyWith(color: context.colors.ink),
        ),
      ),
    );
  }
}

/// The box every knob control sits in, so a field, a picker and a number all
/// line up.
class KnobBox extends StatelessWidget {
  const KnobBox({super.key, required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 24,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: child,
    );
  }
}
