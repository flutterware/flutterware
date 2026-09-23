import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/popover.dart';
import '../../ui/popover_menu.dart';
import '../../ui/tappable.dart';

/// The palette a scene's colours are picked from. A scene's own palette will
/// come from the project (its theme, its tokens); until then this is the
/// spike's, kept so the panel is usable.
const scenePalette = <SceneColor>[
  SceneColor(0xFFFFFFFF),
  SceneColor(0xFF1A1A1A),
  SceneColor(0xFF2B1B12),
  SceneColor(0xFF4A2F1F),
  SceneColor(0xFF6B4226),
  SceneColor(0xFFD8C9BD),
  SceneColor(0xFFE8632B),
  SceneColor(0xFFF2B705),
  SceneColor(0xFF3E7C4F),
  SceneColor(0xFF4A64D0),
];

/// A row of colour dots, the current one ringed. [allowNone] adds the "no
/// colour" dot first — right for a fill, wrong for a text colour or a colour
/// parameter, which always have one.
class SceneSwatches extends StatelessWidget {
  const SceneSwatches({
    super.key,
    required this.current,
    required this.onPick,
    this.allowNone = true,
  });

  final SceneColor? current;
  final void Function(SceneColor?) onPick;
  final bool allowNone;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: FwSpacing.sm,
    runSpacing: FwSpacing.sm,
    children: [
      for (var color in [if (allowNone) null, ...scenePalette])
        Tappable(
          onTap: () => onPick(color),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color?.flutter,
              shape: BoxShape.circle,
              border: Border.all(
                color: current == color
                    ? context.colors.accent
                    : context.colors.line,
                width: current == color ? 2 : 1,
              ),
            ),
            child: color == null
                ? Icon(
                    Icons.block,
                    size: FwIconSize.sm,
                    color: context.colors.mut2,
                  )
                : null,
          ),
        ),
    ],
  );
}

/// A colour, on one line: the swatch, what it is, and the palette one tap
/// behind.
///
/// The panel used to spend a hundred pixels on every colour — eleven dots
/// wrapped over two rows, three times over on a frame — which is a palette,
/// not a field. A colour is one value and reads as one row; the choosing is
/// a moment, and a moment belongs in a popover.
class SceneColorField extends StatelessWidget {
  const SceneColorField({
    super.key,
    required this.current,
    required this.onPick,
    this.allowNone = true,
  });

  final SceneColor? current;
  final void Function(SceneColor?) onPick;
  final bool allowNone;

  static String hexOf(SceneColor c) =>
      '#${c.argb.toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Popover(
      anchor: (context, controller) => Tappable.builder(
        onTap: controller.toggle,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: FwSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            borderRadius: BorderRadius.circular(context.radii.radius),
            border: Border.all(
              color: controller.isOpen
                  ? colors.accent
                  : hovered
                  ? colors.mut3
                  : colors.line,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: current?.flutter,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.line),
                ),
                child: current == null
                    ? Icon(Icons.block, size: FwIconSize.xs, color: colors.mut2)
                    : null,
              ),
              const Gap(FwSpacing.sm),
              Expanded(
                child: Text(
                  current == null ? 'none' : hexOf(current!),
                  style: current == null
                      ? context.type.bodyMuted
                      : context.type.mono,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.expand_more, size: FwIconSize.md, color: colors.mut2),
            ],
          ),
        ),
      ),
      content: (context, controller) => PopoverMenuSurface(
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.md),
          child: SizedBox(
            width: 208,
            child: SceneSwatches(
              current: current,
              allowNone: allowNone,
              onPick: (c) {
                onPick(c);
                controller.close();
              },
            ),
          ),
        ),
      ),
    );
  }
}
