import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';

import 'package:flutterware/store_report.dart';

import '../../address/address_scope.dart';
import '../../store/ui/set_card.dart';
import '../../store/viewers.dart';
import '../../store/tree.dart';
import '../../ui/age.dart';
import '../../ui/design/design.dart';
import '../../ui/empty_state.dart';
import '../../ui/menu.dart';
import '../../ui/tappable.dart';
import '../../ui/panel_header.dart';
import '../../ui/split_button.dart';
import '../../ui/theme.dart';
import '../native_plugin.dart';
import 'no_packages.dart';
import 'store_core.dart';
import 'store_results.dart';

export 'store_core.dart' show StoreCore, storePluginId;

/// An image provider for a path an export's manifest names —
/// `StorePlugin(image: …)`.
typedef StoreImage = ImageProvider Function(String path);

/// The listing, as it was last exported.
///
/// **Two truths, and they come from different places.** The *structure* — which
/// listings, which display classes, which locales, what canvas each is — is the
/// declaration, in hand with no I/O. The *pixels* are the last export, read
/// from `StoreShotsReport`. The panel walks the first and looks each set up in the
/// second, which is why there is one layout here rather than an empty screen
/// and a full one: a set with no export draws the same card with placeholders
/// where its shots will be.
///
/// That asymmetry is decision 11 made visible. A source scan would have filled
/// those placeholders with real shot names before the first export, at the cost
/// of a parser tracking two naming spellings forever. What it would have bought
/// is the difference between a card that says *five shots, not yet exported*
/// and one that says *not yet exported* — and the declaration alone already
/// says everything else on the card.
class StorePlugin extends NativePlugin<StoreCore> {
  StorePlugin(super.core, {StoreImage? image}) : image = image ?? _fileImage;

  /// The picture at a path the manifest names — a file of the export tree,
  /// unless a recording is standing in for one.
  final StoreImage image;

  static ImageProvider _fileImage(String path) => FileImage(File(path));

  @override
  Widget buildPanel(BuildContext context) => _StorePanel(this);
}

class _StorePanel extends StatefulWidget {
  const _StorePanel(this.plugin);

  final StorePlugin plugin;

  @override
  State<_StorePanel> createState() => _StorePanelState();
}

class _StorePanelState extends State<_StorePanel> {
  bool _running = false;

  /// What the last run said, and which app it was about — null for a run over
  /// all of them. Kept with its app so that moving to another one does not
  /// carry "12 images written" onto a page that wrote none.
  ({String? app, String text})? _outcome;

  /// The **app's** locale, not the store's slot, because that is what the
  /// declaration spells and what the reader typed. Null until the declaration
  /// is read, then the first one declared.
  String? _locale;

  StoreCore get _core => widget.plugin.core;

  List<String> _localesOf(StoreShotsApp app) =>
      {for (var listing in app.listings) ...listing.locales.keys}.toList();

