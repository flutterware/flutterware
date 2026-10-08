import 'dart:typed_data';

import 'package:flutterware/app_events.dart';
import 'package:flutterware/comparison_report.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:test/test.dart';

/// One thing compared on every channel that had something to say, and the
/// verdict that comes out of them.
void main() {
  Uint8List frame(int value) => Uint8List(4 * 4 * 4)..fillRange(0, 64, value);

  PixelDiff pixels({int base = 0, int head = 0}) => PixelDiff.of(
    base: frame(base),
    baseWidth: 4,
    baseHeight: 4,
    head: frame(head),
    headWidth: 4,
    headHeight: 4,
  );

  InspectNode node(String type, {String? description}) => InspectNode(
    id: '',
    type: type,
    description: description,
    createdByLocalProject: true,
    children: const [],
  );

  test('nothing on any channel is the same picture', () {
    var item = ComparedItem.of(id: 'a#b', pixels: pixels());

    expect(item.state, ComparedState.same);
    expect(item.texts, isNull);
  });

  test('a changed channel is enough to make the item changed', () {
    var item = ComparedItem.of(id: 'a#b', pixels: pixels(head: 255));

    expect(item.state, ComparedState.changed);
    expect(item.toJson()['channels'], isA<Map<String, Object?>>());
  });

  // The text channel costs nothing and is the most legible one in a terminal:
  // pixels can only say what fraction of the screen moved.
  test('text alone can carry the finding', () {
    var item = ComparedItem.of(
      id: 'a#b',
      pixels: pixels(),
      baseTexts: ['Save'],
      headTexts: ['Pay'],
    );

    expect(item.state, ComparedState.changed);
    expect(item.texts!.added, ['Pay']);
    expect(item.texts!.removed, ['Save']);
  });

  // A list gaining a second "Buy" is a change, and two sets would call it
  // nothing.
  test('a repeated text is counted, not deduplicated', () {
    var channel = TextChannel.of(base: ['Buy'], head: ['Buy', 'Buy']);

    expect(channel.added, ['Buy']);
    expect(channel.removed, isEmpty);
  });

  test('a reordered text list is not a change', () {
    var channel = TextChannel.of(base: ['A', 'B'], head: ['B', 'A']);

    expect(channel.changed, isFalse);
  });

  // A tree that differs only below a resized ancestor has not changed;
  // something above it did, and that is already reported.
  test('a tree of nothing but shifts is not itself a change', () {
    var channel = TreeChannel(
      const TreeDiff([
        TreeDelta(
          kind: TreeDeltaKind.shifted,
          path: 'Column › Text',
          property: 'offset',
          base: '0,20',
          head: '0,44',
        ),
      ]),
    );

    expect(channel.changed, isFalse);
  });

  test('a tree delta alone can carry the finding', () {
    var item = ComparedItem.of(
      id: 'a#b',
      pixels: pixels(),
      tree: TreeDiff.of(
        node('Text', description: 'Text("Save")'),
        node('Text', description: 'Text("Pay")'),
      ),
    );

    expect(item.state, ComparedState.changed);
  });

  // Measured on a branch that only bumped flutterware: 109 rows changed and
  // not one pixel moved, every delta a `Text.rich` the newer walk had learned
  // to spell out. Two walks' readings are carried, and do not decide.
  group('a tree read by two versions of the walk', () {
    ComparedItem skewed({int head = 0}) => ComparedItem.of(
      id: 'a#b',
      pixels: pixels(head: head),
      tree: TreeDiff.of(
        node('Text', description: null),
        node('Text', description: 'Text("Pay")'),
      ),
      treeSkewed: true,
    );

    test('does not make a finding on its own', () {
      var item = skewed();

      expect(item.state, ComparedState.same);
      expect(item.channelsFired, isEmpty);
    });

    test('is still carried, for a reader to look at', () {
      var item = skewed();

      expect(item.tree!.changed, isTrue);
      expect(item.tree!.significant, isFalse);
      expect(item.deltas.map((d) => d.channel), ['tree']);
    });

    test('leaves the pixels to decide', () {
      var item = skewed(head: 255);

      expect(item.state, ComparedState.changed);
      expect(item.channelsFired, ['pixels']);
    });

    test('survives the file', () {
      var read = ComparedItem.fromJson(skewed().toJson());

      expect(read.tree!.skewed, isTrue);
      expect(read.tree!.diff.deltas, isNotEmpty);
    });
  });

  group('the severity ladder', () {
    // The one result the tool exists to catch: a percentage next to it would
    // be answering a smaller question.
    test('a head that stopped rendering outranks everything', () {
      var item = ComparedItem.of(
        id: 'a#b',
        headRendered: false,
        pixels: pixels(head: 255),
      );

      expect(item.state, ComparedState.broke);
      expect(item.note, contains('throws here'));
      expect(item.pixels, isNull);
    });

    test('a base that never rendered is said once, quietly', () {
      var item = ComparedItem.of(id: 'a#b', baseRendered: false);

      expect(item.state, ComparedState.wasBroken);
      expect(item.note, contains('already broken'));
    });

    test('neither side rendering is its own state', () {
      var item = ComparedItem.of(
        id: 'a#b',
        baseRendered: false,
        headRendered: false,
      );

      expect(item.state, ComparedState.failed);
    });

    test('the states are declared worst-first, so a sort is a ranking', () {
      expect(
        ComparedState.broke.index,
        lessThan(ComparedState.wasBroken.index),
      );
      expect(ComparedState.changed.index, lessThan(ComparedState.same.index));
      expect(ComparedState.same.index, lessThan(ComparedState.skipped.index));
    });
  });

  test('the json says the state, and the channels when there are any', () {
    var json = ComparedItem.of(
      id: 'demo/card.dart#card',
      label: 'Card',
      pixels: pixels(head: 255),
      baseTexts: ['Save'],
      headTexts: ['Pay'],
    ).toJson();

    expect(json['id'], 'demo/card.dart#card');
    expect(json['state'], 'changed');
    expect(json['label'], 'Card');
    var channels = json['channels']! as Map<String, Object?>;
    expect(channels['pixels'], isNotNull);
    expect(channels['texts'], isNotNull);
    expect(channels.containsKey('tree'), isFalse);
  });

  group('db events are told apart by their statement', () {
    /// Two different statements, both formatted the way a person formats
    /// them: the keyword alone on the first line.
    AppEvent tasks() => AppEvent.query(
      sql: 'select\n  t.*,\n  count(te.id)\nfrom task as t\nwhere t.done is null',
    );
    AppEvent users() =>
        AppEvent.query(sql: 'select\n  u.id,\n  u.email\nfrom users as u');

    test('a branch that swapped one query for another says so', () {
      // `mask` keys an event on its channel and its title. While `AppEvent
      // .query` titled from the first line, both of these were `db select …`
      // — one key — and this diff came back empty: a silent false negative,
      // on the channel whose entire job is to notice.
      var diff = EventChannel.of(
        base: [tasks().toJson()],
        head: [users().toJson()],
      );

      expect(diff.added, hasLength(1));
      expect(diff.removed, hasLength(1));
      expect(diff.added.single, contains('users'));
      expect(diff.removed.single, contains('task'));
    });

    test('the same query on both sides is still no change', () {
      var diff = EventChannel.of(
        base: [tasks().toJson()],
        head: [tasks().toJson()],
      );

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('an N+1 sibling still meets its twin, because digits fold', () {
      // Folding whitespace keeps the literals, so pairing leans on `mask`'s
      // digits-to-`#` rule exactly as it did before: the two meet, and neither
      // is reported as having come or gone.
      //
      // What they no longer do is meet *silently*. The id is the whole
      // difference between them, and under the multiset it vanished into the
      // key — which is the same hole that let a flow start hitting a different
      // record and report nothing. Paired and then diffed, the pairing is kept
      // and the difference is named.
      var diff = EventChannel.of(
        base: [AppEvent.query(sql: 'select * from t\nwhere id = 1').toJson()],
        head: [AppEvent.query(sql: 'select * from t\nwhere id = 2').toJson()],
      );

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.deltas.single.property, 'title');
      expect(diff.deltas.single.base, contains('id = 1'));
      expect(diff.deltas.single.head, contains('id = 2'));
    });
  });

  group('the events channel says which field moved', () {
    Map<String, Object?> log(String message, {String? level}) =>
        AppEvent.log(message, level: level).toJson();

    Map<String, Object?> request(String url, {int? status}) =>
        AppEvent.request(method: 'POST', url: url, status: status).toJson();

    // The finding a consumer's branch actually contained, and the one the
    // masked multiset reported as no change at all: two `_logger.info` calls
    // became `_logger.warning`, on steps whose pixels were byte-identical.
    test('a log level moving is the finding, not silence', () {
      var diff = EventChannel.of(
        base: [log('card declined', level: 'INFO')],
        head: [log('card declined', level: 'WARNING')],
      );

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.changed, isTrue);
      var delta = diff.deltas.single;
      expect(delta.subchannel, 'log');
      expect(delta.property, 'level');
      expect(delta.base, 'INFO');
      expect(delta.head, 'WARNING');
    });

    test('a status flip on one endpoint is one line, not two events', () {
      var diff = EventChannel.of(
        base: [request('/login', status: 200)],
        head: [request('/login', status: 500)],
      );

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.deltas.single.property, 'detail');
      expect(diff.deltas.single.base, '200');
      expect(diff.deltas.single.head, '500');
    });

    test('a payload is compared leaf by leaf, not as one blob', () {
      var diff = EventChannel.of(
        base: [
          AppEvent.analytics(
            'checkout',
            params: {
              'cart': {'id': 'a1', 'items': 2},
            },
          ).toJson(),
        ],
        head: [
          AppEvent.analytics(
            'checkout',
            params: {
              'cart': {'id': 'b7', 'items': 2},
            },
          ).toJson(),
        ],
      );

      expect(diff.deltas.single.property, 'data.cart.id');
      expect(diff.deltas.single.base, 'a1');
      expect(diff.deltas.single.head, 'b7');
    });

    test('a JSON body is leaves too, so one field reads as one line', () {
      var diff = EventChannel.of(
        base: [
          AppEvent.custom(
            channel: AppChannel.network,
            title: 'GET /me',
            body: '{"user":{"role":"member","id":7}}',
          ).toJson(),
        ],
        head: [
          AppEvent.custom(
            channel: AppChannel.network,
            title: 'GET /me',
            body: '{"user":{"role":"admin","id":7}}',
          ).toJson(),
        ],
      );

      expect(diff.deltas.single.property, 'body.user.role');
      expect(diff.deltas.single.base, 'member');
      expect(diff.deltas.single.head, 'admin');
    });

    // The brittleness that made folding the payload into a key unthinkable:
    // two long bodies differing in one word, printed twice in full.
    test('a body that is not JSON reports where it parts, not all of it', () {
      var base = '${'x' * 200}ALPHA${'y' * 200}';
      var head = '${'x' * 200}OMEGA${'y' * 200}';
      var diff = EventChannel.of(
        base: [
          AppEvent.custom(channel: 'wire', title: 'frame', body: base).toJson(),
        ],
        head: [
          AppEvent.custom(channel: 'wire', title: 'frame', body: head).toJson(),
        ],
      );

      var delta = diff.deltas.single;
      expect(delta.property, 'body');
      expect(delta.base, contains('ALPHA'));
      expect(delta.head, contains('OMEGA'));
      expect(delta.base!.length, lessThan(base.length));
      expect(delta.base, startsWith('…'));
    });

    // A multiset compares counts and never order, so this was invisible by
    // construction. FakeAsync makes a transition's ordering deterministic,
    // which is what makes it a finding rather than a flake.
    test('an auth call moving after a data fetch is reported as moved', () {
      var diff = EventChannel.of(
        base: [request('/auth'), request('/items')],
        head: [request('/items'), request('/auth')],
      );

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.deltas.single.kind, EventDeltaKind.moved);
      expect(diff.deltas.single.property, 'order');
    });

    // Aligning straight on the masked key is the cascade `#297` removed from
    // drift: five events share one masked key, so a sixth pairs them all off
    // by one and reports five title deltas for one insertion.
    test('one inserted request is one addition, not a renumbering', () {
      var diff = EventChannel.of(
        base: [for (var i = 1; i <= 5; i++) request('/orders/$i')],
        head: [for (var i = 1; i <= 6; i++) request('/orders/$i')],
      );

      expect(diff.added, ['network POST /orders/#']);
      expect(diff.removed, isEmpty);
      expect(diff.deltas, isEmpty);
    });

    test('identical events on both sides say nothing at all', () {
      var events = [request('/login', status: 200), log('ready')];
      var diff = EventChannel.of(base: events, head: events);

      expect(diff.changed, isFalse);
      expect(diff.deltas, isEmpty);
    });

    // Per channel, never shared: a step whose system chatter moved four
    // hundred times would otherwise eat the allowance pixels and tree needed.
    test('the delta list is capped and says how much it cut', () {
      var diff = EventChannel.of(
        base: [for (var i = 0; i < 80; i++) log('line $i', level: 'INFO')],
        head: [for (var i = 0; i < 80; i++) log('line $i', level: 'WARNING')],
      );

      expect(diff.deltas, hasLength(maxEventDeltas));
      expect(diff.deltasDropped, 80 - maxEventDeltas);
    });

    // A line number moves when anything above it moves, so an origin inside
    // the compared set would report every event as changed on any edit.
    test('the origin rides along and is never itself compared', () {
      var diff = EventChannel.of(
        base: [
          {
            'channel': 'db',
            'title': 'select * from t',
            'origin': 'package:app/src/cache.dart Cache.read',
          },
        ],
        head: [
          {
            'channel': 'db',
            'title': 'select * from t',
            'origin': 'package:app/src/store.dart Store.read',
          },
        ],
      );

      expect(diff.changed, isFalse);
      expect(diff.deltas, isEmpty);
    });

    test('an added line still says which channel it was on', () {
      expect(EventChannel.subchannelOf('network POST /verify'), 'network');
    });

    // The read side's rule, arrived at the verdict: `system` is most of the
    // volume and none of the signal. A router mints a fresh `pageKey` per
    // process and no project can pin it — measured on a consumer's
    // comment-only diff, 19 of 51 scenarios reported a finding and every
    // delta was `system`.
    group('system chatter is compared but decides nothing', () {
      Map<String, Object?> system(String title, {String? detail}) => {
        'channel': 'system',
        'title': title,
        'detail': ?detail,
      };

      test('a step whose only difference is system stays same', () {
        var item = ComparedItem.of(
          id: 'a#b',
          baseEvents: [system('flutter/navigation', detail: 'yi_iit')],
          headEvents: [system('flutter/navigation', detail: 'rhsu_hl')],
        );

        expect(item.state, ComparedState.same);
        expect(item.channelsFired, isEmpty);
        // Carried, not erased: the deltas are the door for whoever is
        // chasing a focus or keyboard bug.
        expect(item.events!.deltas, isNotEmpty);
        expect(item.events!.significant, isFalse);
      });

      test('a system line that came or went decides nothing either', () {
        var item = ComparedItem.of(
          id: 'a#b',
          headEvents: [system('flutter/assets')],
        );

        expect(item.state, ComparedState.same);
        expect(item.events!.added, ['system flutter/assets']);
      });

      test('one real delta among the chatter is still a finding', () {
        var item = ComparedItem.of(
          id: 'a#b',
          baseEvents: [
            system('flutter/navigation', detail: 'yi_iit'),
            request('/login', status: 200),
          ],
          headEvents: [
            system('flutter/navigation', detail: 'rhsu_hl'),
            request('/login', status: 500),
          ],
        );

        expect(item.state, ComparedState.changed);
        expect(item.channelsFired, ['events']);
      });

      // The doc on [maxEventDeltas] promised the allowance to the channels
      // that earn it; a plain `take` let sixty focus changes evict the one
      // status flip the step was worth reading for.
      test('the cap spends its allowance on the other subchannels first', () {
        var diff = EventChannel.of(
          base: [
            for (var i = 0; i < 60; i++) system('probe $i', detail: 'a'),
            request('/login', status: 200),
          ],
          head: [
            for (var i = 0; i < 60; i++) system('probe $i', detail: 'b'),
            request('/login', status: 500),
          ],
        );

        expect(diff.deltas.first.subchannel, 'network');
        expect(diff.deltas, hasLength(maxEventDeltas));
        expect(diff.deltasDropped, 61 - maxEventDeltas);
      });
    });
  });

  // The seam between the model and the UI pass: a filter can only ever select
  // on facets the comparison recorded.
  group('the facet contract', () {
    ComparedItem item() => ComparedItem.of(
      id: 'a#b',
      pixels: pixels(head: 255),
      tree: TreeDiff.of(
        node('Text', description: 'Text("Save")'),
        node('Text', description: 'Text("Pay")'),
      ),
      baseTexts: ['Save'],
      headTexts: ['Pay'],
      baseEvents: [
        AppEvent.log('card declined', level: 'INFO').toJson(),
        AppEvent.request(method: 'GET', url: '/gone').toJson(),
      ],
      headEvents: [
        AppEvent.log('card declined', level: 'WARNING').toJson(),
        AppEvent.request(method: 'GET', url: '/new').toJson(),
      ],
    );

    test('every channel reaches the flat list, pixels included', () {
      expect(
        {for (var delta in item().deltas) delta.channel},
        {'pixels', 'tree', 'texts', 'events'},
      );
    });

    // Without a line of its own the channel that fires most often would be
    // invisible to a per-channel count.
    test('the pixel channel contributes one line carrying its size', () {
      var pixel = item().deltas.firstWhere((d) => d.channel == 'pixels');

      expect(pixel.property, 'changed');
      expect(pixel.head, contains('%'));
    });

    test('an event delta keeps its subchannel and what moved', () {
      var level = item().deltas.firstWhere((d) => d.property == 'level');

      expect(level.channel, 'events');
      expect(level.subchannel, 'log');
      expect(level.base, 'INFO');
      expect(level.head, 'WARNING');
    });

    // An added or removed event is a finding too, and a reader excluding a
    // channel has to be able to exclude those with it.
    test('an added event says which channel it arrived on', () {
      var added = item().deltas.firstWhere(
        (d) => d.channel == 'events' && d.property == 'added',
      );

      expect(added.subchannel, 'network');
      expect(added.subject, contains('/new'));
    });

    test('a text that came or went is a delta like any other', () {
      var texts = item().deltas.where((d) => d.channel == 'texts');

      expect(texts.map((d) => d.property), containsAll(['added', 'removed']));
      expect(texts.map((d) => d.head ?? d.base), containsAll(['Pay', 'Save']));
    });

    // A tree that moved only because something above it grew has not changed,
    // and a count built off this list must not think it has.
    test('a shifted tree node is not in the list', () {
      var shifted = ComparedItem(
        id: 'a#b',
        state: ComparedState.same,
        tree: TreeChannel(
          const TreeDiff([
            TreeDelta(
              kind: TreeDeltaKind.shifted,
              path: 'Column › Text',
              property: 'offset',
              base: '0,20',
              head: '0,44',
            ),
          ]),
        ),
      );

      expect(shifted.deltas, isEmpty);
    });

    test('an item with nothing to say has an empty list, not a null one', () {
      expect(ComparedItem.of(id: 'a#b', pixels: pixels()).deltas, isEmpty);
    });

    test('a delta round-trips through its json', () {
      var delta = item().deltas.firstWhere((d) => d.property == 'level');
      var back = ChannelDelta.fromJson(delta.toJson());

      expect(back.channel, delta.channel);
      expect(back.subchannel, delta.subchannel);
      expect(back.property, delta.property);
      expect(back.base, delta.base);
      expect(back.head, delta.head);
    });
  });

  // Measured on this repository: a comparison whose events channel reported
  // eleven deltas reported one *shape*, eleven times over. Eleven lines that
  // are one fact.
  group('folding', () {
    ChannelDelta autofill(String hash) => ChannelDelta(
      channel: 'events',
      subchannel: 'system',
      subject: 'flutter/textinput TextInput.setClient',
      property: 'data.arguments[1].autofill.uniqueIdentifier',
      base: 'EditableText-$hash',
      head: 'EditableText-',
    );

    test('one shape across many items is one row that counts both', () {
      var folded = foldChannelDeltas([
        [autofill('1047800503')],
        [autofill('14348167')],
        [autofill('936512157'), autofill('220435757')],
      ]);

      expect(folded, hasLength(1));
      expect(folded.single.count, 4);
      expect(folded.single.items, 3);
      expect(folded.single.repeated, isTrue);
    });

    // The value differing on every occurrence is the case this exists for, so
    // grouping on it would put each one in a group of its own.
    test('the differing value is not part of the shape', () {
      var folded = foldChannelDeltas([
        [autofill('1'), autofill('2'), autofill('3')],
      ]);

      expect(folded.single.count, 3);
      expect(folded.single.items, 1);
    });

    // A shape with no value attached to it cannot be judged.
    test('the row keeps one example of the values it folded', () {
      var folded = foldChannelDeltas([
        [autofill('1047800503'), autofill('14348167')],
      ]);

      expect(folded.single.delta.base, 'EditableText-1047800503');
      expect(folded.single.delta.head, 'EditableText-');
    });

    test('different properties on one subject stay apart', () {
      var folded = foldChannelDeltas([
        [
          const ChannelDelta(
            channel: 'events',
            subchannel: 'network',
            subject: 'POST /login',
            property: 'detail',
            base: '200',
            head: '500',
          ),
          const ChannelDelta(
            channel: 'events',
            subchannel: 'network',
            subject: 'POST /login',
            property: 'data.token',
            base: 'a',
            head: 'b',
          ),
        ],
      ]);

      expect(folded, hasLength(2));
      expect(folded.every((row) => row.count == 1), isTrue);
    });

    // Ranking by count would put the noisiest shape at the top of every
    // report, which is the opposite of what a reader wants.
    test('input order is kept, not count order', () {
      var folded = foldChannelDeltas([
        [
          const ChannelDelta(channel: 'pixels', property: 'changed'),
          autofill('1'),
          autofill('2'),
        ],
      ]);

      expect(folded.map((row) => row.delta.channel), ['pixels', 'events']);
      expect(folded.map((row) => row.count), [1, 2]);
    });

    test('nothing folds to nothing', () {
      expect(foldChannelDeltas(const []), isEmpty);
      expect(foldChannelDeltas([<ChannelDelta>[]]), isEmpty);
    });
  });

  // Two caps on one payload, the second applied *after* the write and so
  // *before* the comparison, puts an "N more fields" count into what is
  // compared, and the diff reports the count instead of the field.
  group('a payload is capped once, at write time', () {
    Map<String, Object?> wide(int fields, {String tail = 'x'}) => {
      'channel': 'analytics',
      'title': 'checkout',
      'data': {for (var i = 0; i < fields; i++) 'f$i': 'v$i', 'tail': tail},
    };

    test('a payload wider than any read-time cap still names its field', () {
      var diff = EventChannel.of(
        base: [wide(40)],
        head: [wide(40, tail: 'y')],
      );

      expect(diff.deltas.single.property, 'data.tail');
      expect(diff.deltas.single.base, 'x');
      expect(diff.deltas.single.head, 'y');
    });

    // It reported `…  39 more fields → 40 more fields` and named nothing.
    test('a field added to a wide payload is the field, not a count', () {
      var diff = EventChannel.of(
        base: [wide(40)],
        head: [
          {
            'channel': 'analytics',
            'title': 'checkout',
            'data': {
              for (var i = 0; i < 40; i++) 'f$i': 'v$i',
              'tail': 'x',
              'extra': 'new',
            },
          },
        ],
      );

      expect(diff.deltas.single.property, 'data.extra');
      expect(diff.deltas.map((d) => d.property), isNot(contains('…')));
    });
  });

  // A value with nothing on the other side skipped the excerpt entirely, so a
  // body added where there was none went into `index.json` and the MCP reply
  // at its full four thousand characters.
  test('a value added where there was none is excerpted too', () {
    var long = 'z' * 3000;
    var diff = EventChannel.of(
      base: [
        {'channel': 'network', 'title': 'GET /me'},
      ],
      head: [
        {'channel': 'network', 'title': 'GET /me', 'body': long},
      ],
    );

    var delta = diff.deltas.single;
    expect(delta.property, 'body');
    expect(delta.base, isNull);
    expect(delta.head!.length, lessThan(200));
    expect(delta.head, endsWith('…'));
  });
}
