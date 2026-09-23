import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/translations.dart';
import 'package:path/path.dart' as p;

import '../../address/address_scope.dart';
import '../../translations/row.dart';
import '../../ui/design/design.dart';
import '../../ui/empty_state.dart';
import '../../ui/error_state.dart';
import '../../ui/menu.dart';
import '../../ui/popover.dart';
import '../../ui/tappable.dart';
import '../native_plugin.dart';
import 'no_packages.dart';
import 'translations_address.dart';
import 'translations_core.dart';

export 'translations_core.dart' show TranslationsCore, translationsPluginId;

/// The GUI half of the translations plugin: **one table**, not a wall of
/// findings.
///
/// Rows are the keys, and each carries the source text, one target language,
/// and a crop of the string where it actually rendered. Five separate finding
/// lists were designed and cut: a suite that already fails on real overflow
/// says everything about overflow, and a list of every key a run never reached
/// is a coverage number rather than a worklist. What survived is two filters
/// over the same rows, which is why this panel has no tabs.
///
/// It is useful before anything has run. The catalog files fill every
/// column but the picture, so the first open shows the whole product's strings
/// and which languages are behind — and the export becomes something you
/// choose rather than a toll you pay before the tab does anything.
class TranslationsPlugin extends NativePlugin<TranslationsCore> {
  TranslationsPlugin(super.core);

  @override
  Widget buildPanel(BuildContext context) =>
      _Shots(read: core.source.readShot, child: _TranslationsPanel(this));
}

/// Where the pictures below are read from — the core's source, put in the
/// tree once so a cell three widgets down does not have to be handed it.
///
/// Re-provided inside [_FullScreenShot]'s dialog, which is built above the
/// panel: a dialog's context sees the app, not the panel that opened it.
class _Shots extends InheritedWidget {
  const _Shots({required this.read, required super.child});

  final Future<Uint8List?> Function(String path) read;

  static _Shots of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Shots>()!;

  @override
  bool updateShouldNotify(_Shots old) => old.read != read;
}

/// The height every control in the filter row shares — the field, the language
/// switch and the chips. One number, because three that nearly agree read as a
/// misalignment rather than as a rhythm.
const _controlHeight = 32.0;

/// How tall a table row is. The separator belongs at the *bottom* of this, so
/// the row that owns it fills it — a cell shorter than the extent drew its own
/// border partway up and the table looked striped through the middle.
const _rowHeight = 44.0;

/// How wide the in-place crop is. Wider than it first looks like it needs to
/// be, because the crop fits the *whole* string: every point here is a point a
/// long sentence does not have to shrink by.
const _cropWidth = 168.0;

/// The max-length cell — `≥ 120 ch` at caption size, with room to spare.
const _maxLengthWidth = 76.0;

class _TranslationsPanel extends StatefulWidget {
  const _TranslationsPanel(this.plugin);

  final TranslationsPlugin plugin;

  @override
  State<_TranslationsPanel> createState() => _TranslationsPanelState();
}

class _TranslationsPanelState extends State<_TranslationsPanel> {
  TranslationsCore get _core => widget.plugin.core;

