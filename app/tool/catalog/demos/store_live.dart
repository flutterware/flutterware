/// Where the store's own listing goes on a set card — three candidates, and
/// the states each of them has to survive.
///
/// Design: `docs/superpowers/specs/2026-08-27-store-live-and-upload-design.md`
/// §5. Nothing here is wired to a store; every screenshot is painted and every
/// live half is a literal, which is the point — the question is a layout
/// question and it is answerable without a credential.
///
/// Three things this is being judged on:
///
/// 1. **A project that does not use this lane must see no change at all.** The
///    first card of *Card states* is today's card, byte for byte, and it has
///    to still read as finished rather than as one waiting for a second half.
/// 2. **An absence somebody chose is an offer, not a warning.** Not declared,
///    never exported and never checked are all neutral; only a credential that
///    was found and refused is red.
/// 3. **A fact belongs at the level it is true at.** *Levels* is the check on
///    that: nothing about an account may end up printed once per card.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/store/ui/set_card.dart';
import 'package:flutterware_app/src/ui/design/design.dart';
import 'package:flutterware_app/src/ui/hover_card.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';
import 'store_stage.dart' show StandInShot;

@Preview(name: 'Three layouts', group: 'Store live', wrapper: wrapInAppTheme)
Widget storeLiveLayouts() => const _Layouts();

@Preview(name: 'Card states', group: 'Store live', wrapper: wrapInAppTheme)
Widget storeLiveStates() => const _States(layout: _LiveLayout.strips);

@Preview(name: 'Card states · D', group: 'Store live', wrapper: wrapInAppTheme)
Widget storeLiveStatesHybrid() => const _States(layout: _LiveLayout.hybrid);

@Preview(
  name: 'What hovering says',
  group: 'Store live',
  wrapper: wrapInAppTheme,
)
Widget storeLiveExplainers() => const _Explainers();

@Preview(name: 'Levels', group: 'Store live', wrapper: wrapInAppTheme)
Widget storeLiveLevels() => const _Levels();

@Preview(
  name: 'Three layouts · dark',
  group: 'Store live',
  wrapper: wrapInDarkTheme,
)
Widget storeLiveLayoutsDark() => const _Layouts();

// ---------------------------------------------------------------------------
// The fork
// ---------------------------------------------------------------------------

/// The same set, the same data, three places to put the store's half.
class _Layouts extends StatelessWidget {
  const _Layouts();

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      const _Caption(
        'A · Two strips',
        'Local above, live below and shorter — the export is the deliverable, '
            'the store is evidence. Comparable at a glance; roughly doubles '
            'the card.',
      ),
      _card(layout: _LiveLayout.strips, live: _live4),
      const _Caption(
        'B · One strip, switched',
        'Compact and the card keeps its height. You cannot see both at once, '
            'which is most of what the live half was for.',
      ),
      _card(layout: _LiveLayout.toggle, live: _live4),
      _card(layout: _LiveLayout.toggle, live: _live4, showing: _Showing.live),
      const _Caption(
        'C · A line, and a dialog',
        'The card stays as it is and answers *how much, how old*. The pixels '
            "move to a third viewer, beside §6's two.",
      ),
      _card(layout: _LiveLayout.line, live: _live4),
    ],
  );
}

// ---------------------------------------------------------------------------
// The state matrix
// ---------------------------------------------------------------------------

/// Every per-set state, drawn on layout A because it is the one with the most
/// to go wrong.
class _States extends StatelessWidget {
  const _States({required this.layout});

