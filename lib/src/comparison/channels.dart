import 'dart:convert';

import 'pixel_diff.dart';
import 'tree_diff.dart';

/// How a row is addressed when a comparison spans several packages.
///
/// The package's own path, worktree-relative, in front of the id the row has
/// inside that package — so the whole thing reads as the file's path plus the
/// name it was declared under, and needs no separator nobody has seen before.
///
/// Applied only when a run touches more than one package. Qualifying
/// unconditionally would rename every id in every single-package project to
/// buy nothing, and ids travel: they are in deep links, in the pull-request
/// comment's table, and in whatever a consumer's script filters on.
String comparedIdIn(String package, String id) =>
    package.isEmpty ? id : '$package/$id';

/// [ids] as a filter over the ids inside [package]: each one as given, plus the
/// id inside [package] of any that [comparedIdIn] qualified with it.
///
/// For narrowing a run to ids a report handed back. Keeping both forms is what
/// makes it exact without knowing the entries: an id inside [package] passes
/// `contains` on the result precisely when it was named plainly or as
/// `comparedIdIn(package, id)` — so a plain id still narrows every package,
/// and a qualified one only its own.
List<String> idsNamedIn(String package, Iterable<String> ids) => [
  for (var id in ids) ...[
    id,
    if (package.isNotEmpty && id.startsWith('$package/'))
      id.substring(package.length + 1),
  ],
];

/// One thing compared, on every channel that had something to say.
///
/// Channels rather than "a picture plus some extras." Pixels have a
/// threshold, texts are exact, and the events channel that is coming will need
/// field masks for tokens and timestamps. Making each channel own its own
/// rules now is what lets a new one land later without reopening the kernel —
/// and what lets a reader who cannot see pixels, which is every agent, read
/// the same comparison a human is looking at.
class ComparedItem {
  const ComparedItem({
    required this.id,
    required this.state,
    this.label,
    this.pixels,
    this.tree,
    this.texts,
    this.events,
    this.note,
    this.retargeted,
    this.shots,
    this.package,
  });

  /// What was compared: an entry id, or a step's path through its flow — made
  /// unique within it, see `StepIds`.
  final String id;

  /// Which package declared it, worktree-relative — `app`,
  /// `packages/gallery`. Null on a row from a comparison written before a
  /// comparison could span several, and on a step, which takes its package
  /// from the scenario holding it.
  ///
  /// Recorded even when the run touched one package and [id] was therefore
  /// left unqualified, so a script never has to take an id apart to recover
  /// the package — see [comparedIdIn].
  final String? package;

  final ComparedState state;

  /// How it names itself on screen — a step's `tap #pay`, an entry's name.
  final String? label;

  final PixelChannel? pixels;
  final TreeChannel? tree;
  final TextChannel? texts;
  final EventChannel? events;

  /// Why it is in the state it is, when the state alone does not say: which
  /// file made it worth rendering, or which side failed to render.
  final String? note;

  /// What the step aimed at on each side, when the test names its target
  /// another way than it did — a renamed key, a finder by key where there was
  /// one by index. Null for every step aimed the way it was, and for an entry.
  ///
  /// **A fact about the test, not about the app**, which is why it is no
  /// [state]: the channels say what the app did, and a step that is found
  /// differently and drew the same picture did the same thing. It is recorded
  /// because it is the explanation a reader needs in the one case where it
  /// matters — a step that *did* change may have changed because it now
  /// reaches another widget — and it is a field rather than a sentence in
  /// [note] so that a reader which is not a person can tell the two apart.
  final ({String base, String head})? retargeted;

  /// Where the two frames are filed, as `ShotCache` keys.
  ///
  /// The verdict is not the picture, and a reader wants both. Without this
  /// a comparison could say a preview changed by 0.38% and nothing anywhere
  /// could show it: the keys are computed inside the runner from a closure
  /// fingerprint nobody outside can reproduce. They go in the artifact too, so
  /// a panel, an agent and a static page all address the same two files.
  final ({String base, String head})? shots;

  /// The same row, addressed inside [package].
  ///
  /// [qualify] puts the package's path in front of the id, which is what a
  /// comparison spanning several packages does: without it two packages each
  /// declaring `demo/card.dart#card` are one row that overwrites itself. A
  /// comparison of a single package leaves the id exactly as it was and still
  /// records the package.
  ComparedItem inPackage(String package, {required bool qualify}) =>
      ComparedItem(
        id: qualify ? comparedIdIn(package, id) : id,
        state: state,
        label: label,
        pixels: pixels,
        tree: tree,
        texts: texts,
        events: events,
        note: note,
        retargeted: retargeted,
        shots: shots,
        package: package,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'state': state.name,
    'package': ?package,
    'label': ?label,
    'note': ?note,
    'retargeted': ?(retargeted == null
        ? null
        : {'base': retargeted!.base, 'head': retargeted!.head}),
    'shots': ?(shots == null
        ? null
        : {'base': shots!.base, 'head': shots!.head}),
    if (pixels != null || tree != null || texts != null || events != null)
      'channels': {
        'pixels': ?pixels?.toJson(),
        'tree': ?tree?.toJson(),
        'texts': ?texts?.toJson(),
        'events': ?events?.toJson(),
      },
  };