  final _search = TextEditingController();
  String _query = '';
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (_search.text != _query) setState(() => _query = _search.text);
    });
    _track();
  }

  @override
  void didUpdateWidget(covariant _TranslationsPanel old) {
    super.didUpdateWidget(old);
    // A config reload swaps the core underneath a mounted panel, and a panel
    // that only tracked in initState would go permanently cold.
    _track();
  }

  void _track() {
    for (var path in _core.packages) {
      _core.track(path);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The place the address names, or the first declared package when it names
  /// none — where selecting the plugin off the rail leaves you.
  TranslationPlace? _resolve() {
    var place = translationPlace(
      AddressScope.segments(context),
      locale: AddressScope.param(context, 'locale'),
      filter: AddressScope.param(context, 'filter'),
    );
    if (place != null && _core.packages.contains(place.package)) return place;
    var package = _core.packages.isEmpty ? null : _core.packages.first;
    return package == null
        ? null
        : TranslationPlace(
            package,
            locale: place?.locale,
            filter: place?.filter ?? TranslationFilter.all,
          );
  }

  void _go(TranslationPlace place) => AddressScope.of(context).go(
    _core.addressFor(
      place.package,
      catalog: place.catalog,
      key: place.key,
      locale: place.locale,
      filter: place.filter,
    ),
  );

  Future<void> _export(String package) async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      await _core.export({
        'package': package,
        if (_core.measureOnExport(package)) 'max-lengths': 'true',
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Rebuilds when the catalogs land: the core notifies, the plugin
  /// forwards. Without it the first frame — parsed nothing yet — is the only
  /// frame, and the table reads as an empty project.
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.plugin,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    if (_core.packages.isEmpty) {
      return const NoPackagesConfigured(icon: Icons.translate_outlined);
    }
    var place = _resolve();
    if (place == null) {
      return const NoPackagesConfigured(icon: Icons.translate_outlined);
    }
    if (_core.failureFor(place.package) case var failure?) {
      return ErrorState(
        title: 'The catalogs could not be read',
        message: failure,
      );
    }

    var template = _core.templateFor(place.package);
    var locales = _core.localesFor(place.package);
    // The template is never a comparison against itself, so the switch starts
    // on the first language that could actually be behind.
    var locale =
        place.locale ??
        locales.firstWhere((it) => it != template, orElse: () => template);
    var rows = _core.rowsFor(place.package);
    var shown = [
      for (var row in rows)
        if (row.matches(_query) && _passes(row, locale, place.filter)) row,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Strip(
          core: _core,
          place: place,
          rows: rows,
          exporting: _exporting,
          onExport: () => _export(place.package),
        ),
        if (_error case var error?) _ErrorBar(error),
        if (_core.exportFor(place.package) == null && !_exporting)
          _NoExportYet(onExport: () => _export(place.package))
        else if (_core.untracedFor(place.package))
          _NothingTraced(
            catalog:
                _core.catalogsFor(place.package)?.keys.firstOrNull ?? 'app',
          ),
        _Filters(
          search: _search,
          locales: locales,
          locale: locale,
          template: template,
          rows: rows,
          place: place,
          exported: _core.exportFor(place.package) != null,
          probed: _core.measuredMaxLengthsFor(place.package),
          onChanged: _go,
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.search_off_outlined,
                  title: 'Nothing matches',
                  message: _query.isEmpty
                      ? 'No key is in this state.'
                      : 'No key or text contains "$_query".',
                )
              : _Table(
                  core: _core,
                  place: place,
                  rows: shown,
                  locale: locale,
                  template: template,
                  exported: _core.exportFor(place.package) != null,
                  onOpen: _go,
                ),
        ),
      ],
    );
  }

  bool _passes(TranslationRow row, String locale, TranslationFilter filter) =>
      switch (filter) {
        TranslationFilter.all => true,
        TranslationFilter.missing => row.missingIn(locale),
        TranslationFilter.noPicture => !row.hasPicture,
        TranslationFilter.fragile => row.fragile,
      };
}