  final _LiveLayout layout;

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      const _Caption('1 · Nothing declared, nothing exported', "Today's card."),
      _card(layout: layout, local: const [], live: null),
      const _Caption('2 · Exported, never checked', 'Nobody has asked yet.'),
      _card(
        layout: layout,
        live: const _Live(
          note: 'Not checked.',
          detail:
              'Nobody has asked the App Store what it is showing. Checking '
              'only reads the listing — it cannot change it.',
        ),
      ),
      const _Caption('3 · Checked, and they agree', 'Four and four.'),
      _card(layout: layout, live: _live4),
      const _Caption(
        '4 · Checked, and they do not',
        'Six live against four here. A count, not a verdict — which one is '
            'right is not ours to say.',
      ),
      _card(layout: layout, live: _live6),
      const _Caption(
        '5 · Checked, and the slot is empty',
        'The app is there; this size and language have nothing on it. Ghosts '
            'are honest here — the slot is real and will fill.',
      ),
      _card(
        layout: layout,
        live: const _Live(
          shots: [],
          note: 'Nothing published here.',
          detail:
              'The app is on the App Store, but this size and this language '
              'have no screenshots on it yet.',
        ),
      ),
      const _Caption(
        '6 · No key on this Mac',
        'An offer, not a complaint. Nobody has failed at anything.',
      ),
      _card(
        layout: layout,
        live: const _Live(
          note: 'No App Store key on this Mac.',
          detail:
              'Create a key in App Store Connect under your own profile, then '
              'save it as ~/.appstoreconnect/private_keys/AuthKey_XXXXX.p8. It '
              'only reaches the apps you can already see.',
        ),
      ),
      const _Caption(
        '7 · The key works and cannot see this app',
        'Amber, because it is about access rather than about a mistake.',
      ),
      _card(
        layout: layout,
        live: const _Live(
          note: 'This key cannot see com.example.shop.',
          detail:
              'The key works — it just has no access to this app. It can see '
              'com.example.brew and com.example.pos.',
          tone: _Tone.amber,
        ),
      ),
      const _Caption(
        '8 · The key was refused',
        'The only red on the panel: something you set up has stopped working.',
      ),
      _card(
        layout: layout,
        live: const _Live(
          note: 'The App Store refused the key.',
          detail:
              'The key was found but not accepted. It may have been revoked, '
              'or the file may not match the key id in its name.',
          tone: _Tone.red,
        ),
      ),
      const _Caption(
        '9 · Google Play wants more than reading',
        'The one refusal nobody guesses, so it has to be said outright.',
      ),
      _card(
        layout: layout,
        listing: _play,
        target: _playPhone,
        live: const _Live(
          note: 'Google Play needs edit access.',
          detail:
              'Reading a Play listing opens a draft edit that we throw away, '
              'and view-only permission cannot open one. Ask for release '
              'access on this app.',
          tone: _Tone.amber,
        ),
      ),
      const _Caption(
        '10 · The worst pairing',
        'Never exported, six live. Ghosts above real pixels.',
      ),
      _card(
        layout: layout,
        listing: _play,
        target: _playPhone,
        local: const [],
        live: _livePlay6,
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Where the rest of the facts go
// ---------------------------------------------------------------------------

/// The three levels above the card, which is where most of §4's matrix lives.
class _Levels extends StatelessWidget {
  const _Levels();

  @override
  Widget build(BuildContext context) => _Page(
    children: [
      const _Caption(
        'Panel header · connected',
        'The summary line grows a clause per store. One line, whatever the '
            'listing contains.',
      ),
      const _Header(
        summary:
            'exported 4 days ago  ·  App Store checked just now  ·  '
            'Google Play checked just now',
      ),
      const _Caption(
        'Panel header · one store connected, one not',
        'Not connected is a state of the machine, said once. It is not amber: '
            'nobody failed.',
      ),
      const _Header(
        summary:
            'exported 4 days ago  ·  App Store checked just now  ·  '
            'Google Play not connected',
      ),
      const _Caption(
        'Panel header · nothing declared',
        'The lane is not in use, and the header offers it rather than '
            'complaining. No Check stores button until there is something to '
            'check.',
      ),
      const _Header(
        summary: 'exported 4 days ago',
        offer:
            'Declare a bundle id and a package name to see what each store '
            'currently has.',
      ),
      const _Caption(
        'Listing block · not published yet',
        "True of the store, not of the set — so it sits under the store's "
            'heading and the cards below it stay as they are.',
      ),
      const _ListingHeading(
        label: 'App Store',
        note: 'com.example.shop has no App Store record yet.',
      ),
      _card(live: null),
      const _Caption(
        'Listing block · connected',
        'When there is nothing to say, nothing is said.',
      ),
      const _ListingHeading(label: 'App Store'),
      _card(live: _live4),
    ],
  );
}

/// Every line the panel can say about an absence, with the card behind it
/// opened beside it.
///
/// A screenshot cannot hover, and the copy is the thing being reviewed — so the
/// two halves are laid out flat here rather than one being reachable only with
/// a pointer.
class _Explainers extends StatelessWidget {
  const _Explainers();

  static const _all = [
    (
      'Not exported yet.',
      'Export runs your scenarios on an iPhone 16 Pro Max and saves every shot '
          'you named, at 1320 × 2868.',
      _Tone.neutral,
    ),
    (
      'Not checked.',
      'Nobody has asked the App Store what it is showing. Checking only reads '
          'the listing — it cannot change it.',
      _Tone.neutral,
    ),
    (
      'Nothing published here.',
      'The app is on the App Store, but this size and this language have no '
          'screenshots on it yet.',
      _Tone.neutral,
    ),
    (
      'No App Store key on this Mac.',
      'Create a key in App Store Connect under your own profile, then save it '
          'as ~/.appstoreconnect/private_keys/AuthKey_XXXXX.p8. It only '
          'reaches the apps you can already see.',
      _Tone.neutral,
    ),
    (
      'This key cannot see com.example.shop.',
      'The key works — it just has no access to this app. It can see '
          'com.example.brew and com.example.pos.',
      _Tone.amber,
    ),
    (
      'The App Store refused the key.',
      'The key was found but not accepted. It may have been revoked, or the '
          'file may not match the key id in its name.',
      _Tone.red,
    ),
    (
      'Google Play needs edit access.',
      'Reading a Play listing opens a draft edit that we throw away, and '
          'view-only permission cannot open one. Ask for release access on '
          'this app.',
      _Tone.amber,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return _Page(
      children: [
        for (var (line, detail, tone) in _all)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 320,
                  child: _Explain(line: line, detail: detail, tone: tone),
                ),
                const Gap(FwSpacing.xl),
                Container(
                  width: 320,
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  decoration: BoxDecoration(
                    color: colors.panel,
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusSmall,
                    ),
                  ),
                  child: Text(detail, style: context.type.caption),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The candidates
// ---------------------------------------------------------------------------

/// D is the one the states render argued for; the other three are the
/// candidates it was argued against. See the file header.
enum _LiveLayout { strips, toggle, line, hybrid }

enum _Showing { local, live }

enum _Tone { neutral, amber, red }

/// What the store said, or why it did not.
class _Live {
  const _Live({
    this.shots,
    this.when,
    this.note,
    this.detail,
    this.tone = _Tone.neutral,
  });

  /// Null is *we do not know*, which is not the same as the empty list — that
  /// is *the store has none*, and the two want different words.
  final List<StoreShotImage>? shots;

  final String? when;

  /// The line on the card. One sentence, and short enough to read sideways.
  final String? note;

  /// What hovering it says. Where the path, the permission or the fix goes —
  /// the card has no room for any of them and should not make room.
  final String? detail;

  final _Tone tone;
}

Widget _card({
  _LiveLayout layout = _LiveLayout.strips,
  Listing? listing,
  StoreTarget? target,
  List<StoreShotImage>? local,
  required _Live? live,
  _Showing showing = _Showing.local,
}) {
  var resolvedListing = listing ?? _appStore;
  var resolvedTarget = target ?? _iphone;
  return _Card(
    layout: layout,
    listing: resolvedListing,
    target: resolvedTarget,
    local: local ?? _shots(4, resolvedTarget),
    live: live,
    showing: showing,
  );
}

class _Card extends StatelessWidget {
  const _Card({
    required this.layout,
    required this.listing,
    required this.target,
    required this.local,
    required this.live,
    required this.showing,
  });

  final _LiveLayout layout;
  final Listing listing;
  final StoreTarget target;
  final List<StoreShotImage> local;
  final _Live? live;
  final _Showing showing;

  double get _aspect => target.canvas.width / target.canvas.height;

  @override
  Widget build(BuildContext context) {
    return StoreCardShell(
      children: [
        StoreCardHeader(
          label: target.label,
          actions: [
            if (local.isNotEmpty)
              StoreCardAction(
                label: 'Preview listing',
                icon: Icons.storefront_outlined,
                onTap: () {},
              ),
          ],
          facts: [
            '${target.canvas.width} × ${target.canvas.height} px',
            'en-US',
            if (local.isNotEmpty) '${local.length} shots',
          ],
          trailing: layout == _LiveLayout.toggle && live?.shots != null
              ? _Segmented(showing: showing)
              : null,
        ),
        const Gap(FwSpacing.lg),
        ...switch (layout) {
          _LiveLayout.strips => _strips(context),
          _LiveLayout.hybrid => _hybrid(context),
          _LiveLayout.toggle => _toggle(context),
          _LiveLayout.line => _line(context),
        },
        if (local.isEmpty) ...[
          const Gap(FwSpacing.lg),
          _Explain(
            line: 'Not exported yet.',
            detail:
                'Export runs your scenarios on a ${target.device.label} and '
                'saves every shot you named, at '
                '${target.canvas.width} × ${target.canvas.height}.',
          ),
        ],
      ],
    );
  }

  /// A · the store's half under ours, shorter, with a label on each so the
  /// pair cannot be read as one long strip.
  List<Widget> _strips(BuildContext context) => [
    if (live != null) ...[
      const _StripLabel(text: 'This export', trailing: null),
      const Gap(FwSpacing.sm),
    ],
    StoreShotStrip(
      shots: local,
      aspect: _aspect,
      height: storeThumbHeight,
      cap: listing.maxShots,
      capLabel: listing.storeLabel,
      onShot: (_) {},
    ),
    if (live case var live?) ...[
      const Gap(FwSpacing.lg),
      _StripLabel(
        text: 'On ${listing.storeLabel}',
        trailing: live.when ?? live.note,
        tone: live.tone,
      ),
      const Gap(FwSpacing.sm),
      if (live.shots case var shots?)
        StoreShotStrip(
          shots: shots,
          aspect: _aspect,
          height: storeThumbHeight * 0.62,
          onShot: (_) {},
        )
      else
        SizedBox(
          height: storeThumbHeight * 0.62,
          child: StoreGhostStrip(width: storeThumbHeight * 0.62 * _aspect),
        ),
    ],
  ];

  /// D · A where there are pixels, C where there are not.
  ///
  /// The rule the *Card states* render forced: a ghost strip promises *this
  /// will fill*, which is true of a slot the store has and false of one we
  /// were not allowed to look at. Five states drew the same picture under A
  /// and only their sentences differed — so an unknown live half stops being
  /// a strip and becomes a line.
  List<Widget> _hybrid(BuildContext context) =>
      live?.shots == null ? _line(context) : _strips(context);

  /// B · one strip, and the header says which one you are looking at.
  List<Widget> _toggle(BuildContext context) => [
    StoreShotStrip(
      shots: showing == _Showing.local ? local : (live?.shots ?? const []),
      aspect: _aspect,
      height: storeThumbHeight,
      cap: showing == _Showing.local ? listing.maxShots : null,
      capLabel: listing.storeLabel,
      onShot: (_) {},
    ),
    if (live?.note case var note?) ...[
      const Gap(FwSpacing.lg),
      _note(context, note, live!.tone),
    ],
  ];

  /// C · the card unchanged, and one line about the store under it.
  List<Widget> _line(BuildContext context) => [
    StoreShotStrip(
      shots: local,
      aspect: _aspect,
      height: storeThumbHeight,
      cap: listing.maxShots,
      capLabel: listing.storeLabel,
      onShot: (_) {},
    ),
    if (live case var live?) ...[
      const Gap(FwSpacing.lg),
      Row(
        children: [
          Expanded(
            child: _Explain(
              line: live.shots == null
                  ? live.note ?? ''
                  : '${live.shots!.length} on the ${listing.storeLabel}'
                        '${live.when == null ? '' : ', ${live.when}'}.',
              detail: live.detail,
              tone: live.tone,
            ),
          ),
          if (live.shots != null)
            StoreCardAction(
              label: 'Compare',
              icon: Icons.compare_arrows,
              onTap: () {},
            ),
        ],
      ),
    ],
  ];

  Widget _note(BuildContext context, String text, _Tone tone) {
    var colors = context.colors;
    return switch (tone) {
      _Tone.neutral => Text(
        text,
        style: context.type.bodySmall.copyWith(color: colors.mut2),
      ),
      _Tone.amber => StoreNote(
        tone: colors.amber,
        icon: Icons.info_outline,
        text: text,
      ),
      _Tone.red => StoreNote(
        tone: colors.red,
        icon: Icons.error_outline,
        text: text,
      ),
    };
  }
}

/// One short line, with the long answer behind it.
///
/// Every absence on this panel has two audiences: somebody scanning four cards
/// who needs to know *whether* there is a problem, and somebody who has just
/// found one and needs the path, the permission or the fix. Putting both on the
/// card serves neither — the line stops being scannable and the detail is still
/// too cramped to hold a file path.
///
/// So the card carries a sentence and hovering carries the rest, on the house
/// [HoverCard] rather than a `Tooltip`: the detail runs to two lines and often
/// wants a path in it, and a tooltip that long is a wall that vanishes when you
/// move to read it.
class _Explain extends StatelessWidget {
  const _Explain({required this.line, this.detail, this.tone = _Tone.neutral});

  final String line;
  final String? detail;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (toneColor, icon) = switch (tone) {
      _Tone.neutral => (colors.mut2, null),
      _Tone.amber => (colors.amber, Icons.info_outline),
      _Tone.red => (colors.red, Icons.error_outline),
    };
    var text = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case var icon?) ...[
          Icon(icon, size: FwIconSize.sm, color: toneColor),
          const Gap(FwSpacing.sm),
        ],
        Flexible(
          child: Text(
            line,
            style: context.type.bodySmall.copyWith(color: toneColor),
          ),
        ),
        // The affordance. A hover target that looks like prose is a hover
        // target nobody hovers.
        if (detail != null) ...[
          const Gap(FwSpacing.xs),
          Icon(Icons.help_outline, size: 13, color: colors.mut3),
        ],
      ],
    );
    if (detail case var detail?) {
      return Align(
        alignment: Alignment.centerLeft,
        child: HoverCard(
          anchor: (context, _) => text,
          content: (context, _) => Container(
            width: 320,
            padding: const EdgeInsets.all(FwSpacing.lg),
            decoration: BoxDecoration(
              color: colors.panel,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x22000000),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(detail, style: context.type.caption),
          ),
        ),
      );
    }
    return Align(alignment: Alignment.centerLeft, child: text);
  }
}

/// The little heading over a strip, and the fact that belongs to it.
class _StripLabel extends StatelessWidget {
  const _StripLabel({
    required this.text,
    required this.trailing,
    this.tone = _Tone.neutral,
  });

  final String text;
  final String? trailing;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var toneColor = switch (tone) {
      _Tone.neutral => colors.mut,
      _Tone.amber => colors.amber,
      _Tone.red => colors.red,
    };
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: context.type.bodySmall.copyWith(
            color: colors.mut,
            fontSize: 10,
            letterSpacing: 0.8,
          ),
        ),
        if (trailing case var trailing?) ...[
          const Gap(FwSpacing.md),
          Expanded(
            child: Text(
              trailing,
              style: context.type.bodySmall.copyWith(color: toneColor),
            ),
          ),
        ],
      ],
    );
  }
}

