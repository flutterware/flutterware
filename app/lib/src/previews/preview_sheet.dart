import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../ui/design/design.dart';
import '../ui/tappable.dart';
import 'catalog_entry.dart';
import 'catalog_tree.dart';

/// What a tile with no picture is waiting for.
///
/// The three are not one state, and drawing them as one was the whole problem:
/// a page of grey boxes says nothing about whether the first picture is two
/// seconds away or forty.
enum PreviewTileWait {
  /// In the page's ask, and the harness will get to it. Seconds away, so it is
  /// drawn as a plain reserved box and nothing more.
  queued,

  /// Nothing can be rendered yet: the harness is compiling the whole catalog,
  /// which is tens of seconds. This is the one that shimmers.
  compiling,

  /// Being photographed at this instant.
  rendering,
}

/// The catalog as pictures rather than as names.
///
/// **The geometry is final before any picture exists.** Every tile reserves the
/// box its picture will occupy — from the screen the entry is declared to open
/// on, which the scan already knows — so a sheet of empty boxes and a sheet of
/// photographs have identical layouts and nothing moves as renders land. That
/// is the property the whole surface rests on: a full catalog is tens of
/// seconds of rendering, so the page has to be useful and stable long before it
/// is finished. A grid that reflowed as pictures arrived would be unusable at
/// exactly the moment it is being looked at.
///
/// The cell is uniform and the *picture* inside it is not. A catalog holds
/// phones and panels, and a grid that gave them one shape would either squash
/// the phones or letterbox everything into the tallest thing present.
///
/// **The row height is the section's, not the sheet's.** One height for the
/// whole catalog means every desktop tile carries a phone's worth of empty
/// space under it — a quarter of the page, over a hundred and forty-five tiles.
/// A section is one component's variants and they are almost always one shape,
/// so a height taken per section is tight for both: the panels sit in 4:3 rows
/// and the phones get tall ones. Clamped at both ends, because "the tallest
/// thing present" is a phone at more than twice its own width and a row of
/// those is a column.
class PreviewSheet extends StatefulWidget {
  const PreviewSheet({
    super.key,
    required this.sections,
    required this.screenOf,
    this.bytesOf,
    this.problemOf,
    this.onVisible,
    this.selectedId,
    this.onTap,
    this.onUndecodable,
    this.waitOf,
    this.animate = false,
  });

  /// What [entry] is waiting for, or null when it is not waiting.
  ///
  /// Only consulted for a tile with no picture — a tile that has one is not
  /// waiting for anything, whatever a store that is midway through re-rendering
  /// it happens to say.
  final PreviewTileWait? Function(CatalogEntry entry)? waitOf;

  /// Whether the shimmer runs.
  ///
  /// **One ticker for the whole sheet, and this is the switch on it.** A
  /// hundred and fifty animated tiles is a hundred and fifty
  /// `AnimationController`s, each waking the scheduler, on exactly the frames
  /// where the thing being waited for is a compiler that wants every core. One
  /// controller lives at the sheet, is read down the tree, and is stopped the
  /// moment nothing is pending.
  final bool animate;

  /// [entry]'s bytes would not decode.
  ///
  /// A page draws the encoded form, so nothing decodes a tile's picture before
  /// it is painted — this is the only moment anything finds out that what a
  /// store handed over is not an image. Reported so it can be re-rendered
  /// rather than shown as an empty frame for ever.
  final void Function(CatalogEntry entry)? onUndecodable;

  /// The entries, under the headings they sit beneath.
  final List<PreviewSheetSection> sections;

  /// The screen [entry] opens on, in logical pixels, or null for the plain
  /// rectangle an entry under no canvas gets.
  ///
  /// A callback rather than a map on the entry, because the answer is the
  /// package's declaration rather than anything the entry carries — the same
  /// resolution the stage does when it frames one.
  final Size? Function(CatalogEntry entry) screenOf;

  /// [entry]'s picture as encoded bytes, or null while there is none.
  ///
  /// Bytes rather than a decoded image so that the decoding, the caching and
  /// the bounding are Flutter's — a page draws far more pictures than a
  /// popover, and a store that handed out `ui.Image`s would have to guarantee
  /// it never disposed one a tile was mid-paint on.
  final Uint8List? Function(CatalogEntry entry)? bytesOf;

  /// What went wrong with [entry], for the ones that have no picture because
  /// they did not render. Drawn in the tile rather than hidden: a grey box that
  /// never fills is the same picture as one still rendering, and they are not
  /// the same thing.
  final String? Function(CatalogEntry entry)? problemOf;

