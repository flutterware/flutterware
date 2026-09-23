/// A shot, drawn where it will actually be seen: in a listing, beside its
/// neighbours, at the size a store shows it.
///
/// **A View.** Plain data and `ImageProvider`s in, pixels out — no filesystem,
/// no core, no manifest. That is what lets `app/tool/catalog/demos/` exercise
/// every state of it with painted stand-ins, and it is why this file knows
/// nothing about where an export puts things.
///
/// **The arrangement, never the chrome** — decision 4. Nothing here copies
/// Apple's or Google's styling, so nothing here goes stale when either
/// restyles. It reads as a listing because of the *shape*: an icon and a name
/// over a row of screenshots that runs off the edge.
///
/// Which settles §12's first open question: **one arrangement, not one per
/// store.** Two chromes would be two invented layouts to keep current, and
/// they would differ only cosmetically — because we are not copying either
/// store, "App Store" and "Play" would be two of our own designs wearing
/// different labels. What genuinely differs, and what a person needs to see,
/// is *how many shots are visible and how much of each* — and that is
/// [StorePlacement], which is a question about the listing rather than about
/// the company.
library;

import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';
import '../ui/theme.dart';

/// Where in a store a listing is being seen.
///
/// The axis that matters, and the reason is arithmetic rather than taste: a
/// product page gives a screenshot its full height and a search result gives it
/// a band off the top. So the question *do my first three carry the listing*
/// stops being ASO folklore and becomes something on screen.
enum StorePlacement {
  /// The listing's own page: shots at full height, three across, the fourth
  /// running off the edge.
  productPage('Product page'),

  /// A row in a result list: shorter, so only the top of each shot survives.
  searchResult('Search result');

  const StorePlacement(this.label);

  final String label;

  /// How much of a shot's height survives here.
  double get visibleFraction => switch (this) {
    productPage => 1.0,
    searchResult => 0.52,
  };
}

/// The listing, as a picture.
class StoreStage extends StatelessWidget {
  const StoreStage({
    super.key,
    required this.shots,
    required this.aspect,
    required this.appName,
    required this.subtitle,
    this.placement = StorePlacement.productPage,
  });

  /// Every shot of the set, in the order the store will show them.
  final List<ImageProvider> shots;

  /// The canvas's width over its height. Passed rather than derived from the
  /// images, because a stage has to lay out before any of them decode — and
  /// because the shape is the thing being judged.
  final double aspect;

  final String appName;
  final String subtitle;
  final StorePlacement placement;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xxl),
            child: _Identity(appName: appName, subtitle: subtitle),
          ),
          const Gap(FwSpacing.xl),
          _Carousel(
            shots: shots,
            aspect: aspect,
            // Cropped from the top, not scaled: a search result shows the top
            // of a screenshot, it does not show a squashed one.
            crop: placement.visibleFraction,
          ),
        ],
      ),
    );
  }
}

/// Icon, name, subtitle — and **nothing invented**.
///
/// It carried a star rating and an Install button for a while. Both are gone,
/// and the rule they broke is worth naming because decision 4 only half said
/// it: we draw the *arrangement*, never the chrome — and an invented rating is
/// worse than chrome. A fake `4.6 · 1.2K ratings` is a number, and a number on
/// a screen is read as a fact about the app; an Install button invites the
/// whole panel to be read as a preview of a real store page rather than as a
/// layout that shows a screenshot at the size a stranger meets it.
///
/// What is left is true: the name and the line under it are the package's own
/// pubspec. The icon is a letter, which is plainly a placeholder rather than a
/// claim.
class _Identity extends StatelessWidget {
  const _Identity({required this.appName, required this.subtitle});

  final String appName;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: colors.accentSoft,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: colors.line),
          ),
          alignment: Alignment.center,
          child: Text(
            appName.isEmpty ? '?' : appName.characters.first.toUpperCase(),
            style: context.type.pageTitle.copyWith(color: colors.accentDark),
          ),
        ),
        const Gap(FwSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appName,
                style: context.type.heading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                subtitle,
                style: context.type.bodySmall.copyWith(color: colors.mut),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The row of shots, running off the right edge.
///
/// Running off is the point. A listing is not a gallery you were handed; it is
/// three screenshots and a hint that there are more, and the fourth being cut
/// by the edge is what makes the first three's job visible.
class _Carousel extends StatefulWidget {
  const _Carousel({
    required this.shots,
    required this.aspect,
    required this.crop,
  });

  final List<ImageProvider> shots;
  final double aspect;

  /// How much of each shot's height is shown, 0–1, measured from the top.
  final double crop;

  /// How many shots the row is sized to hold. Three, and a third of a fourth
  /// — which is what makes the fourth get cut by the edge at any pane width.
  ///
  /// **Sized from the width, not from a fixed height.** A fixed height sized
  /// the shots by their aspect, so a wide pane fitted six of a tall phone's
  /// shots and the whole point of the arrangement — three, and a hint of more
  /// — disappeared into a gallery. Driving it from the width instead means the
  /// first three always are the first three, and a 3:4 tablet simply comes out
  /// shorter than a 1:2 phone, which is true.
  static const _perView = 3.35;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        var room = constraints.maxWidth - FwSpacing.xxl * 2;
        var width =
            (room - FwSpacing.lg * (_Carousel._perView - 1)).clamp(
              120.0,
              4000.0,
            ) /
            _Carousel._perView;
        var height = width / widget.aspect * widget.crop;
        return SizedBox(
          height: height,
          child: _row(context, colors, width: width, crop: widget.crop),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    FwPalette colors, {
    required double width,
    required double crop,
  }) => ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xxl),
    itemCount: widget.shots.length,
    separatorBuilder: (_, _) => const Gap(FwSpacing.lg),
    itemBuilder: (context, index) {
      return Container(
        width: width,
        decoration: BoxDecoration(
          color: colors.panel2,
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: crop,
          child: AspectRatio(
            aspectRatio: widget.aspect,
            child: Image(
              image: widget.shots[index],
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
    },
  );
}