/// The summary and the one control.
///
/// It carries the export button because the button's result is the numbers
/// beside it — a glance surface may only hold controls whose effect is visible
/// on it.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.core,
    required this.place,
    required this.rows,
    required this.exporting,
    required this.onExport,
  });

  final TranslationsCore core;
  final TranslationPlace place;
  final List<TranslationRow> rows;
  final bool exporting;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var withPicture = rows.length - core.withoutPictureFor(place.package);
    var exportedAt = core.exportedAt(place.package);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.xl,
        children: [
          Text('Translations', style: context.type.bodyStrong),
          // One Expanded around both readings, so the free space lands *here*
          // and the control below is pushed to the edge. A Flexible per text
          // eats the row's slack between them, and then a Spacer has none
          // left to give — which is how the button came to sit mid-row.
          Expanded(
            child: Row(
              spacing: FwSpacing.xl,
              children: [
                Flexible(
                  child: Text(
                    '${rows.length} keys · '
                    '${core.localesFor(place.package).length} languages · '
                    '$withPicture with a picture',
                    style: context.type.bodyMuted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (exportedAt != null)
                  Flexible(
                    child: Text(
                      'Exported ${_ago(exportedAt)}',
                      style: context.type.bodyMuted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          if (exporting)
            _Running(
              phrase: core.busyFor(place.package) ?? 'running the scenarios',
              progress: core.progressFor(place.package),
            )
          else
            _ExportSplitButton(
              measure: core.measureOnExport(place.package),
              onExport: onExport,
              onToggleMeasure: () => core.setMeasureOnExport(
                place.package,
                !core.measureOnExport(place.package),
              ),
            ),
        ],
      ),
    );
  }
}

/// What the Export button turns into while it runs.
///
/// A bar, because an export is minutes rather than seconds: the suite runs
/// once per locale, and measuring max lengths runs it again per rung of the
/// ladder. A spinner held that long says only that the app has not crashed.
///
/// The bar fills once per **pass** and the phrase says which pass — there is
/// no honest denominator for the whole export, because the ladder stops as
/// soon as every measurable key has clipped and nobody knows when that is
/// until it happens. Indeterminate until the scan that supplies the
/// denominator lands, which is a beat after the first pass starts.
class _Running extends StatelessWidget {
  const _Running({required this.phrase, required this.progress});

  final String phrase;
  final ({int done, int? total})? progress;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var total = progress?.total;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.md,
      children: [
        SizedBox(
          width: 96,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: total == null || total == 0
                  ? null
                  : (progress!.done / total).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: colors.line,
              color: colors.accent,
            ),
          ),
        ),
        // Flexible, because a measuring pass says the longest of these —
        // "measuring max lengths — photographing +40% · 12 of 46 scenarios" —
        // and the strip is as wide as the window is.
        Flexible(
          child: Text(
            total == null
                ? phrase
                : '$phrase · ${progress!.done} of $total scenarios',
            style: context.type.bodyMuted,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The Export button with its one choice behind the chevron.
///
/// Same anatomy as the scenario panel's Run button: the primary segment runs
/// with whatever is ticked, the arrow holds the rare toggle. The label says
/// which export a click will run — a primary that silently measures (or
/// silently stops measuring) would make both the cost and the result a
/// surprise, and measuring takes minutes where plain export takes seconds.
class _ExportSplitButton extends StatelessWidget {
  const _ExportSplitButton({
    required this.measure,
    required this.onExport,
    required this.onToggleMeasure,
  });

  final bool measure;
  final VoidCallback onExport;

  /// Remembered by the core per package — see
  /// `TranslationsCore.measureOnExport`.
  final VoidCallback onToggleMeasure;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var fg = colors.onPrimary;
    return Container(
      height: 32,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: measure
                ? 'Re-run the suite, then measure how long every string '
                      'can get — several extra passes'
                : 'Re-run the suite and refresh the pictures',
            child: Tappable(
              onTap: onExport,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
                child: Text(
                  measure ? 'Export + measure' : 'Export',
                  style: context.type.button.copyWith(color: fg),
                ),
              ),
            ),
          ),
          Container(width: 1, color: fg.withValues(alpha: 0.3)),
          Menu(
            align: PopoverAlign.end,
            entries: [
              MenuItem(
                'Measure max lengths',
                icon: measure
                    ? Icons.check_box_outlined
                    : Icons.check_box_outline_blank,
                onSelected: onToggleMeasure,
              ),
            ],
            builder: (context, controller) => Tooltip(
              message: 'Export options',
              child: Tappable(
                onTap: controller.toggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
                  child: Icon(
                    Icons.arrow_drop_down,
                    size: FwIconSize.lg,
                    color: fg,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.xl,
      vertical: FwSpacing.lg,
    ),
    color: context.colors.red.withValues(alpha: .12),
    child: SelectableText(message, style: context.type.bodySmall),
  );
}

/// The state that decides whether anyone opens this tab twice.
///
/// It says what the table below already *is* — everything but the pictures —
/// so the run reads as an addition rather than a precondition.
class _NoExportYet extends StatelessWidget {
  const _NoExportYet({required this.onExport});

  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: colors.amber.withValues(alpha: .10),
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          Icon(
            Icons.photo_camera_outlined,
            size: FwIconSize.sm,
            color: colors.amber,
          ),
          Expanded(
            child: Text(
              'No export yet. The table is read straight from your catalog '
              'files — running the export adds a picture of each string in '
              'place, and a folder you can send a translator.',
              style: context.type.bodySmall,
            ),
          ),
          TextButton(
            onPressed: onExport,
            child: const Text('Export screenshots'),
          ),
        ],
      ),
    );
  }
}

/// An export that ran and traced nothing.
///
/// The state that costs the most time to diagnose without help: the run
/// succeeded, the frames are on disk, and every row says "No picture" — which
/// reads as a coverage problem, so the next hour goes on scenarios that were
/// never the problem. The seam is what is missing, and it is one line.
class _NothingTraced extends StatelessWidget {
  const _NothingTraced({required this.catalog});

  /// A declared catalog's name, so the snippet is this project's rather than
  /// the documentation's.
  final String catalog;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: colors.amber.withValues(alpha: .10),
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          Icon(
            Icons.link_off_outlined,
            size: FwIconSize.sm,
            color: colors.amber,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: FwSpacing.xs,
              children: [
                Text(
                  'The export ran, but nothing asked a catalog for a string — '
                  'so no picture could be attached to a key. The seam is not '
                  'wired.',
                  style: context.type.bodySmall,
                ),
                SelectableText(
                  "indexTranslations('$catalog')(key, value)",
                  style: context.type.mono.copyWith(color: colors.mut),
                ),
                Text(
                  'Hand that to whatever your app already funnels its '
                  "translation reads through, in the scenarios' test setup, "
                  'and the next export fills the column in.',
                  style: context.type.bodySmall.copyWith(color: colors.mut),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Search, the language switch, and the two filters that survived.
class _Filters extends StatelessWidget {
  const _Filters({
    required this.search,
    required this.locales,
    required this.locale,
    required this.template,
    required this.rows,
    required this.place,
    required this.exported,
    required this.probed,
    required this.onChanged,
  });

  final TextEditingController search;
  final List<String> locales;
  final String locale;
  final String template;
  final List<TranslationRow> rows;
  final TranslationPlace place;

  /// Whether an export exists. Before one, "no picture" is every key and says
  /// only that nothing has run — so the filter is not offered rather than
  /// offered and useless.
  final bool exported;

  /// Whether the last export measured max lengths. Gates the fragile filter
  /// the way [exported] gates the picture one: an unprobed table offering
  /// "fragile: 0" would read as room where nothing was measured.
  final bool probed;

  final ValueChanged<TranslationPlace> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var missing = rows.where((row) => row.missingIn(locale)).length;
    var noPicture = rows.where((row) => !row.hasPicture).length;
    var fragile = rows.where((row) => row.fragile).length;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.md,
        children: [
          // **Built like the switch beside it, not out of InputDecoration.**
          // A Material field brings its own intrinsic height and its own
          // padding, and squeezing that into the row's height left the text in
          // a thin slot inside a border that was drawn at a different size.
          // The border and the box are ours here, and the field inside them is
          // just the text — so the two controls are the same shape because
          // they are made the same way.
          _SearchField(controller: search),
          // The switch, not a column per language. Three fit across; ten do
          // not, and every project grows toward ten.
          _LocaleSwitch(
            locales: locales,
            locale: locale,
            template: template,
            onChanged: (it) => onChanged(
              TranslationPlace(
                place.package,
                catalog: place.catalog,
                key: place.key,
                locale: it,
                filter: place.filter,
              ),
            ),
          ),
          const Spacer(),
          for (var filter in TranslationFilter.values)
            if ((exported || filter != TranslationFilter.noPicture) &&
                (probed || filter != TranslationFilter.fragile))
              _Chip(
                label: switch (filter) {
                  TranslationFilter.all => 'All',
                  TranslationFilter.missing => 'Missing in $locale',
                  TranslationFilter.noPicture => 'No picture',
                  TranslationFilter.fragile => 'Fragile',
                },
                count: switch (filter) {
                  TranslationFilter.all => rows.length,
                  TranslationFilter.missing => missing,
                  TranslationFilter.noPicture => noPicture,
                  TranslationFilter.fragile => fragile,
                },
                warn: filter != TranslationFilter.all,
                selected: place.filter == filter,
                onTap: () => onChanged(
                  TranslationPlace(
                    place.package,
                    catalog: place.catalog,
                    key: place.key,
                    locale: place.locale,
                    filter: filter,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// The filter row's search box.
///
/// Every border state is cleared, not just `border`. The app's theme sets
/// `enabledBorder` and `focusedBorder` in its `inputDecorationTheme`, and those
/// win over `border` — so a field asked politely for no border still drew one
/// inside the box around it, and lit it blue on focus. Two borders, one of them
/// ours.
///
/// The focus ring moved out here with them: one box, which is the thing that
/// responds.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: 220,
      height: _controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(
          color: _focus.hasFocus ? colors.accent : colors.line,
        ),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Row(
        spacing: FwSpacing.md,
        children: [
          Icon(Icons.search, size: FwIconSize.xs, color: colors.mut2),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              style: context.type.bodySmall,
              cursorHeight: 14,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                hintText: 'Search keys and text',
                hintStyle: context.type.bodyMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocaleSwitch extends StatelessWidget {
  const _LocaleSwitch({
    required this.locales,
    required this.locale,
    required this.template,
    required this.onChanged,
  });

  final List<String> locales;
  final String locale;
  final String template;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MenuAnchor(
      menuChildren: [
        for (var it in locales)
          MenuItemButton(
            onPressed: () => onChanged(it),
            leadingIcon: Icon(
              it == locale ? Icons.check : null,
              size: FwIconSize.sm,
              color: colors.accent,
            ),
            child: Text(
              it == template ? '$it · source' : it,
              style: context.type.body,
            ),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Which language is shown beside the source text',
        child: Tappable(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Container(
            height: _controlHeight,
            padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
            decoration: BoxDecoration(
              color: colors.bg,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: Row(
              spacing: FwSpacing.sm,
              children: [
                // **Both languages, with the arrow between them.** The left
                // column of the table is always the source and the right one
                // is whatever this picks; a lone `fr` named a language without
                // saying what the control was for.
                //
                // Unless they are the same, when there is no second column and
                // `en → en` would be an arrow pointing at itself.
                if (locale == template)
                  Text('$template · source', style: context.type.bodySmall)
                else ...[
                  Text(
                    template,
                    style: context.type.bodySmall.copyWith(color: colors.mut),
                  ),
                  Icon(
                    Icons.arrow_right_alt,
                    size: FwIconSize.xs,
                    color: colors.mut2,
                  ),
                  Text(locale, style: context.type.bodySmall),
                ],
                Icon(
                  Icons.expand_more,
                  size: FwIconSize.xs,
                  color: colors.mut2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.warn,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final bool warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        height: _controlHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : colors.bg,
          border: Border.all(color: selected ? colors.accent : colors.line),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          spacing: FwSpacing.sm,
          children: [
            Text(
              label,
              style: context.type.bodySmall.copyWith(
                color: selected ? colors.accent : colors.ink2,
              ),
            ),
            Text(
              '$count',
              style: context.type.bodySmall.copyWith(
                color: selected
                    ? colors.accent
                    : (warn && count > 0 ? colors.amber : colors.mut),
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The table, and the open row's detail beside it.
class _Table extends StatelessWidget {
  const _Table({
    required this.core,
    required this.place,
    required this.rows,
    required this.locale,
    required this.template,
    required this.exported,
    required this.onOpen,
  });

  final TranslationsCore core;
  final TranslationPlace place;
  final List<TranslationRow> rows;
  final String locale;
  final String template;
  final bool exported;
  final ValueChanged<TranslationPlace> onOpen;

  @override
  Widget build(BuildContext context) {
    var open = place.id == null
        ? null
        : rows.where((row) => row.id == place.id).firstOrNull;
    var directory = core.exportDirectoryFor(place.package);
    var list = _List(
      rows: rows,
      locale: locale,
      template: template,
      directory: directory,
      selected: place.id,
      exported: exported,
      probed: core.measuredMaxLengthsFor(place.package),
      compact: open != null,
      onOpen: (row) => onOpen(
        TranslationPlace(
          place.package,
          catalog: row.catalog,
          key: row.key,
          locale: place.locale,
          filter: place.filter,
        ),
      ),
    );
    if (open == null) return list;
    return Row(
      children: [
        Expanded(flex: 5, child: list),
        Container(width: 1, color: context.colors.line),
        Expanded(
          flex: 4,
          child: _Detail(
            row: open,
            locale: locale,
            template: template,
            directory: directory,
            onClose: () => onOpen(
              TranslationPlace(
                place.package,
                locale: place.locale,
                filter: place.filter,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.rows,
    required this.locale,
    required this.template,
    required this.directory,
    required this.selected,
    required this.exported,
    required this.probed,
    required this.compact,
    required this.onOpen,
  });

  final List<TranslationRow> rows;
  final String locale;
  final String template;
  final String directory;
  final String? selected;

  /// The picture column is what the export adds, so before one there is no
  /// column. Fourteen identical "no picture" boxes are a wall that says
  /// exactly what the banner above already said, and they push the words a
  /// person came to read off to the right.
  final bool exported;

  /// The max-length column is what a probe adds — same rule as [exported].
  final bool probed;

  final bool compact;
  final ValueChanged<TranslationRow> onOpen;

  @override
  Widget build(BuildContext context) {
    var showTarget = locale != template;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderRow(
          template: template,
          locale: locale,
          showTarget: showTarget && !compact,
          showPicture: exported,
          showBudget: probed && !compact,
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemExtent: _rowHeight,
            itemBuilder: (context, index) => _Row(
              row: rows[index],
              locale: locale,
              template: template,
              directory: directory,
              selected: rows[index].id == selected,
              showTarget: showTarget && !compact,
              showPicture: exported,
              showBudget: probed && !compact,
              onTap: () => onOpen(rows[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.template,
    required this.locale,
    required this.showTarget,
    required this.showPicture,
    required this.showBudget,
  });

  final String template;
  final String locale;
  final bool showTarget;
  final bool showPicture;
  final bool showBudget;

  @override
  Widget build(BuildContext context) {
    var style = context.type.caption.copyWith(color: context.colors.mut2);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.md,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          if (showPicture)
            SizedBox(
              width: _cropWidth,
              child: Text('In place', style: style),
            ),
          SizedBox(width: 190, child: Text('Key', style: style)),
          Expanded(child: Text(template, style: style)),
          if (showTarget) Expanded(child: Text(locale, style: style)),
          if (showBudget)
            SizedBox(
              width: _maxLengthWidth,
              child: Text('Max length', style: style),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.locale,
    required this.template,
    required this.directory,
    required this.selected,
    required this.showTarget,
    required this.showPicture,
    required this.showBudget,
    required this.onTap,
  });

  final TranslationRow row;
  final String locale;
  final String template;
  final String directory;
  final bool selected;
  final bool showTarget;
  final bool showPicture;
  final bool showBudget;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        // Filled to the row's full height, so the border it draws is the row's
        // edge. Sized to its tallest child instead, it drew a line partway up
        // the extent and the table read as striped.
        height: _rowHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xl),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : null,
          border: Border(bottom: BorderSide(color: colors.line2)),
        ),
        child: Row(
          spacing: FwSpacing.lg,
          children: [
            if (showPicture)
              SizedBox(
                width: _cropWidth,
                child: _InPlace(row: row, directory: directory),
              ),
            SizedBox(
              width: 190,
              child: Text(
                row.key,
                style: context.type.mono.copyWith(
                  color: selected ? colors.accent : colors.ink,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(child: _Value(row.valueIn(template), missing: false)),
            if (showTarget)
              Expanded(
                child: _Value(
                  row.valueIn(locale),
                  missing: row.missingIn(locale),
                ),
              ),
            if (showBudget)
              SizedBox(
                width: _maxLengthWidth,
                child: _MaxLengthCell(row, locale: locale),
              ),
          ],
        ),
      ),
    );
  }
}

/// The evidence, as one sentence: what fit, what clipped, where, and — when a
/// translation is already over the limit — who is over.
String _maxLengthSentence(ExportedMaxLength measured, List<String> over) {
  var where = switch (measured.screen) {
    var screen? =>
      ' on ${screen.step}'
          '${measured.measuredOn == null ? '' : ' (${measured.measuredOn})'}',
    _ => '',
  };
  var base = measured.bounded
      ? 'Measured: ${measured.chars} characters fit$where; '
            '${measured.clipsChars} were cut off.'
      : 'Measured: at least ${measured.chars} characters fit$where — '
            'nothing tried was long enough to clip.';
  if (over.isEmpty) return base;
  return '$base The ${over.join(', ')} text is already longer than the limit.';
}

/// The max-length cell: the proven characters, in one glance.
///
/// `≤ N ch` for a real limit, `≥ N ch` muted for an open bound, blank for
/// unmeasured — blank must never read as room. Amber is reserved for the one
/// state that demands action: a translation that already exceeds the limit.
class _MaxLengthCell extends StatelessWidget {
  const _MaxLengthCell(this.row, {required this.locale});

  final TranslationRow row;
  final String locale;

  @override
  Widget build(BuildContext context) {
    var measured = row.maxLength;
    if (measured == null) return const SizedBox.shrink();
    var colors = context.colors;
    var exceeded = row.overLimit([locale]).isNotEmpty;
    return Text(
      measured.bounded ? '≤ ${measured.chars} ch' : '≥ ${measured.chars} ch',
      style: context.type.caption.copyWith(
        color: exceeded
            ? colors.amber
            : measured.bounded
            ? colors.ink
            : colors.mut3,
      ),
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.value, {required this.missing});

  final String? value;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    if (missing || value == null || value!.isEmpty) {
      return Text(
        '—',
        style: context.type.bodySmall.copyWith(
          color: missing ? context.colors.amber : context.colors.mut3,
        ),
      );
    }
    return Text(
      value!,
      style: context.type.bodySmall,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The string where it actually rendered — the only thing on the row that
/// shows a user's view of it.
///
/// A crop, and only here. The export ships whole frames because that is
/// what a translation service takes; a row is 44 pixels tall and a whole phone
/// in it is a smudge. Same rectangle, two renderings.
class _InPlace extends StatelessWidget {
  const _InPlace({required this.row, required this.directory});

  final TranslationRow row;
  final String directory;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var shot = row.shot;
    if (shot == null || shot.rect == null) {
      return Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: colors.line2, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(
          'No picture',
          style: context.type.micro.copyWith(color: colors.mut3),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        height: 30,
        decoration: BoxDecoration(border: Border.all(color: colors.line)),
        child: CropView(
          path: p.join(directory, shot.image.replaceAll('/', p.separator)),
          rect: shot.rect!,
          // A little air around the words, so the crop reads as a place on a
          // screen rather than as a ransom note.
          padding: 8,
        ),
      ),
    );
  }
}

/// The open row: the whole frame, the box drawn over it, and every other
/// screen the key was seen on.
class _Detail extends StatelessWidget {
  const _Detail({
    required this.row,
    required this.locale,
    required this.template,
    required this.directory,
    required this.onClose,
  });

  final TranslationRow row;
  final String locale;
  final String template;
  final String directory;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var shot = row.shot;
    var others = [
      for (var it in row.occurrences)
        if (it.image != shot?.image || it.stepIndex != shot?.stepIndex) it,
    ];
    return Container(
      color: colors.panel2,
      child: ListView(
        padding: const EdgeInsets.all(FwSpacing.xl),
        children: [
          Row(
            children: [
              Expanded(child: Text(row.id, style: context.type.mono)),
              Tappable(
                onTap: onClose,
                child: Icon(
                  Icons.close,
                  size: FwIconSize.sm,
                  color: colors.mut,
                ),
              ),
            ],
          ),
          if (shot != null)
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.xxs),
              child: Text(
                '${shot.scenario} · ${shot.step}'
                '${shot.device == null ? '' : ' · ${shot.device}'}',
                style: context.type.bodyMuted,
              ),
            ),
          const SizedBox(height: FwSpacing.xl),
          for (var it in row.values.keys)
            _LocaleLine(
              locale: it,
              value: row.valueIn(it),
              template: it == template,
              highlighted: it == locale,
            ),
          if (row.missingIn(locale))
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.md),
              child: Text(
                'Nothing for $locale, so the $template text is what a reader '
                'of that language sees.',
                style: context.type.bodySmall.copyWith(color: colors.amber),
              ),
            ),
          if (row.maxLength case var measured?) ...[
            Padding(
              padding: const EdgeInsets.only(top: FwSpacing.md),
              child: Text(
                _maxLengthSentence(measured, row.overLimit([locale])),
                style: context.type.bodySmall.copyWith(
                  color: row.overLimit([locale]).isNotEmpty
                      ? colors.amber
                      : colors.mut,
                ),
              ),
            ),
            if (measured.clipped case var clipped?)
              Padding(
                padding: const EdgeInsets.only(top: FwSpacing.lg),
                child: SizedBox(
                  width: 220,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Openable(
                        path: p.join(
                          directory,
                          clipped.image.replaceAll('/', p.separator),
                        ),
                        rect: clipped.rect,
                        title:
                            '${row.id} clipping · '
                            '${clipped.scenario} · ${clipped.step}',
                        maxHeight: 260,
                      ),
                      const SizedBox(height: FwSpacing.xs),
                      Text(
                        'The clip, photographed: the padded string cut off '
                        'in place.',
                        style: context.type.micro.copyWith(color: colors.mut),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: FwSpacing.xxl),
          if (shot == null)
            EmptyState(
              icon: Icons.photo_camera_outlined,
              title: 'No picture of this one',
              message:
                  'No scenario in the last export put it on a screen. Either '
                  'nothing covers that screen yet, or nothing uses the key.',
            )
          else ...[
            _Openable(
              path: p.join(directory, shot.image.replaceAll('/', p.separator)),
              rect: shot.rect,
              title: '${row.id} · ${shot.scenario} · ${shot.step}',
              maxHeight: 420,
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: FwSpacing.xxl),
              Text(
                others.length == 1
                    ? 'Also on 1 other screen'
                    : 'Also on ${others.length} other screens',
                style: context.type.sectionLabel,
              ),
              const SizedBox(height: FwSpacing.lg),
              Wrap(
                spacing: FwSpacing.lg,
                runSpacing: FwSpacing.lg,
                children: [
                  for (var it in others)
                    SizedBox(
                      width: 110,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Openable(
                            path: p.join(
                              directory,
                              it.image.replaceAll('/', p.separator),
                            ),
                            rect: it.rect,
                            title: '${row.id} · ${it.scenario} · ${it.step}',
                            maxHeight: 200,
                          ),
                          const SizedBox(height: FwSpacing.xs),
                          Text(
                            '${it.step}${it.locale == null ? '' : ' · ${it.locale}'}',
                            style: context.type.micro.copyWith(
                              color: colors.mut,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _LocaleLine extends StatelessWidget {
  const _LocaleLine({
    required this.locale,
    required this.value,
    required this.template,
    required this.highlighted,
  });

  final String locale;
  final String? value;
  final bool template;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: FwSpacing.lg,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              locale,
              style: context.type.bodySmall.copyWith(
                color: highlighted ? colors.accent : colors.mut2,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value == null || value!.isEmpty ? '—' : value!,
              style: context.type.bodySmall.copyWith(
                color: value == null || value!.isEmpty
                    ? (template ? colors.mut3 : colors.amber)
                    : colors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A framed shot that opens full size when tapped.
class _Openable extends StatelessWidget {
  const _Openable({
    required this.path,
    required this.title,
    required this.maxHeight,
    this.rect,
  });

  final String path;
  final String title;
  final double maxHeight;
  final ExportedRect? rect;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Open full size',
    child: Tappable(
      onTap: () =>
          _FullScreenShot.show(context, path: path, title: title, rect: rect),
      child: _Framed(path: path, rect: rect, maxHeight: maxHeight),
    ),
  );
}

/// The frame, as big as the window allows.
///
/// A screenshot in a side pane is a thumbnail of a phone, and the thing this
/// whole feature exists to show is what a string looks like *in place* — which
/// at 150 points wide is a guess. One tap is the difference between believing
/// the box and reading the screen.
class _FullScreenShot extends StatelessWidget {
  const _FullScreenShot({required this.path, required this.title, this.rect});

  final String path;
  final String title;
  final ExportedRect? rect;

  static void show(
    BuildContext context, {
    required String path,
    required String title,
    ExportedRect? rect,
  }) {
    // Read here, where the panel's [_Shots] is in scope: the dialog's own
    // context is not under it.
    var shots = _Shots.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => _Shots(
          read: shots.read,
          child: _FullScreenShot(path: path, title: title, rect: rect),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Dialog(
      backgroundColor: colors.bg,
      insetPadding: const EdgeInsets.all(FwSpacing.xxl),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: context.type.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Tappable(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.close,
                    size: FwIconSize.sm,
                    color: colors.mut,
                  ),
                ),
              ],
            ),
            const SizedBox(height: FwSpacing.lg),
            Flexible(
              child: Center(
                child: _Framed(path: path, rect: rect, maxHeight: 4000),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A whole frame with the box drawn over it.
///
/// The frame is untouched and the box is geometry — the same arrangement the
/// exported page uses, and the same numbers a translation service is handed.
class _Framed extends StatelessWidget {
  const _Framed({required this.path, this.rect, required this.maxHeight});

  final String path;
  final ExportedRect? rect;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => _DecodedImage(
    path: path,
    builder: (context, image) {
      var width = image.width.toDouble();
      var height = image.height.toDouble();
      return ClipRRect(
        borderRadius: BorderRadius.circular(context.radii.radius),
        child: Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            border: Border.all(color: context.colors.line),
          ),
          child: AspectRatio(
            aspectRatio: width / height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RawImage(image: image, fit: BoxFit.contain),
                if (rect case var rect?)
                  LayoutBuilder(
                    builder: (context, box) => Stack(
                      children: [
                        Positioned(
                          left: rect.x / width * box.maxWidth,
                          top: rect.y / height * box.maxHeight,
                          width: rect.width / width * box.maxWidth,
                          height: rect.height / height * box.maxHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: context.colors.accent,
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Shows one rectangle of an image, whole.
class CropView extends StatelessWidget {
  const CropView({
    super.key,
    required this.path,
    required this.rect,
    this.padding = 0,
  });

  /// The frame, as the panel built it under the export's directory — what
  /// [_Shots] reads.
  final String path;
  final ExportedRect rect;

  /// Image pixels of context kept around [rect] before fitting.
  final double padding;

  @override
  Widget build(BuildContext context) => _DecodedImage(
    path: path,
    builder: (context, image) => CustomPaint(
      painter: _CropPainter(image: image, rect: rect, padding: padding),
      child: const SizedBox.expand(),
    ),
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.rect,
    required this.padding,
  });

  final ui.Image image;
  final ExportedRect rect;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // **The whole string, not a magnified corner of it.** Scale to whichever
    // axis runs out first, so a long sentence shrinks to fit rather than being
    // cut off at the cell's edge — a crop that ends mid-word tells a reader
    // less than the row's own text column already did.
    var wanted = Size(rect.width + padding * 2, rect.height + padding * 2);
    var scale = math.min(
      size.width / wanted.width,
      size.height / wanted.height,
    );

    // Then widen the source back out to the cell's shape at that scale, so the
    // space around the words is filled with the screen they were on rather
    // than with empty bands.
    var source = Size(size.width / scale, size.height / scale);
    var left = (rect.x + rect.width / 2 - source.width / 2)
        .clamp(0.0, math.max(0.0, image.width - source.width))
        .toDouble();
    var top = (rect.y + rect.height / 2 - source.height / 2)
        .clamp(0.0, math.max(0.0, image.height - source.height))
        .toDouble();

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(left, top, source.width, source.height),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.rect != rect || old.padding != padding;
}

/// Decodes the frame at [path] once and hands the result to [builder].
///
/// Cached across the whole panel because **frames are shared**: several keys
/// sit on one screen, and decoding a phone-sized PNG per row is the difference
/// between a table that scrolls and one that stutters. A frame already decoded
/// is handed over in the same frame it is asked for, so scrolling back up does
/// not flash grey.
class _DecodedImage extends StatefulWidget {
  const _DecodedImage({required this.path, required this.builder});

  final String path;
  final Widget Function(BuildContext context, ui.Image image) builder;

  @override
  State<_DecodedImage> createState() => _DecodedImageState();
}

class _DecodedImageState extends State<_DecodedImage> {
  /// Decoded frames, by path.
  static final _decoded = <String, ui.Image>{};

  /// Decodes in flight, so eight rows off one screen decode it once.
  static final _pending = <String, Future<ui.Image?>>{};

  ui.Image? _image;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _DecodedImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _image = null;
      _resolve();
    }
  }

  void _resolve() {
    // Dependencies change more often than the picture does.
    if (_image != null) return;
    var path = widget.path;
    if (_decoded[path] case var ready?) {
      _image = ready;
      return;
    }
    var read = _Shots.of(context).read;
    unawaited(
      (_pending[path] ??= _decode(read, path)).then((image) {
        if (!mounted || image == null) return;
        setState(() => _image = image);
      }),
    );
  }

  static Future<ui.Image?> _decode(
    Future<Uint8List?> Function(String path) read,
    String path,
  ) async {
    try {
      var bytes = await read(path);
      if (bytes == null) return null;
      var image = await decodeImageFromList(bytes);
      _decoded[path] = image;
      return image;
    } catch (_) {
      // A frame that will not decode leaves the cell empty rather than taking
      // the table down. The export's own result already counts frames it could
      // not find, which is the honest place to say so.
      return null;
    } finally {
      _pending.remove(path)?.ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    var image = _image;
    if (image == null) {
      return ColoredBox(color: context.colors.panel, child: const SizedBox());
    }
    return widget.builder(context, image);
  }
}

String _ago(DateTime at) {
  // Through `package:clock`, so a scenario of this panel — the studio's own,
  // over a recording — reads the same age every day it runs.
  var delta = clock.now().difference(at);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
  }
  return '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago';
}