/// B's control. Two pills, because there are exactly two things to look at.
class _Segmented extends StatelessWidget {
  const _Segmented({required this.showing});

  final _Showing showing;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget pill(String label, bool on) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: on ? colors.accent.withValues(alpha: 0.14) : null,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        label,
        style: context.type.bodySmall.copyWith(
          color: on ? colors.accent : colors.mut,
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill('This export', showing == _Showing.local),
          pill('On the store', showing == _Showing.live),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The levels above the card
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.summary, this.offer});

  final String summary;
  final String? offer;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Store', style: context.type.pageTitle),
            const Spacer(),
            if (offer == null) ...[
              const _Button(label: 'Check stores', filled: false),
              const Gap(FwSpacing.md),
            ],
            const _Button(label: 'Export', filled: true),
          ],
        ),
        const Gap(FwSpacing.sm),
        Text(
          summary,
          style: context.type.bodySmall.copyWith(color: colors.mut),
        ),
        if (offer case var offer?) ...[
          const Gap(FwSpacing.sm),
          Row(
            children: [
              Flexible(
                child: Text(
                  offer,
                  style: context.type.bodySmall.copyWith(color: colors.mut2),
                ),
              ),
              const Gap(FwSpacing.md),
              StoreCardAction(
                label: 'How',
                icon: Icons.help_outline,
                onTap: () {},
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ListingHeading extends StatelessWidget {
  const _ListingHeading({required this.label, this.note});

  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.lg),
      child: Row(
        children: [
          Text(label, style: context.type.heading),
          if (note case var note?) ...[
            const Gap(FwSpacing.lg),
            Expanded(
              child: Text(
                note,
                style: context.type.bodySmall.copyWith(color: colors.mut2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.filled});

  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: filled ? colors.accent : null,
        border: filled ? null : Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        label,
        style: context.type.bodySmall.copyWith(
          color: filled ? Colors.white : colors.ink,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scaffolding
// ---------------------------------------------------------------------------

class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(FwSpacing.xl),
    children: [
      for (var child in children) ...[child, const Gap(FwSpacing.lg)],
    ],
  );
}

/// What each block below is, and what it is being judged on. Part of the
/// mockup rather than of the panel.
class _Caption extends StatelessWidget {
  const _Caption(this.title, this.body);

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: FwSpacing.xl, bottom: FwSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: context.type.bodyStrong.copyWith(color: colors.accent),
          ),
          const Gap(FwSpacing.xs),
          Text(
            body,
            style: context.type.bodySmall.copyWith(color: colors.mut2),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data, all of it painted
// ---------------------------------------------------------------------------

final _appStore = Listing.appStore(locales: const {'en': 'en-US'});
final _play = Listing.play(locales: const {'en': 'en-US'});
final _iphone = _appStore.targets.first;
final _playPhone = _play.targets.first;

const _names = [
  'menu',
  'order',
  'cart',
  'pickup',
  'rewards',
  'account',
  'settings',
];

List<StoreShotImage> _shots(int count, StoreTarget target, {String? prefix}) =>
    [
      for (var i = 0; i < count; i++)
        StoreShotImage(
          name:
              '${(i + 1).toString().padLeft(2, '0')}-'
              '${prefix == null ? '' : '$prefix-'}${_names[i % _names.length]}',
          image: StandInShot(
            index: prefix == null ? i : i + 2,
            aspect: target.canvas.width / target.canvas.height,
          ),
        ),
    ];

final _live4 = _Live(
  shots: _shots(4, _iphone, prefix: 'live'),
  when: 'uploaded 12 Aug',
);

final _live6 = _Live(
  shots: _shots(6, _iphone, prefix: 'live'),
  when: 'uploaded 12 Aug',
);

final _livePlay6 = _Live(
  shots: _shots(6, _playPhone, prefix: 'live'),
  when: 'uploaded 3 Jun',
);