  /// The entries this page built this frame, in the order it built them.
  ///
  /// **This is what makes the page render itself in the order it is read.**
  /// A grid builds the tiles near the viewport and no others, so the list this
  /// hands back is already "what is on screen, roughly top-first" — no
  /// scroll-offset arithmetic and no guessing at row heights. Reported once per
  /// frame rather than once per tile, so a caller may treat it as the whole ask
  /// and replace whatever it had.
  final void Function(List<CatalogEntry> entries)? onVisible;

  final String? selectedId;

  final void Function(CatalogEntry entry)? onTap;

  /// The widest a tile is allowed to be before another column is added.
  ///
  /// Not a fixed column count: the pane this sits in is anywhere between the
  /// stage beside an open tree and the whole window with the tree folded away,
  /// and a count that suited one would be four enormous tiles or twelve
  /// unreadable ones in the other.
  static const maxTileWidth = 180.0;

  /// The room under a picture for the entry's name.
  static const _labelHeight = 24.0;

  /// A heading's height, fixed because a pinned header has to declare its
  /// extent before anything is laid out.
  static const _headingHeight = 32.0;

  /// The gap below a section's last row.
  static const _sectionGap = FwSpacing.xl;

  /// How tall a picture may be against its own width. A phone is 2.17 and a row
  /// of them at full height is a column with three things in it.
  static const _tallest = 1.5;

  /// And how short. Nothing in the table is wider than 2.5:1, but a project can
  /// declare any size, and a row of 40-pixel slivers is not a contact sheet.
  static const _shortest = 0.6;

  @override
  State<PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<PreviewSheet>
    with SingleTickerProviderStateMixin {
  /// Collected as the grid builds and flushed once the frame is done — see
  /// [PreviewSheet.onVisible].
  final _built = <CatalogEntry>[];
  var _flushing = false;

  /// The sheet's one ticker — see [PreviewSheet.animate].
  ///
  /// Held for the life of the sheet and merely stopped when there is nothing
  /// pending, rather than created and destroyed: a page fills in bursts, and a
  /// controller that came and went with each of them would be rebuilding the
  /// inherited scope every time.
  late final _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _shimmer.repeat();
  }

  @override
  void didUpdateWidget(PreviewSheet old) {
    super.didUpdateWidget(old);
    if (widget.animate == old.animate) return;
    if (widget.animate) {
      _shimmer.repeat();
    } else {
      _shimmer.stop();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  void _note(CatalogEntry entry) {
    if (widget.onVisible == null) return;
    _built.add(entry);
    if (_flushing) return;
    _flushing = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _flushing = false;
      if (!mounted || _built.isEmpty) return;
      var seen = <String>{};
      var visible = [
        for (var entry in _built)
          if (seen.add(entry.id)) entry,
      ];
      _built.clear();
      widget.onVisible?.call(visible);
    });
  }

  @override
  Widget build(BuildContext context) {
    var sections = widget.sections;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = FwSpacing.lg;
        var inner = constraints.maxWidth - FwSpacing.lg * 2;
        // The delegate's own arithmetic, done here because the tile height has
        // to be the resolved *width* plus a label — a `childAspectRatio` cannot
        // say that, since the width it would be a ratio of is what this is
        // computing.
        var columns = ((inner + gap) / (PreviewSheet.maxTileWidth + gap))
            .ceil()
            .clamp(1, 12);
        var side = ((inner - gap * (columns - 1)) / columns).clamp(
          48.0,
          PreviewSheet.maxTileWidth,
        );
        var slivers = <Widget>[];
        for (var (index, section) in sections.indexed) {
          var picture = side * section.pictureRatio;
          var extent = picture + PreviewSheet._labelHeight;
          var grid = SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.lg,
              0,
              FwSpacing.lg,
              PreviewSheet._sectionGap,
            ),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: gap,
                mainAxisSpacing: gap,
                mainAxisExtent: extent,
              ),
              delegate: SliverChildBuilderDelegate((context, at) {
                var entry = section.entries[at];
                _note(entry);
                var bytes = widget.bytesOf?.call(entry);
                return _Tile(
                  entry: entry,
                  screen: widget.screenOf(entry),
                  bytes: bytes,
                  problem: widget.problemOf?.call(entry),
                  wait: bytes != null ? null : widget.waitOf?.call(entry),
                  width: side,
                  height: picture,
                  selected: entry.id == widget.selectedId,
                  onUndecodable: widget.onUndecodable,
                  onTap: widget.onTap == null
                      ? null
                      : () => widget.onTap!(entry),
                );
              }, childCount: section.entries.length),
            ),
          );

          if (section.label case var label?) {
            slivers.add(
              // **Grouped, which is what makes it one heading and not a
              // stack.** Several pinned headers in one scroll view all stay
              // pinned and pile up; inside a group a header is pinned only
              // while its own section is on screen, and the next one pushes it
              // off — which is the behaviour anybody has ever wanted from a
              // sticky heading.
              SliverMainAxisGroup(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _PinnedHeading(label),
                  ),
                  grid,
                ],
              ),
            );
          } else {
            // The entries at the root have no heading to give them, and
            // without one they read as the tail of whatever section is above
            // them. A rule says "these are not those" without inventing a name
            // for a group the catalog does not have.
            if (index > 0) {
              slivers.add(const SliverToBoxAdapter(child: _RootRule()));
            }
            slivers.add(grid);
          }
        }
        return _ShimmerScope(
          animation: _shimmer,
          child: CustomScrollView(
            // A screen of tiles built ahead in each direction: enough that a
            // flung scroll is never looking at nothing, and short of the "build
            // the whole catalog" that a large extent amounts to. In viewports
            // rather than pixels because the pane this sits in is resizable,
            // and the answer wanted is "a screenful" at any of its sizes.
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            slivers: slivers,
          ),
        );
      },
    );
  }
}

