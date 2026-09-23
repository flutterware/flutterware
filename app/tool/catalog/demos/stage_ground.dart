import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/previews/stage_ground.dart';
import 'package:flutterware_app/src/ui/stage.dart';
import 'package:flutterware_app/src/ui/design/design.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The preview stage — the ground a guest sits on and the edge around it — in
/// the states it takes, under the chrome it has to survive.
///
/// What this is for. The thing being judged is whether two surfaces read as
/// two surfaces, which is a question about a few pixels of edge and a few
/// percent of grey — and the running studio prices one look at a device pick, a
/// compile and a squint at a corner. So the pane is faked: a top bar and an
/// inspect dock in the studio's own colours, and inside them a guest built out
/// of the same design system the studio uses. That last part is not laziness,
/// it is the hard case — the real failure was a demo's `Reload` button two
/// pixels from a real one, and a guest drawn in some other look would hide it.
///
/// The device silhouette is deliberately absent from all of these. It already
/// separates a preview perfectly well; these are the two stagings that had
/// nothing — `Fit`, and a phone with the body switched off.

@Preview(
  name: 'Stage · fitted',
  group: 'Previews stage',
  wrapper: wrapInAppTheme,
)
Widget stageFitted() => const _Pane();

@Preview(
  name: 'Stage · fitted · dark',
  group: 'Previews stage',
  wrapper: wrapInDarkTheme,
)
Widget stageFittedDark() => const _Pane();

/// A phone-shaped guest with the body switched off — where a white screen on a
/// white pane used to be a rectangle with nothing around it.
@Preview(
  name: 'Stage · bodyless phone',
  group: 'Previews stage',
  wrapper: wrapInAppTheme,
)
Widget stageBodyless() => const _Pane(screen: Size(320, 400));

@Preview(
  name: 'Stage · bodyless phone · dark',
  group: 'Previews stage',
  wrapper: wrapInDarkTheme,
)
Widget stageBodylessDark() => const _Pane(screen: Size(320, 400));

/// The edge doing its second job: the guest holds the keyboard, and says so.
///
/// Live in a running preview — click the picture and the edge lights, click
/// anywhere else in the pane and it goes back. Both halves belong to
/// [StageSpecimen]; this entry only starts out focused.
@Preview(
  name: 'Stage · focused',
  group: 'Previews stage',
  wrapper: wrapInAppTheme,
)
Widget stageFocused() => const _Pane(focused: true);

/// The previews pane, minus everything that is not the question.
class _Pane extends StatefulWidget {
  const _Pane({this.focused = false, this.screen});

  final bool focused;

  /// A guest of its own size, sitting on the ground, instead of one fitted to
  /// the canvas.
  final Size? screen;

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  /// Stands in for the panel's own node — the one the guest's input region
  /// focuses on a click.
  final _focus = FocusNode(debugLabel: 'guest');

  @override
  void initState() {
    super.initState();
    if (widget.focused) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // The real panel focuses this from the embedder's input region on a
    // pointer-down inside the guest; there is no embedder here, so the picture
    // takes the click itself.
    var guest = StageSpecimen(
      focus: _focus,
      // The `Focus` is what the embedder's input region provides in the real
      // panel, and it is not optional scaffolding: a node nothing hosts cannot
      // take focus, so without it the press below is a no-op and the edge
      // never lights.
      child: Focus(
        focusNode: _focus,
        child: Listener(
          onPointerDown: (_) => _focus.requestFocus(),
          child: widget.screen == null
              ? const _Guest()
              : SizedBox.fromSize(size: widget.screen!, child: const _Guest()),
        ),
      ),
    );
    return ColoredBox(
      color: colors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TopBar(),
          const Divider(height: 1),
          Expanded(
            child: StageGround(
              child: Padding(
                padding: const EdgeInsets.all(stageInset),
                child: widget.screen == null ? guest : Center(child: guest),
              ),
            ),
          ),
          const Divider(height: 1),
          const _Dock(),
        ],
      ),
    );
  }
}

/// The panel's own bar, near enough for the edge underneath it to be judged.
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      height: 38,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      child: Row(
        children: [
          _Chip(label: 'Fit', colors: colors),
          const SizedBox(width: FwSpacing.md),
          _Chip(label: '100%', colors: colors),
          const Spacer(),
          Icon(Icons.copy_outlined, size: FwIconSize.sm, color: colors.mut),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.colors});

  final String label;
  final FwPalette colors;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: colors.line),
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
    ),
    child: Text(label, style: context.type.caption),
  );
}

class _Dock extends StatelessWidget {
  const _Dock();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      height: 34,
      color: colors.bg,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      child: Row(
        children: [
          for (var tab in ['Controls', 'Elements', 'Semantics', 'Console'])
            Padding(
              padding: const EdgeInsets.only(right: FwSpacing.xl),
              child: Text(
                tab,
                style: context.type.caption.copyWith(color: colors.ink),
              ),
            ),
        ],
      ),
    );
  }
}

/// Somebody else's app — built, on purpose, out of the studio's own design
/// system, because that is the case the separation has to survive. This is very
/// nearly the `Action button` demo as the panel actually renders it.
class _Guest extends StatelessWidget {
  const _Guest();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      // Scrolls rather than overflows: this is staged at 320px wide as well as
      // full width, and a real app on a narrow screen scrolls too.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FwSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Instant — the case this exists for',
              style: context.type.heading,
            ),
            const SizedBox(height: FwSpacing.xs),
            Text(
              'Returns immediately. The running state is held to its floor so '
              'the press is legible anyway.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
            const SizedBox(height: FwSpacing.lg),
            Row(
              children: [
                _GuestButton(label: 'Reload', colors: colors),
                const SizedBox(width: FwSpacing.md),
                _GuestButton(label: 'Resolve', colors: colors),
              ],
            ),
            const SizedBox(height: FwSpacing.xxl),
            Text('Fails', style: context.type.heading),
            const SizedBox(height: FwSpacing.xs),
            Text(
              'The error keeps its own words, and stays up until the next '
              'press rather than timing out unread.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuestButton extends StatelessWidget {
  const _GuestButton({required this.label, required this.colors});

  final String label;
  final FwPalette colors;

  @override
  Widget build(BuildContext context) => Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: colors.line2),
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
    ),
    child: Text(label, style: context.type.caption),
  );
}