  /// A row read back off `index.json` — what an exported page draws from.
  ///
  /// Lossy exactly where [toJson] is: the pixel counts come back as the rounded
  /// fraction, the mask never travels, and a capped cluster list stays capped.
  /// Everything a viewer draws survives the round trip; nothing recomputes.
  static ComparedItem fromJson(Map<String, Object?> json) {
    var channels = json['channels'] as Map<String, Object?>? ?? const {};
    var shots = json['shots'] as Map<String, Object?>?;
    var base = shots?['base'] as String?;
    var head = shots?['head'] as String?;
    var retargeted = json['retargeted'] as Map<String, Object?>?;
    var aimedBase = retargeted?['base'] as String?;
    var aimedHead = retargeted?['head'] as String?;
    return ComparedItem(
      id: json['id'] as String? ?? '',
      state:
          ComparedState.values.asNameMap()[json['state']] ??
          ComparedState.skipped,
      package: json['package'] as String?,
      label: json['label'] as String?,
      note: json['note'] as String?,
      retargeted: aimedBase == null || aimedHead == null
          ? null
          : (base: aimedBase, head: aimedHead),
      shots: base == null || head == null ? null : (base: base, head: head),
      pixels: switch (channels['pixels']) {
        Map<String, Object?> pixels => PixelChannel.fromJson(pixels),
        _ => null,
      },
      tree: switch (channels['tree']) {
        Map<String, Object?> tree => TreeChannel.fromJson(tree),
        _ => null,
      },
      texts: switch (channels['texts']) {
        Map<String, Object?> texts => TextChannel.fromJson(texts),
        _ => null,
      },
      events: switch (channels['events']) {
        Map<String, Object?> events => EventChannel.fromJson(events),
        _ => null,
      },
    );
  }

  /// Which channels had something to say about this item.
  ///
  /// The cheap question, kept apart from [deltas] because a list draws it on
  /// every row of every frame and [deltas] allocates. Nothing here builds a
  /// delta: it asks each channel whether it changed and takes its name.
  /// Events answer with [EventChannel.significant] — a row chip saying
  /// `events` over pure `system` chatter is the list restating the noise the
  /// verdict just learned to ignore.
  List<String> get channelsFired => [
    if (pixels?.changed ?? false) 'pixels',
    if (tree?.significant ?? false) 'tree',
    if (texts?.changed ?? false) 'texts',
    if (events?.significant ?? false) 'events',
  ];

  /// Every difference this item found, on every channel, as one flat list.
  ///
  /// The **facet contract** — one shape a reader can filter, count and rank
  /// without knowing which channel a difference came from. A filter asking for
  /// *events on the db channel, but not out of `lib/data/cache.dart`* is three
  /// predicates over these fields; without the flattening it is three
  /// predicates and a walk over four differently-shaped lists.
  ///
  /// Built on demand and never stored: `index.json` keeps the channels, which
  /// is where the detail belongs, and this is the view over them. See the
  /// design note §9.
  List<ChannelDelta> get deltas => [
    // One line, because a pixel diff has no fields — but it must be here or a
    // per-channel count cannot see the channel that fires most often.
    if (pixels?.changed ?? false)
      ChannelDelta(
        channel: 'pixels',
        property: 'changed',
        head:
            '${(pixels!.diff.fraction * 100).toStringAsFixed(2)}% · '
            '${pixels!.diff.clusters.length} '
            'region${pixels!.diff.clusters.length == 1 ? '' : 's'}',
      ),
    for (var delta in tree?.diff.deltas ?? const <TreeDelta>[])
      if (delta.kind != TreeDeltaKind.shifted)
        ChannelDelta(
          channel: 'tree',
          subject: delta.path,
          property: delta.property ?? delta.kind.name,
          base: delta.base,
          head: delta.head,
        ),
    for (var text in texts?.removed ?? const <String>[])
      ChannelDelta(channel: 'texts', property: 'removed', base: text),
    for (var text in texts?.added ?? const <String>[])
      ChannelDelta(channel: 'texts', property: 'added', head: text),
    for (var event in events?.removed ?? const <String>[])
      ChannelDelta(
        channel: 'events',
        subchannel: EventChannel.subchannelOf(event),
        subject: event,
        property: 'removed',
      ),
    for (var event in events?.added ?? const <String>[])
      ChannelDelta(
        channel: 'events',
        subchannel: EventChannel.subchannelOf(event),
        subject: event,
        property: 'added',
      ),
    for (var delta in events?.deltas ?? const <EventDelta>[])
      ChannelDelta(
        channel: 'events',
        subchannel: delta.subchannel,
        subject: delta.title,
        property: delta.kind == EventDeltaKind.moved ? 'moved' : delta.property,
        base: delta.base,
        head: delta.head,
        origin: delta.origin,
      ),
  ];