/// One heading, the entries under it, and how tall a picture in it is.
class PreviewSheetSection {
  const PreviewSheetSection({
    required this.label,
    required this.entries,
    required this.pictureRatio,
  });

  /// The folder or group these sit in, or null for the entries the index shows
  /// under no folder at all — see [previewSheetSections]'s `rootLabel`.
  final String? label;

  final List<CatalogEntry> entries;

  /// A picture's height as a multiple of a tile's width — the tallest entry
  /// here needs, within the clamp.
  ///
  /// Decided when the section is built rather than during layout. It walks
  /// every entry, and a sheet that recomputed it for every section on every
  /// frame would be walking the whole catalog to lay out one screen of it.
  final double pictureRatio;
}

/// [tree] flattened into headed sections, in the tree's own order.
///
/// The sheet does not nest: a heading is the whole path down to the entries
/// under it — `Home page / Default` rather than an indented `Default` inside a
/// `Home page` — because a grid has no indentation to nest *with*, and a
/// heading that repeated one word per level would say less than the joined path
/// does. Root leaves come last, which is where the tree puts them too.
///
/// [rootLabel] names those root leaves, and is what a narrowed sheet has that
/// the index does not: inside a folder they are the folder's own entries and it
/// is the folder's name they want — see `scopeHeading`. At the index they are
/// the entries that sit under no folder at all, there is no name to give them,
/// and a rule stands in for one.
List<PreviewSheetSection> previewSheetSections(
  List<CatalogNode> tree, {
  required Size? Function(CatalogEntry entry) screenOf,
  String? rootLabel,
}) {
  var sections = <PreviewSheetSection>[];
  var loose = <CatalogEntry>[];

  double ratioOf(List<CatalogEntry> entries) {
    var tallest = 0.0;
    for (var entry in entries) {
      var screen = screenOf(entry);
      var ratio = screen == null
          ? 1 / _Tile.plainAspect
          : screen.height / screen.width;
      if (ratio > tallest) tallest = ratio;
    }
    return tallest.clamp(PreviewSheet._shortest, PreviewSheet._tallest);
  }

  void walk(List<CatalogNode> nodes, String? path) {
    var here = <CatalogEntry>[];
    for (var node in nodes) {
      switch (node) {
        case CatalogLeaf(:var entry):
          here.add(entry);
        case CatalogBranch(:var label, :var children):
          // Depth-first, and the branch's own leaves are emitted *before*
          // recursing so a section's entries appear in the order the tree
          // draws them.
          walk(children, path == null ? label : '$path / $label');
      }
    }
    if (here.isEmpty) return;
    if (path == null) {
      loose.addAll(here);
    } else {
      sections.add(
        PreviewSheetSection(
          label: path,
          entries: here,
          pictureRatio: ratioOf(here),
        ),
      );
    }
  }

  walk(tree, null);
  if (loose.isNotEmpty) {
    sections.add(
      PreviewSheetSection(
        label: rootLabel,
        entries: loose,
        pictureRatio: ratioOf(loose),
      ),
    );
  }
  return sections;
}

/// What separates the ungrouped entries from the last headed section.
class _RootRule extends StatelessWidget {
  const _RootRule();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.lg,
      FwSpacing.xs,
      FwSpacing.lg,
      FwSpacing.lg,
    ),
    child: Divider(height: 1, thickness: 1, color: context.colors.line),
  );
}