  /// Runs [action] for [app], or for every declared app when it is null.
  Future<void> _run(
    String action, {
    String? app,
    Map<String, Object?> arguments = const {},
  }) async {
    setState(() {
      _running = true;
      _outcome = null;
    });
    try {
      var result = (await _core.invoke(
        action,
        arguments: {...arguments, 'app': ?app},
      ))!;
      if (!mounted) return;
      setState(() {
        _outcome = switch (result) {
          StoreExportResult(:var count, :var apps) => (
            app: app,
            text:
                apps.map((a) => a.error).nonNulls.firstOrNull ??
                '$count ${count == 1 ? 'image' : 'images'} written',
          ),
          _ => null,
        };
      });
    } catch (error) {
      if (mounted) setState(() => _outcome = (app: app, text: '$error'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The one-click export of the app on screen, with the narrowed forms
  /// behind the chevron.
  ///
  /// **Capture and framing are one thing here**, and the menu says nothing
  /// about the split. It carried a *Re-frame existing screenshots* entry for a
  /// while — the second pass, offered on its own — and it was two things at
  /// once: obscure, because nobody thinks of a listing as two passes, and
  /// barely worth it, because moving the PNG codec off the main isolate took a
  /// full export from ~48s to ~26s against a recompose's ~17s. A menu entry
  /// that asks the reader to learn the internals to save nine seconds is a
  /// menu entry that should not be there.
  ///
  /// The per-store entries are this app's listings rather than both stores:
  /// an app declaring one store was offered the other, and with one declared
  /// the plain Export already is that export.
  Widget _exportButton(
    StoreShotsApp app, {
    required bool several,
    DateTime? exported,
  }) {
    var name = _core.nameOf(app);
    var narrowed = [
      if (app.listings.length > 1)
        for (var listing in app.listings)
          MenuItem(
            'Export ${listing.storeLabel} only',
            onSelected: _running
                ? null
                : () => _run(
                    'export',
                    app: name,
                    arguments: {'listing': listing.store},
                  ),
          ),
      if (several)
        MenuItem(
          'Export all apps',
          onSelected: _running ? null : () => _run('export'),
        ),
    ];
    return FwSplitButton(
      label: _running ? 'Exporting…' : 'Export',
      onPressed: _running ? null : () => _run('export', app: name),
      entries: [
        ...narrowed,
        if (narrowed.isNotEmpty) const MenuDivider(),
        MenuItem(
          'Reveal in Finder',
          onSelected: exported == null ? null : () => _run('open', app: name),
        ),
        MenuItem(
          'Copy CLI command',
          onSelected: () => _copyCommand(several ? name : null),
        ),
      ],
    );
  }

  /// A thumbnail was clicked: show that image, as large as the window allows.
  void _showShot(String appName, String key, int index) {
    var found = _setFor(appName, key);
    if (found == null) return;
    var (app, target, listing, set) = found;
    showStoreShot(
      context,
      shots: [
        for (var image in set.images) widget.plugin.image(set.pathOf(image)),
      ],
      titles: [
        for (var image in set.images) storeTitleOf(app.layout, target, image),
      ],
      index: index,
      setLabel: '${listing.storeLabel} · ${target.label} · ${set.storeLocale}',
      width: target.canvas.width,
      height: target.canvas.height,
    );
  }

  /// The card's own action: the whole set, arranged as a listing.
  void _showListing(String appName, String key) {
    var found = _setFor(appName, key);
    if (found == null) return;
    var (app, target, listing, set) = found;
    showStoreListing(
      context,
      shots: [
        for (var image in set.images) widget.plugin.image(set.pathOf(image)),
      ],
      aspect: target.canvas.width / target.canvas.height,
      appName: _core.identityOf(app).name,
      subtitle: _core.identityOf(app).subtitle,
      setLabel: '${listing.storeLabel} · ${target.label} · ${set.storeLocale}',
    );
  }

  /// Everything a viewer needs, from the package that was clicked and the set
  /// within it.
  ///
  /// **Both, not just the key.** A manifest key is `store/class/appLocale` and
  /// carries no package, because a manifest belongs to one package already —
  /// so searching every package for the first match opened the wrong app's
  /// screenshots as soon as two declared packages shared a listing shape,
  /// which two apps in one workspace routinely do.
  (StoreShotsApp, StoreTarget, Listing, StoreShotsSet)? _setFor(
    String appName,
    String key,
  ) {
    for (var app in _core.apps) {
      if (_core.nameOf(app) != appName) continue;
      var set = _core.manifestOf(app)[key];
      if (set == null || set.images.isEmpty) return null;
      var target = _targetFor(app, key);
      if (target == null) return null;
      return (app, target.$1, target.$2, set);
    }
    return null;
  }

  /// The declared target and its listing, from a manifest key.
  ///
  /// A key is `app/store/class/appLocale` since the manifest's second
  /// version, and the app's segment is matched too: matched from the store
  /// on, no key ever matched, and both viewers opened nothing.
  (StoreTarget, Listing)? _targetFor(StoreShotsApp app, String key) {
    var name = _core.nameOf(app);
    for (var listing in app.listings) {
      for (var target in listing.targets) {
        if (key.startsWith('$name/${target.store}/${target.id}/')) {
          return (target, listing);
        }
      }
    }
    return null;
  }

  /// The command the Export button runs. `--app` only when there is a choice:
  /// with one app declared, the bare command is the same export and is the
  /// one the docs spell.
  void _copyCommand(String? app) {
    var command = [
      'fw run store export',
      if (app != null) '--app=$app',
    ].join(' ');
    unawaited(Clipboard.setData(ClipboardData(text: command)));
    setState(() => _outcome = (app: app, text: 'Command copied'));
  }

  /// Where the shots come from — the scenario file, workspace-relative, so it
  /// reads the same whichever package it is in and pastes into a terminal at
  /// the root. The package alone when the declaration names no file, and
  /// nothing for a root package that names none, since `.` says nothing.
  static String? _sourceOf(StoreShotsApp app) {
    var parts = [if (app.path != '.') app.path, ?app.file];
    return parts.isEmpty ? null : parts.join('/');
  }

  @override
  Widget build(BuildContext context) {
    var apps = _core.apps;
    if (apps.isEmpty) {
      return const NoPackagesConfigured(icon: Icons.storefront_outlined);
    }
    // The app the address names, or the first declared one when it names
    // none — which is where selecting the plugin off the rail leaves you.
    var named = AddressScope.segment(context, 0);
    var app = named == null
        ? apps.first
        : apps.where((a) => _core.nameOf(a) == named).firstOrNull;
    if (app == null) {
      // Said rather than repaired: showing the first app under an address
      // that names another is a page that is wrong without looking wrong.
      return EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No app called $named',
        message: 'Declared: ${apps.map(_core.nameOf).join(', ')}.',
      );
    }
    var locales = _localesOf(app);
    var locale = locales.contains(_locale) ? _locale : locales.firstOrNull;

    // Subscribed, not merely read. The core narrates by calling
    // `notifyChanged`, which the plugin relays as a `ChangeNotifier`; without
    // this the rail's status line moved through a whole export while the panel
    // below it sat on the first line it had happened to build with.
    return ListenableBuilder(
      listenable: widget.plugin,
      builder: (context, _) =>
          _body(context, app, locales, locale, several: apps.length > 1),
    );
  }

  Widget _body(
    BuildContext context,
    StoreShotsApp app,
    List<String> locales,
    String? locale, {
    required bool several,
  }) {
    var name = _core.nameOf(app);
    var manifest = _core.manifestOf(app);
    var exported = manifest.exportedAt;
    var progress = _core.progress;
    var outcome = _outcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The header pads itself — gutter, top and bottom — so the list adds
        // only the side gutter. Padding both was three helpings of the same
        // space: doubled gutters, a doubled top inset, and a gap under the
        // header on top of the header's own.
        FwPanelHeader(
          name,
          selectableSubtitle: true,
          subtitle: [
            ?_sourceOf(app),
            if (progress != null)
              progress.line
            else if (exported == null)
              'never exported'
            else
              'exported ${ageOf(exported)}',
            if (progress == null &&
                outcome != null &&
                (outcome.app == null || outcome.app == name))
              outcome.text,
          ],
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (locales.length > 1 && locale != null) ...[
                _LocaleSwitch(
                  locales: locales,
                  selected: locale,
                  onChanged: (value) => setState(() => _locale = value),
                ),
                const Gap(FwSpacing.md),
              ],
              _exportButton(app, several: several, exported: exported),
            ],
          ),
        ),
        // Determinate, because the total is known before the first set starts
        // — a spinner would be the one thing a long job must not be, which is
        // silent about how much is left.
        if (progress != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: panelGutter),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.pill),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 4,
                backgroundColor: context.colors.line,
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              panelGutter,
              FwSpacing.md,
              panelGutter,
              FwSpacing.xxxl,
            ),
            children: [
              for (var listing in app.listings)
                _ListingBlock(
                  appName: name,
                  listing: listing,
                  manifest: manifest,
                  image: widget.plugin.image,
                  locale: locale,
                  working: progress?.app == name ? progress?.key : null,
                  onShot: _showShot,
                  onListing: _showListing,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Which locale every card on the screen is showing.
///
/// A switch rather than a fourth level of nesting, per §6: changing it changes
/// every image at once, where nesting it turns four screenshots into sixteen
/// rows.
///
/// A **dropdown**, and the same one the Translations panel uses. It was a row
/// of pills first, which is the right control for two or three choices and the
/// wrong one here — a listing declares as many locales as it ships, and twenty
/// of them wrap into a block of chrome taller than the title it sits under.
/// One compact control is also what lets this live beside Export in the title
/// row instead of in a band of its own below it.
class _LocaleSwitch extends StatelessWidget {
  const _LocaleSwitch({
    required this.locales,
    required this.selected,
    required this.onChanged,
  });

  final List<String> locales;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MenuAnchor(
      menuChildren: [
        for (var locale in locales)
          MenuItemButton(
            onPressed: () => onChanged(locale),
            leadingIcon: Icon(
              locale == selected ? Icons.check : null,
              size: FwIconSize.sm,
              color: colors.accent,
            ),
            child: Text(locale, style: context.type.body),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Which locale the screenshots below are from',
        child: Tappable(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Container(
            height: 28,
            padding: const EdgeInsets.only(
              left: FwSpacing.lg,
              right: FwSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.bg,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: Row(
              children: [
                Text(selected, style: context.type.bodySmall),
                Icon(Icons.expand_more, size: FwIconSize.sm, color: colors.mut),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One store's half of the listing: a heading, then a card per display class.
class _ListingBlock extends StatelessWidget {
  const _ListingBlock({
    required this.appName,
    required this.listing,
    required this.manifest,
    required this.image,
    required this.locale,
    required this.working,
    required this.onShot,
    required this.onListing,
  });

  /// Which declared app this block is drawing.
  final String appName;

  final Listing listing;
  final StoreShotsReport manifest;
  final StoreImage image;
  final String? locale;

  /// A shot was clicked — the app, the set's key, and its 0-based position.
  final void Function(String appName, String key, int index) onShot;

  /// The card's listing action — the app and the set's key.
  final void Function(String appName, String key) onListing;

  /// The `store/class/appLocale` key of the set an export is on right now, so
  /// exactly that card can say so while the others stay as they were.
  final String? working;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.lg),
          child: Text(listing.storeLabel, style: context.type.heading),
        ),
        for (var target in listing.targets)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.lg),
            child: _SetCard(
              listing: listing,
              target: target,
              image: image,
              set: locale == null
                  ? null
                  : manifest['$appName/${target.store}/${target.id}/$locale'],
              storeLocale: locale == null ? null : listing.locales[locale],
              working: working == '${target.store}/${target.id}/$locale',
              onShot: (index) => onShot(
                appName,
                '$appName/${target.store}/${target.id}/$locale',
                index,
              ),
              onListing: () => onListing(
                appName,
                '$appName/${target.store}/${target.id}/$locale',
              ),
            ),
          ),
        const Gap(FwSpacing.lg),
      ],
    );
  }
}

/// One set — one listing, one display class, one locale.
///
/// An adapter now: the card and its parts live in `store/ui/set_card.dart`,
/// where a demo can reach them. This maps the report onto them and owns the
/// wording, which is the half that is about *this* panel.
///
/// The corner is deliberately **neutral and unabbreviated**: canvas, locale,
/// and how many shots there are. It first read `1320×2868 · 15 of 10 · en-US`
/// in amber, which nobody could decode — two numbers with no unit, coloured as
/// a warning about something the card never named, and shots past the tenth
/// dimmed with nothing on screen saying why.
///
/// So the cap is stated in words, once, under the strip, and only when it
/// actually bites. Nothing here judges the screenshots: decision 1. A store
/// publishing ten of fifteen is arithmetic against a published limit, and it
/// is the one thing on this card that changes what gets shipped.
class _SetCard extends StatelessWidget {
  const _SetCard({
    required this.listing,
    required this.target,
    required this.image,
    required this.set,
    required this.storeLocale,
    required this.working,
    required this.onShot,
    required this.onListing,
  });

  final Listing listing;
  final StoreTarget target;
  final StoreImage image;
  final StoreShotsSet? set;
  final String? storeLocale;
  final ValueChanged<int> onShot;
  final VoidCallback onListing;

  /// This set is the one being exported right now.
  final bool working;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var images = set?.images ?? const <String>[];
    var shots = [
      for (var image in images)
        StoreShotImage(name: image, image: this.image(set!.pathOf(image))),
    ];
    return StoreCardShell(
      children: [
        StoreCardHeader(
          label: target.label,
          busy: working,
          actions: [
            // The set's own action, on the set's own card. A listing is a
            // property of the set — which is why there is no such thing as
            // previewing "the listing of shot 4", and why the page that tried
            // to be one had a selection it could not justify.
            if (shots.isNotEmpty)
              StoreCardAction(
                label: 'Preview listing',
                icon: Icons.storefront_outlined,
                onTap: onListing,
              ),
          ],
          facts: [
            '${target.canvas.width} × ${target.canvas.height} px',
            ?storeLocale,
            if (shots.isNotEmpty)
              '${shots.length} ${shots.length == 1 ? 'shot' : 'shots'}',
          ],
        ),
        const Gap(FwSpacing.lg),
        StoreShotStrip(
          shots: shots,
          aspect: target.canvas.width / target.canvas.height,
          height: storeThumbHeight,
          cap: listing.maxShots,
          capLabel: listing.storeLabel,
          onShot: onShot,
        ),
        if (shots.length > listing.maxShots) ...[
          const Gap(FwSpacing.lg),
          StoreNote(
            tone: colors.amber,
            icon: Icons.info_outline,
            text:
                'Only the first ${listing.maxShots} are published — '
                "${listing.storeLabel}'s limit per display class.",
          ),
        ],
        if (shots.isEmpty) ...[
          const Gap(FwSpacing.lg),
          // Under the strip rather than beside it. Beside it, the sentence
          // starts wherever three thumbnails happen to end — and a thumbnail
          // is as wide as its canvas, so four cards on one screen put the same
          // sentence at four different left edges.
          Text(
            target.needsComposition
                ? 'Not exported yet. Export runs the scenarios at '
                      '${target.device.label}, then composes each named shot '
                      'onto this canvas.'
                : 'Not exported yet. Export runs the scenarios at '
                      '${target.device.label} and keeps every named shot.',
            style: context.type.bodySmall.copyWith(color: colors.mut2),
          ),
        ],
        if (set != null && set!.failed > 0) ...[
          const Gap(FwSpacing.md),
          StoreNote(
            tone: colors.red,
            icon: Icons.error_outline,
            text:
                '${set!.failed} scenario${set!.failed == 1 ? '' : 's'} '
                'failed while producing this set — it may be short.',
          ),
        ],
        // Its own note rather than a number added to the one above: the two
        // fail at different passes and are fixed differently — a scenario
        // that failed is the app's problem, a shot that would not compose is
        // the capture's.
        if (set != null && set!.framesFailed > 0) ...[
          const Gap(FwSpacing.md),
          StoreNote(
            tone: colors.red,
            icon: Icons.broken_image_outlined,
            text:
                '${set!.framesFailed} shot'
                '${set!.framesFailed == 1 ? '' : 's'} could not be composed '
                'onto this canvas and ${set!.framesFailed == 1 ? 'was' : 'were'} '
                'not written — the capture would not decode. Export again.',
          ),
        ],
      ],
    );
  }
}
