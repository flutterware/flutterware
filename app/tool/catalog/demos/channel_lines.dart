import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/ui/channel_lines.dart';

import 'app_theme.dart';

/// What a comparison says in words, once the events channel can say which
/// field moved.
///
/// The three prose channels in one column, so the event lines can be read
/// against the tree lines they are meant to sit beside: the same idiom on
/// every row — subject, field, then the old value on the removed tint and
/// the new one on the added tint, `network  POST /login  detail  200 → 500`.
@Preview(name: 'Channel lines', group: 'Comparison', wrapper: wrapInAppTheme)
Widget channelLines() => ChannelLines(_item);

@Preview(
  name: 'Channel lines · dark',
  group: 'Comparison',
  wrapper: wrapInDarkTheme,
)
Widget channelLinesDark() => ChannelLines(_item);

EventDelta _delta({
  required String subchannel,
  required String title,
  String? property,
  EventDeltaKind kind = EventDeltaKind.changed,
  String? base,
  String? head,
}) => EventDelta(
  kind: kind,
  subchannel: subchannel,
  title: title,
  property: property,
  base: base,
  head: head,
);

final _item = ComparedItem(
  id: 'demo/checkout.dart#checkout',
  state: ComparedState.changed,
  tree: TreeChannel(
    const TreeDiff([
      TreeDelta(
        kind: TreeDeltaKind.changed,
        path: 'Card › Padding',
        property: 'size',
        base: '328×96',
        head: '328×120',
      ),
    ]),
  ),
  texts: const TextChannel(added: ['Pay'], removed: ['Save']),
  events: EventChannel(
    added: const ['network POST /verify'],
    removed: const [],
    deltas: [
      _delta(
        subchannel: 'log',
        title: 'card declined',
        property: 'level',
        base: 'INFO',
        head: 'WARNING',
      ),
      _delta(
        subchannel: 'network',
        title: 'POST /login',
        property: 'detail',
        base: '200',
        head: '500',
      ),
      _delta(
        subchannel: 'db',
        title: 'select * from cases where id = 1',
        property: 'title',
        base: 'select * from cases where id = 1',
        head: 'select * from cases where id = 2',
      ),
      _delta(
        subchannel: 'analytics',
        title: 'checkout',
        property: 'data.cart.id',
        base: 'a1',
        head: 'b7',
      ),
      _delta(
        subchannel: 'network',
        title: 'GET /me',
        property: 'body.user.role',
        base: 'member',
        head: 'admin',
      ),
      _delta(
        subchannel: 'system',
        title: 'flutter/textinput TextInput.setClient',
        kind: EventDeltaKind.moved,
        base: '#4',
        head: '#9',
      ),
      // The shape measured on this repository: one fact wearing four lines,
      // differing only in an identity hash.
      for (var hash in ['1047800503', '14348167', '936512157', '220435757'])
        _delta(
          subchannel: 'system',
          title: 'flutter/textinput TextInput.setClient',
          property: 'data.arguments[1].autofill.uniqueIdentifier',
          base: 'EditableText-$hash',
          head: 'EditableText-',
        ),
    ],
    deltasDropped: 12,
  ),
);