/// A section's heading, pinned while that section is on screen.
///
/// **Sticky because it is the only thing that says where you are.** A contact
/// sheet is a wall of small pictures with a name under each; scrolled a page
/// into it, nothing on screen answers "which component am I looking at" unless
/// the heading came with you.
///
/// A readout and not a control. Moving between sections is the tree's job —
/// it is already a list of exactly these headings, folded, with their counts —
/// and a second way to do it here would be a second thing to find.
class _PinnedHeading extends SliverPersistentHeaderDelegate {
  const _PinnedHeading(this.label);

  final String label;

  @override
  double get minExtent => PreviewSheet._headingHeight;

  @override
  double get maxExtent => PreviewSheet._headingHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    // Opaque, or the tiles scroll through the words.
    return Container(
      color: context.colors.bg,
      height: PreviewSheet._headingHeight,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: context.type.sectionLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedHeading old) => old.label != label;
}

/// How much of a problem a tile's tooltip carries. The popover's own cap.
const _problemLines = 6;

/// [text]'s first [lines] lines, marked as cut when there were more.
String _cap(String text, int lines) {
  var kept = text.trimRight().split('\n');
  if (kept.length <= lines) return kept.join('\n');
  return '${kept.take(lines).join('\n')}\n…';
}

/// One entry: the box its picture will fill, and its name under it.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.entry,
    required this.screen,
    required this.bytes,
    required this.problem,
    required this.wait,
    required this.width,
    required this.height,
    required this.selected,
    required this.onUndecodable,
    required this.onTap,
  });

  final CatalogEntry entry;
  final Size? screen;

  /// The picture, encoded, or null while there is none to draw.
  final Uint8List? bytes;

  /// What the entry said instead of rendering, if it said anything.
  final String? problem;

  /// What this tile is waiting for, or null when it is waiting for nothing.
  final PreviewTileWait? wait;

  /// The cell's width, and the height its section gives a picture.
  final double width;
  final double height;

  final bool selected;
  final void Function(CatalogEntry entry)? onUndecodable;
  final VoidCallback? onTap;

  /// What an entry under no canvas is drawn as. The plain rectangle has no
  /// declared size — it is whatever the stage is — so the sheet picks the
  /// shape a desktop panel has and stays consistent about it.
  static const plainAspect = 4 / 3;

  /// What fills the reserved box: the picture, a mark, or nothing yet.
  ///
  /// Nothing yet is the common case for the length of a first render, and it
  /// is deliberately *nothing* rather than a spinner: a page of a hundred and
  /// fifty spinners is a page that looks broken, where a page of empty frames
  /// filling in one by one reads as what it is.
  Widget? _art(BuildContext context) {
    if (bytes case var found?) {
      return Image.memory(
        found,
        fit: BoxFit.cover,
        // The tile is a fraction of the frame's size and the decoder can
        // resample as it reads, so this is the difference between a page
        // holding thumbnails and one holding full screenshots.
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        // **Where a truncated cache entry is finally noticed.** Without this
        // the decode failure throws out of paint on every frame and the tile
        // stays blank for ever, because nothing else on the page ever asks the
        // bytes to be an image. Reported after the frame — this runs during
        // one, and the report ends in a `notifyListeners`.
        errorBuilder: (context, error, stack) {
          if (onUndecodable case var report?) {
            SchedulerBinding.instance.addPostFrameCallback(
              (_) => report(entry),
            );
          }
          return Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: 16,
              color: context.colors.mut,
            ),
          );
        },
      );
    }
    if (problem != null) {
      return Center(
        child: Icon(
          Icons.error_outline,
          size: 16,
          color: context.colors.danger,
        ),
      );
    }
    // A shimmer is a *surface treatment*, not a control, and that is what makes
    // it survive the no-spinner rule: a hundred and fifty of them read as one
    // page loading, where a hundred and fifty spinners read as a hundred and
    // fifty problems.
    //
    // Only the two waits that are worth a treatment. A queued tile is seconds
    // away and stays the flat reserved box it already was — the whole point of
    // telling the waits apart is that one of them is not news.
    // Both bands are translucent rather than a second flat tone, which is what
    // makes them read the same way in either theme: the tile's ground is a
    // near-white in one and a slate in the other, and a fixed colour that
    // showed against one would vanish into the other.
    var colors = context.colors;
    return switch (wait) {
      PreviewTileWait.compiling => _Shimmer(
        of: context,
        highlight: colors.mut3.withValues(alpha: 0.45),
      ),
      PreviewTileWait.rendering => _Shimmer(
        of: context,
        highlight: colors.accent.withValues(alpha: 0.28),
      ),
      PreviewTileWait.queued || null => null,
    };
  }

  /// [box] under a tooltip, when there is something to say about why it is red.
  ///
  /// **The whole box, not the mark inside it.** The tile drew the mark and the
  /// red border and said nothing else, so the words the store already had —
  /// *the harness returned nothing for this entry*, a compiler diagnostic —
  /// were reachable only by hovering the row in the tree beside it, which is
  /// not where anybody looking at a red tile is pointing.
  ///
  /// Capped at [_problemLines], the way the popover caps it: a diagnostic runs
  /// to dozens of lines and a tooltip is a glance. Opening the entry is where
  /// the whole of it is.
  Widget _explained(Widget box) => switch (problem) {
    var reason? => Tooltip(message: _cap(reason, _problemLines), child: box),
    null => box,
  };

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var radius = BorderRadius.circular(context.radii.radiusSmall);
    var aspect = screen == null ? plainAspect : screen!.width / screen!.height;
    // Fitted into the box the section decided rather than filling it: a section
    // can hold two shapes — one file's phone variant beside its desktop one —
    // and the odd one out letterboxes rather than stretching.
    var pictureWidth = aspect * height < width ? aspect * height : width;
    var pictureHeight = pictureWidth / aspect;

    return RepaintBoundary(
      child: Tappable.builder(
        onTap: onTap,
        borderRadius: radius,
        feedback: TapFeedback.overlay,
        builder: (context, hovered) => DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? colors.accentSoft : null,
            borderRadius: radius,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: height,
                child: Center(
                  child: _explained(
                    Container(
                      width: pictureWidth,
                      height: pictureHeight,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: colors.line2,
                        borderRadius: radius,
                        border: Border.all(
                          // The rendering mark is a hairline in the accent and
                          // the selection is two pixels of it over a tinted
                          // fill, so the two never read as each other — and a
                          // tile can honestly be both.
                          color: problem != null
                              ? colors.danger
                              : selected || wait == PreviewTileWait.rendering
                              ? colors.accent
                              : colors.line,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: _art(context),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: PreviewSheet._labelHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
                  child: Text(
                    entry.name,
                    style: context.type.caption.copyWith(
                      color: selected ? colors.accentDark : colors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Carries the sheet's one ticker down to the tiles that shimmer.
///
/// A plain inherited widget rather than an [InheritedNotifier]: a notifier
/// rebuilds its *dependents* on every tick, which for this tree is a hundred
/// and fifty tile rebuilds per frame — the exact cost the single controller
/// exists to avoid. What is handed down is the animation itself, whose identity
/// never changes, so nothing rebuilds after mount and the painting is driven
/// through `repaint` instead.
class _ShimmerScope extends InheritedWidget {
  const _ShimmerScope({required this.animation, required super.child});

  final Animation<double> animation;

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.animation;

  @override
  bool updateShouldNotify(_ShimmerScope old) => old.animation != animation;
}

/// A highlight sweeping across the box a picture will fill.
class _Shimmer extends StatelessWidget {
  _Shimmer({required BuildContext of, required this.highlight})
    : animation = _ShimmerScope.maybeOf(of);

  final Animation<double>? animation;

  /// The colour of the band that travels. The ground under it is the tile's
  /// own, which is already painted.
  final Color highlight;

  @override
  Widget build(BuildContext context) {
    var animation = this.animation;
    // A sheet mounted outside the scope — a test, or a future caller — draws
    // the plain reserved box rather than throwing. There is nothing to animate
    // and that is a legible state.
    if (animation == null) return const SizedBox.expand();
    return CustomPaint(
      painter: _ShimmerPainter(animation: animation, highlight: highlight),
      size: Size.infinite,
    );
  }
}

/// **A painter and not a builder.** Repainting on `repaint` skips the build
/// phase entirely, so a page of shimmering tiles costs one layout, no rebuilds,
/// and a gradient per pending tile per frame — and each tile is already inside
/// its own [RepaintBoundary].
class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter({required this.animation, required this.highlight})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    // Starts and ends off the box, so the band enters from one edge and leaves
    // by the other rather than appearing in the middle.
    var x = size.width * (animation.value * 2.4 - 0.7);
    var band = size.width * 0.55;
    var paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(x - band, 0),
        Offset(x + band, size.height),
        [
          highlight.withValues(alpha: 0),
          highlight,
          highlight.withValues(alpha: 0),
        ],
        const [0.0, 0.5, 1.0],
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.highlight != highlight;
}