  /// Assembles the verdict from the channels.
  ///
  /// The ladder is severity rather than arithmetic. A head that fails to render
  /// outranks everything: it is the result the tool exists to catch, and a
  /// percentage next to it would answer a smaller question. A base that fails
  /// is the opposite — it means the entry was already broken before this
  /// branch, which is worth stating once and quietly.
  static ComparedItem of({
    required String id,
    String? label,
    PixelDiff? pixels,
    TreeDiff? tree,
    bool treeSkewed = false,
    List<String> baseTexts = const [],
    List<String> headTexts = const [],
    List<Map<String, Object?>> baseEvents = const [],
    List<Map<String, Object?>> headEvents = const [],
    bool baseRendered = true,
    bool headRendered = true,
    String? note,
    ({String base, String head})? shots,
  }) {
    if (!headRendered) {
      return ComparedItem(
        id: id,
        label: label,
        state: baseRendered ? ComparedState.broke : ComparedState.failed,
        note: note ?? (baseRendered ? 'renders on base, throws here' : null),
        shots: shots,
      );
    }
    if (!baseRendered) {
      return ComparedItem(
        id: id,
        label: label,
        state: ComparedState.wasBroken,
        note: note ?? 'was already broken on base',
        shots: shots,
      );
    }

    var textChannel = TextChannel.of(base: baseTexts, head: headTexts);
    var eventChannel = EventChannel.of(base: baseEvents, head: headEvents);
    var treeChannel = tree == null
        ? null
        : TreeChannel(tree, skewed: treeSkewed);
    var pixelChannel = pixels == null ? null : PixelChannel(pixels);
    // Events weigh in through [EventChannel.significant]: `system` chatter is
    // compared and carried, but a step it is the whole of stays `same`. The
    // channel is still stored below whenever it holds anything, which is what
    // keeps the door open — the deltas ride `index.json`, they just do not
    // decide the state.
    var changed =
        (pixelChannel?.changed ?? false) ||
        (treeChannel?.significant ?? false) ||
        textChannel.changed ||
        eventChannel.significant;

    return ComparedItem(
      id: id,
      label: label,
      state: changed ? ComparedState.changed : ComparedState.same,
      pixels: pixelChannel,
      tree: treeChannel,
      texts: textChannel.changed ? textChannel : null,
      events: eventChannel.changed ? eventChannel : null,
      note: note,
      shots: shots,
    );
  }
}

/// Declared in the order a report ranks them: the top row should be the thing
/// most likely to be a mistake.
enum ComparedState {
  /// Renders on base, throws on head. The most valuable output in the tool.
  broke,

  /// Neither side renders.
  failed,

  /// Throws on base, renders on head — already broken before this branch.
  wasBroken,

  /// Only on head.
  added,

  /// Only on base.
  removed,

  changed,

  /// Compared and identical.
  same,

  /// Not compared, because nothing it reads differs between the two
  /// checkouts. Indistinguishable from [same] in truth, and worth its own name
  /// so a report can say how much work it did not do.
  skipped;

  /// True for the states worth drawing attention to. [same] and [skipped] mean
  /// "nothing to see", and a list that highlights those does not get read to
  /// the end.
  bool get isFinding => this != same && this != skipped;
}

class PixelChannel {
  const PixelChannel(this.diff);

  final PixelDiff diff;

  bool get changed => diff.changed;

  /// The written form back into a [PixelDiff] a stage can draw.
  ///
  /// The exact counts are gone — [toJson] keeps a rounded fraction — so they
  /// are reconstructed from it, which is faithful to the same five decimal
  /// places every reader of the file sees.
  static PixelChannel fromJson(Map<String, Object?> json) {
    var width = json['width'] as int? ?? 0;
    var height = json['height'] as int? ?? 0;
    var fraction = (json['changed'] as num?)?.toDouble() ?? 0;
    return PixelChannel(
      PixelDiff(
        width: width,
        height: height,
        comparedPixels: width * height,
        changedPixels: (fraction * width * height).round(),
        sizeChanged: json['sizeChanged'] as bool? ?? false,
        clusters: [
          for (var rect in json['clusters'] as List? ?? const [])
            DiffRect.fromJson((rect as Map).cast<String, Object?>()),
        ],
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'changed': double.parse(diff.fraction.toStringAsFixed(5)),
    'sizeChanged': diff.sizeChanged,
    'width': diff.width,
    'height': diff.height,
    // The eye's jump targets and an agent's coordinates, and capped: a
    // repainted background is thousands of one-pixel specks, and a reader
    // wants the regions rather than the confetti.
    'clusters': [for (var rect in diff.clusters.take(24)) rect.toJson()],
    if (diff.clusters.length > 24) 'clustersDropped': diff.clusters.length - 24,
  };
}

class TreeChannel {
  const TreeChannel(this.diff, {this.skewed = false});

  final TreeDiff diff;

  /// Whether the two trees were read by different versions of the walk —
  /// their `InspectTree.format`s differ.
  ///
  /// A comparison's sides are captured by two checkouts' own
  /// `package:flutterware`, so a branch that bumps it compares one walk's
  /// reading against another's. Measured on a consumer's bump, where only the
  /// docs and the pubspec moved: 109 rows changed, not one pixel, every delta
  /// a `Text.rich` the newer walk had learned to spell out.
  final bool skewed;

  static TreeChannel fromJson(Map<String, Object?> json) => TreeChannel(
    TreeDiff([
      for (var delta in json['deltas'] as List? ?? const [])
        TreeDelta.fromJson((delta as Map).cast<String, Object?>()),
    ]),
    skewed: json['skewed'] == true,
  );

  /// A tree that differs *only* below a resized ancestor has not changed —
  /// something above it did, and that something is already reported.
  bool get changed =>
      diff.deltas.any((delta) => delta.kind != TreeDeltaKind.shifted);

  /// Whether this channel can make a finding: it [changed], and both sides
  /// were read the same way.
  ///
  /// The twin of [EventChannel.significant]. A [skewed] tree is still
  /// compared and its deltas still carried — a real change hides among the
  /// walk's own — but a row it is the whole of stays `same`, and the pixels
  /// and the texts, which no walk produces, still decide.
  bool get significant => changed && !skewed;

  Map<String, Object?> toJson() => {
    if (skewed) 'skewed': skewed,
    'deltas': [for (var delta in diff.deltas.take(50)) delta.toJson()],
    if (diff.deltas.length > 50) 'deltasDropped': diff.deltas.length - 50,
  };
}

/// The visible text, which diffs exactly and costs nothing.
///
/// The cheapest channel and the most legible one in a terminal: a label that
/// changed shows up here as two lines, where the pixel channel can only say
/// what fraction of the screen moved.
class TextChannel {
  const TextChannel({required this.added, required this.removed});

  static TextChannel fromJson(Map<String, Object?> json) => TextChannel(
    added: (json['added'] as List? ?? const []).cast<String>(),
    removed: (json['removed'] as List? ?? const []).cast<String>(),
  );

  factory TextChannel.of({
    required List<String> base,
    required List<String> head,
  }) {
    // Multiset, not set: a list gaining a second "Buy" is a change, and two
    // sets would call it nothing.
    var remaining = <String, int>{};
    for (var text in base) {
      remaining[text] = (remaining[text] ?? 0) + 1;
    }
    var added = <String>[];
    for (var text in head) {
      var left = remaining[text] ?? 0;
      if (left > 0) {
        remaining[text] = left - 1;
      } else {
        added.add(text);
      }
    }
    var removed = [
      for (var entry in remaining.entries)
        for (var i = 0; i < entry.value; i++) entry.key,
    ];
    return TextChannel(added: added, removed: removed);
  }

  final List<String> added;
  final List<String> removed;

  bool get changed => added.isNotEmpty || removed.isNotEmpty;

  Map<String, Object?> toJson() => {'added': added, 'removed': removed};
}

/// What the app did on the way to a step, compared.
///
/// The channel that catches what no picture can: a duplicated request, a new
/// analytics call, an N+1 that appeared because somebody moved a fetch into a
/// builder. None of those change a pixel, and all of them are regressions.
///
/// **Aligned, then diffed field by field** — the same shape [TreeDiff] uses,
/// and for the same reason. This was a multiset over a masked string, which
/// could only ever say *this event is gone, that one arrived*: fold the body
/// into the key and a 4000-character payload differing in one property prints
/// twice in full, leave it out and a `200 → 500` on the same endpoint is
/// silence. There is no setting of that dial that behaves well.
///
/// The mask survives, promoted to the job it was always good at. Collapsing
/// digits is how `/cases/case_0` finds `/cases/case_1`; it is not licence to
/// throw the payload away. Exactly the split [TreeDiff] draws between the
/// signature that matches and the label that reads. Design:
/// `docs/superpowers/specs/2026-08-29-comparison-events-channel-design.md`.
class EventChannel {
  const EventChannel({
    required this.added,
    required this.removed,
    this.deltas = const [],
    this.deltasDropped = 0,
  });

  static EventChannel fromJson(Map<String, Object?> json) => EventChannel(
    added: (json['added'] as List? ?? const []).cast<String>(),
    removed: (json['removed'] as List? ?? const []).cast<String>(),
    deltas: [
      for (var delta in json['deltas'] as List? ?? const [])
        EventDelta.fromJson((delta as Map).cast<String, Object?>()),
    ],
    deltasDropped: json['deltasDropped'] as int? ?? 0,
  );

  factory EventChannel.of({
    required List<Map<String, Object?>> base,
    required List<Map<String, Object?>> head,
  }) {
    var deltas = <EventDelta>[];
    var unpairedBase = <(int, Map<String, Object?>)>[];
    var unpairedHead = <(int, Map<String, Object?>)>[];

    for (var (left, right) in _fuse(_align(base, head))) {
      if (left != null && right != null) {
        deltas.addAll(_diffPair(left.$2, right.$2));
      } else if (left != null) {
        unpairedBase.add(left);
      } else if (right != null) {
        unpairedHead.add(right);
      }
    }

    // What is left over and appears on *both* sides did not come or go — it
    // moved. FakeAsync makes a transition's ordering deterministic, so an auth
    // call that now happens after a data fetch is a real finding rather than a
    // flake, and reporting it as one removal plus one addition of the same
    // string is the nonsense the alignment exists to avoid. An event fed by
    // real I/O is not under FakeAsync, and its order can be the host's; `fw
    // compare` asks a second replay before believing a step that only moved.
    var stillBase = <(int, Map<String, Object?>)>[];
    var byKey = <String, List<(int, Map<String, Object?>)>>{};
    for (var entry in unpairedHead) {
      byKey.putIfAbsent(_key(entry.$2), () => []).add(entry);
    }
    var moved = <(int, Map<String, Object?>)>{};
    for (var entry in unpairedBase) {
      var twins = byKey[_key(entry.$2)];
      if (twins == null || twins.isEmpty) {
        stillBase.add(entry);
        continue;
      }
      var twin = twins.removeAt(0);
      moved.add(twin);
      deltas.add(
        EventDelta(
          kind: EventDeltaKind.moved,
          subchannel: _subchannel(entry.$2),
          title: _title(entry.$2),
          property: 'order',
          base: '#${entry.$1}',
          head: '#${twin.$1}',
          origin: _origin(twin.$2),
        ),
      );
    }

    // `system` after everything else before the cap bites. The doc on
    // [maxEventDeltas] promised the allowance to the channels that earn it,
    // and a plain `take` broke that promise *within* events: a step whose
    // system chatter produced its deltas first evicted the one network delta
    // the step was worth reading for. Order inside each half is preserved —
    // this is a partition, not a sort.
    var ranked = [
      for (var delta in deltas)
        if (delta.subchannel != systemSubchannel) delta,
      for (var delta in deltas)
        if (delta.subchannel == systemSubchannel) delta,
    ];
    return EventChannel(
      added: [
        for (var entry in unpairedHead)
          if (!moved.contains(entry)) mask(entry.$2),
      ],
      removed: [for (var entry in stillBase) mask(entry.$2)],
      deltas: ranked.take(maxEventDeltas).toList(),
      deltasDropped: ranked.length > maxEventDeltas
          ? ranked.length - maxEventDeltas
          : 0,
    );
  }

  /// Events only on head, and only on base, as their masked form.
  ///
  /// Strings rather than deltas, and unchanged from the shape that shipped
  /// first: an older reader of `index.json` sees exactly what it saw before,
  /// and [deltas] is the field it ignores.
  final List<String> added;
  final List<String> removed;

  /// Events both sides made, whose fields disagree — one entry per field.
  ///
  /// Named and written like [TreeChannel]'s, down to [deltasDropped], because
  /// they are the same idea and a reader should not have to learn it twice.
  final List<EventDelta> deltas;

  /// How many deltas [maxEventDeltas] cut. A truncated list that does not say
  /// so reads as a complete one.
  final int deltasDropped;

  bool get changed =>
      added.isNotEmpty || removed.isNotEmpty || deltas.isNotEmpty;

  /// The subchannel the framework's own chatter travels on — platform channel
  /// traffic the app never wrote a line of.
  static const systemSubchannel = 'system';

  /// Whether anything outside the `system` subchannel differs.
  ///
  /// The verdict's half of a rule the read side already applies — *"`system`
  /// is left out unless `channel` names it: it is most of the volume and none
  /// of the signal."* The events design note §6 separated the comparison from
  /// the display and gave the display that default; the verdict kept reading
  /// [changed], so a step whose only difference was a router's per-process
  /// `pageKey` still reported itself a finding. Measured on a consumer's
  /// comment-only diff: 19 of 51 scenarios changed, every delta `system`.
  ///
  /// The chatter is still compared and still carried — [deltas] keeps it, so
  /// a reader chasing a focus or keyboard bug has the door — it just cannot
  /// make a finding on its own.
  bool get significant =>
      added.any((line) => subchannelOf(line) != systemSubchannel) ||
      removed.any((line) => subchannelOf(line) != systemSubchannel) ||
      deltas.any((delta) => delta.subchannel != systemSubchannel);

  /// The channel an `added`/`removed` line travelled on.
  ///
  /// The one place a masked string is taken apart, and it is safe because
  /// [mask] built it: the channel is everything before the first space, and a
  /// channel name never contains one.
  static String subchannelOf(String masked) {
    var space = masked.indexOf(' ');
    return space < 0 ? masked : masked.substring(0, space);
  }

  /// One event reduced to what makes it *that* event, for reading.
  ///
  /// Channel and title with digit-runs collapsed to `#`, because an id in a
  /// path — `/order/8814` — is the commonest way one run's event differs from
  /// another's for no reason worth a line. This is a **pairing key and a
  /// label**, never a comparison key: what two events have to agree on to be
  /// the same event, not what has to agree for nothing to have changed.
  static String mask(Map<String, Object?> event) =>
      '${_subchannel(event)} ${_title(event).replaceAll(RegExp(r'\d+'), '#')}';

  /// The pairing key that is tried *first*: channel and title, verbatim.
  ///
  /// Aligning straight on [mask] is a cascade. An app that requests
  /// `/orders/1` through `/orders/5` has five events sharing one masked key,
  /// so inserting a sixth pairs them all off by one and reports five title
  /// deltas for one insertion — the same failure `#297` removed from drift.
  /// The exact key pairs the five that are identical and leaves the new one
  /// unmatched, which is what it is.
  static String _key(Map<String, Object?> event) =>
      '${_subchannel(event)} ${_title(event)}';

  static String _subchannel(Map<String, Object?> event) =>
      event['channel'] as String? ?? '';

  static String _title(Map<String, Object?> event) =>
      event['title'] as String? ?? '';

  /// Where the app made this event, when it said — never compared, only
  /// carried, so a filter can exclude by file. See the design note §8.
  static String? _origin(Map<String, Object?> event) =>
      event['origin'] as String?;

  /// Pairs events up, longest common subsequence over [_key].
  ///
  /// A sequence alignment rather than a multiset, which is what makes a
  /// reorder visible at all: a multiset compares counts and never order, so an
  /// auth call moving after a data fetch was invisible by construction.
  static List<((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)>
  _align(List<Map<String, Object?>> base, List<Map<String, Object?>> head) {
    // Keyed once, not once per cell. The table is `base.length` by
    // `head.length` and `maxAppEventsPerStep` is 200, so rebuilding the key
    // inside the loop is 80,000 string interpolations to compare 400 events —
    // per step, on every comparison.
    var baseKeys = [for (var event in base) _key(event)];
    var headKeys = [for (var event in head) _key(event)];

    var lengths = List.generate(
      base.length + 1,
      (_) => List.filled(head.length + 1, 0),
    );
    for (var i = base.length - 1; i >= 0; i--) {
      for (var j = head.length - 1; j >= 0; j--) {
        lengths[i][j] = baseKeys[i] == headKeys[j]
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] > lengths[i][j + 1]
                  ? lengths[i + 1][j]
                  : lengths[i][j + 1]);
      }
    }

    var pairs =
        <((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)>[];
    var (i, j) = (0, 0);
    while (i < base.length && j < head.length) {
      if (baseKeys[i] == headKeys[j]) {
        pairs.add(((i, base[i]), (j, head[j])));
        i++;
        j++;
      } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
        pairs.add(((i, base[i]), null));
        i++;
      } else {
        pairs.add((null, (j, head[j])));
        j++;
      }
    }
    while (i < base.length) {
      pairs.add(((i, base[i]), null));
      i++;
    }
    while (j < head.length) {
      pairs.add((null, (j, head[j])));
      j++;
    }
    return pairs;
  }

  /// Takes back the unambiguous half of what the exact key gives up.
  ///
  /// Where a run of leftovers holds exactly one event on each side and the two
  /// share a [mask], only one thing can have happened: the id in the title
  /// moved. Pairing them turns `- /cases/case_0` plus `+ /cases/case_1` into
  /// `title /cases/case_0 → /cases/case_1`, with every other field of the two
  /// still compared.
  ///
  /// One-to-one only. Two same-masked leftovers on a side is a real ambiguity,
  /// and guessing which is which is the nonsense the exact key exists to
  /// refuse. Lifted from `TreeDiff._fuse`, which solved this first.
  static List<((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)>
  _fuse(
    List<((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)> pairs,
  ) {
    var fused =
        <((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)>[];
    var run = <((int, Map<String, Object?>)?, (int, Map<String, Object?>)?)>[];

    void flush() {
      if (run.length > 1) {
        var lefts = [for (var (left, _) in run) ?left];
        var rights = [for (var (_, right) in run) ?right];
        if (lefts.length == 1 &&
            rights.length == 1 &&
            mask(lefts.single.$2) == mask(rights.single.$2)) {
          fused.add((lefts.single, rights.single));
          run.clear();
          return;
        }
      }
      fused.addAll(run);
      run.clear();
    }

    for (var pair in pairs) {
      if (pair.$1 == null || pair.$2 == null) {
        run.add(pair);
      } else {
        flush();
        fused.add(pair);
      }
    }
    flush();
    return fused;
  }

  /// Every field of one paired event that disagrees, as one delta each.
  static List<EventDelta> _diffPair(
    Map<String, Object?> base,
    Map<String, Object?> head,
  ) {
    var deltas = <EventDelta>[];
    var subchannel = _subchannel(head);
    var title = _title(head);
    var origin = _origin(head);

    void report(String property, String? was, String? now) {
      if (was == now) return;
      deltas.add(
        EventDelta(
          kind: EventDeltaKind.changed,
          subchannel: subchannel,
          title: title,
          property: property,
          // Long values are excerpted against each other rather than printed
          // whole. Two four-thousand-character bodies differing in one word
          // is the brittleness that made folding a payload into a comparison
          // key unthinkable; the neighbourhood of where they part is the
          // whole finding.
          //
          // A value with **nothing** to compare against is excerpted too, and
          // that was the hole: a body added where there was none has a null
          // on the other side, so it skipped this and went into `index.json`
          // and the reply at its full four thousand characters.
          base: was == null ? null : firstDifference(was, now ?? ''),
          head: now == null ? null : firstDifference(now, was ?? ''),
          origin: origin,
        ),
      );
    }

    // Only ever different when `_fuse` paired two events across a digit, which
    // is the case this exists to name: a flow that started hitting a different
    // record.
    report('title', _title(base), title);
    report('detail', base['detail'] as String?, head['detail'] as String?);
    report('level', base['level'] as String?, head['level'] as String?);
    // `error` is deliberately not compared. Every named constructor derives it
    // — from the status for a request, from the level for a log — so a delta
    // for it restates the `detail` or `level` delta immediately above it, and
    // doubles the two commonest findings this channel has. It tints a row; it
    // is not a fact of its own.

    var baseLeaves = eventLeaves(base);
    var headLeaves = eventLeaves(head);
    for (var key in {...baseLeaves.keys, ...headLeaves.keys}) {
      report(key, baseLeaves[key], headLeaves[key]);
    }
    return deltas;
  }

  Map<String, Object?> toJson() => {
    'added': added,
    'removed': removed,
    if (deltas.isNotEmpty) 'deltas': [for (var delta in deltas) delta.toJson()],
    if (deltasDropped > 0) 'deltasDropped': deltasDropped,
  };
}

/// How many field deltas one item's events channel keeps.
///
/// Per channel, never shared across them: a step whose `system` chatter moved
/// four hundred times would otherwise eat the allowance `pixels` and `tree`
/// needed, and a reader filtering to a quiet channel would get a truncated
/// list of something that was never noisy.
const maxEventDeltas = 50;

/// What an event's payload is made of, as `data.user.id` → value.
///
/// Flattened rather than compared whole, because a delta saying "`data`
/// changed" repeats one level down the failure this channel exists to fix. The
/// dotted leaf is also the vocabulary a filter excludes by, and the one a
/// reader already uses when talking about a payload. `body` joins them when it
/// parses as JSON, which is the common case for a response and the one where a
/// whole-string diff is least readable.
///
/// **Uncapped, and that is deliberate.** A cap here would be a second one:
/// `AppEvent.toJson` already bounds a payload per leaf against a total budget,
/// at *write* time, before anything compares it. Capping again at read time
/// put a `'…': 'N more fields'` marker into the compared set — so two payloads
/// differing by one field reported `… 5 more fields → 6 more fields` instead
/// of naming the field, and a field inserted early shifted which leaves
/// survived and produced a screenful of phantom ones. That is the derived-count
/// failure the design note §7 is about, reappearing one level above where it
/// was fixed. What bounds the *output* is [maxEventDeltas], which cuts after
/// the comparison rather than before it.
Map<String, String> eventLeaves(Map<String, Object?> event) {
  var out = <String, String>{};
  _flatten('data', event['data'], out);
  var body = event['body'];
  // A db event carries its statement twice — folded into the title, raw in the
  // body — so comparing both reports one changed query as two lines saying the
  // same thing. Where the body *is* the title, the title has it. (A statement
  // long enough for the title's cap to bite escapes this and is reported
  // twice; verbose, rare, and never wrong.)
  if (body is String && _foldWhitespace(body) != event['title']) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map || decoded is List) {
      _flatten('body', decoded, out);
    } else {
      out['body'] = body;
    }
  }
  return out;
}

String _foldWhitespace(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

void _flatten(String prefix, Object? value, Map<String, String> out) {
  if (value is Map) {
    // An emptied map is a change, and a walk that adds no leaf for it would
    // report nothing at all.
    if (value.isEmpty) {
      out[prefix] = '{}';
      return;
    }
    for (var entry in value.entries) {
      _flatten('$prefix.${entry.key}', entry.value, out);
    }
  } else if (value is List) {
    if (value.isEmpty) {
      out[prefix] = '[]';
      return;
    }
    for (var i = 0; i < value.length; i++) {
      _flatten('$prefix[$i]', value[i], out);
    }
  } else if (value != null) {
    out[prefix] = '$value';
  }
}

/// A long string reduced to the neighbourhood of its first difference.
///
/// Two four-thousand-character bodies printed in full is the brittleness that
/// made folding the payload into a comparison key unthinkable; a window either
/// side of where they part is the whole finding. The width is a constant that
/// wants measuring against a real branch — see the design note §12.3.
String firstDifference(String value, String other) {
  if (value.length <= _excerptWindow * 2) return value;
  var at = 0;
  while (at < value.length && at < other.length && value[at] == other[at]) {
    at++;
  }
  var start = (at - _excerptWindow).clamp(0, value.length);
  var end = (at + _excerptWindow).clamp(0, value.length);
  return '${start > 0 ? '…' : ''}'
      '${value.substring(start, end)}'
      '${end < value.length ? '…' : ''}';
}

const _excerptWindow = 40;

/// What kind of disagreement one delta is.
enum EventDeltaKind {
  /// A field of an event both sides made says something different.
  changed,

  /// Both sides made this event and neither side's copy differs — it happened
  /// somewhere else in the sequence.
  moved,
}

/// One field of one event that moved.
///
/// Mirrors [TreeDelta] deliberately: a reader who has learned one has learned
/// the other, and `ChannelLines` already knows how to draw that shape.
///
/// [subchannel], [property] and [origin] are the facets a filter selects on —
/// the half and the channel are already this delta's position in the document,
/// so they are not repeated here. See the design note §9.
class EventDelta {
  const EventDelta({
    required this.kind,
    required this.subchannel,
    required this.title,
    this.property,
    this.base,
    this.head,
    this.origin,
  });

  static EventDelta fromJson(Map<String, Object?> json) => EventDelta(
    kind:
        EventDeltaKind.values.asNameMap()[json['kind']] ??
        EventDeltaKind.changed,
    subchannel: json['subchannel'] as String? ?? '',
    title: json['title'] as String? ?? '',
    property: json['property'] as String?,
    base: json['base'] as String?,
    head: json['head'] as String?,
    origin: json['origin'] as String?,
  );

  final EventDeltaKind kind;

  /// Which channel the event travelled on — `network`, `db`, `log`, `system`.
  final String subchannel;

  /// The event's own one-line summary, uncollapsed: `POST /login`.
  final String title;

  /// Which field disagrees: `detail`, `level`, `data.cartId`, `body.user.role`.
  final String? property;

  final String? base;
  final String? head;

  /// Where the app made the event — `package:app/src/cart.dart Cart.checkout`.
  ///
  /// Carried for filtering and **never compared**: a line number moves when
  /// anything above it moves, so an origin inside the compared set would
  /// report every event as changed on any edit.
  final String? origin;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'subchannel': subchannel,
    'title': title,
    'property': ?property,
    'base': ?base,
    'head': ?head,
    'origin': ?origin,
  };
}

/// One difference, on whichever channel found it.
///
/// The union of what `PixelChannel`, `TreeChannel`, `TextChannel` and
/// `EventChannel` each report, in one shape carrying the facets a reader
/// selects on. `half` is not among them: a delta belongs to an item, and the
/// item already knows which half it is in.
///
/// Nothing computes from this — it is a projection of the channels, built by
/// [ComparedItem.deltas] and thrown away. The channels stay the record.
class ChannelDelta {
  const ChannelDelta({
    required this.channel,
    this.subchannel,
    this.subject,
    this.property,
    this.base,
    this.head,
    this.origin,
  });

  static ChannelDelta fromJson(Map<String, Object?> json) => ChannelDelta(
    channel: json['channel'] as String? ?? '',
    subchannel: json['subchannel'] as String?,
    subject: json['subject'] as String?,
    property: json['property'] as String?,
    base: json['base'] as String?,
    head: json['head'] as String?,
    origin: json['origin'] as String?,
  );

  /// `pixels`, `tree`, `texts` or `events`.
  final String channel;

  /// For an event, the channel it travelled on — `network`, `db`, `log`,
  /// `system`. Null on every other channel.
  final String? subchannel;

  /// What the difference is *about*: a widget's path through the tree, or an
  /// event's own one-line summary. Null where the property says it all.
  final String? subject;

  /// Which field moved — `size`, `detail`, `data.cart.id` — or, where nothing
  /// moved but something arrived or left, `added`, `removed` or `moved`.
  final String? property;

  final String? base;
  final String? head;

  /// Where the app made the event, for an event that said. Never a fact about
  /// the difference; a fact about where to go and look. See the design note §8.
  final String? origin;

  Map<String, Object?> toJson() => {
    'channel': channel,
    'subchannel': ?subchannel,
    'subject': ?subject,
    'property': ?property,
    'base': ?base,
    'head': ?head,
    'origin': ?origin,
  };
}

/// One *shape* of difference, and how much of a comparison wore it.
///
/// Measured on this repository on 2026-08-30: a comparison whose events
/// channel reported eleven deltas reported **one** shape — the same
/// subchannel, the same subject and the same property, eleven times over,
/// differing only in an identity hash. Eleven lines that are one fact, and a
/// channel filter can only ever show or hide all eleven together.
///
/// So repetition is folded before anything is filtered: the reader sees
/// `system · TextInput.setClient · autofill.uniqueIdentifier   11 steps` and
/// can then decide about it. It is also what makes a filter *aimable* — a rule
/// authored by pointing at a folded row already names the shape, where
/// pointing at one of eleven identical lines names an accident.
class FoldedDelta {
  const FoldedDelta({
    required this.delta,
    required this.count,
    required this.items,
  });

  /// The first occurrence, standing for all of them.
  ///
  /// Its [ChannelDelta.channel], [ChannelDelta.subchannel],
  /// [ChannelDelta.subject] and [ChannelDelta.property] are what the fold
  /// grouped on and are true of every occurrence. Its `base` and `head` are
  /// **one example of [count]** — deliberately kept, because a shape with no
  /// value attached to it cannot be judged.
  final ChannelDelta delta;

  /// How many deltas folded into this row.
  final int count;

  /// How many of the compared things carried it — steps, or entries.
  ///
  /// Not the same as [count] and the more useful of the two in a verdict: four
  /// text fields on one screen is one step's problem, and one text field on
  /// four screens is the suite's.
  final int items;

  bool get repeated => count > 1;
}

/// Groups deltas by their shape, keeping the order they were built in.
///
/// [perItem] is one list per compared thing, which is what lets [items] mean
/// anything: folding one item's deltas is `foldChannelDeltas([item.deltas])`
/// and every row comes back with `items: 1`, harmlessly.
///
/// **Input order is kept**, most-repeated *not* first. `ComparedItem.deltas`
/// already builds in channel order — pixels, tree, texts, events — and ranking
/// by count would put the noisiest shape at the top of every report, which is
/// the opposite of what a reader wants. What handles the noise is the count on
/// the row and the channel it names, not its position.
List<FoldedDelta> foldChannelDeltas(Iterable<List<ChannelDelta>> perItem) {
  var order = <String>[];
  var first = <String, ChannelDelta>{};
  var counts = <String, int>{};
  var items = <String, int>{};

  for (var deltas in perItem) {
    var seenHere = <String>{};
    for (var delta in deltas) {
      // Base and head are pointedly not in the key: an identity hash that
      // differs on every occurrence is the case this exists for, and grouping
      // on the value would put every occurrence in a group of its own.
      var key = [
        delta.channel,
        delta.subchannel ?? '',
        delta.subject ?? '',
        delta.property ?? '',
      ].join('\u0000');
      if (first.putIfAbsent(key, () => delta) == delta && counts[key] == null) {
        order.add(key);
      }
      counts[key] = (counts[key] ?? 0) + 1;
      if (seenHere.add(key)) items[key] = (items[key] ?? 0) + 1;
    }
  }

  return [
    for (var key in order)
      FoldedDelta(delta: first[key]!, count: counts[key]!, items: items[key]!),
  ];
}
