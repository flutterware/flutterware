import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/message_banner.dart';
import 'package:flutterware_app/src/world/platform/studio_platform.dart';
import 'package:flutterware_app/src/world/world_messages.dart';
import 'package:flutterware_app/src/world/world_trace.dart';

import 'app_theme.dart';

/// What reaches a person in a world: the banner that comes down on their
/// screen, and the rows of their Messages tab.

@Preview(name: 'Message banners', group: 'Worlds', wrapper: wrapInAppTheme)
Widget messageBanners() => const _Banners();

@Preview(
  name: 'Message banners · dark',
  group: 'Worlds',
  wrapper: wrapInDarkTheme,
)
Widget messageBannersDark() => const _Banners();

@Preview(name: 'Messages', group: 'Worlds', wrapper: wrapInAppTheme)
Widget messages() => const _Inbox();

@Preview(name: 'Messages · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget messagesDark() => const _Inbox();

final _at = DateTime(2026, 10, 28, 23, 49);

final _code = Received.message(
  OutboxMessage(
    id: 'lab/1',
    at: _at,
    kind: 'sms',
    to: '+447700900000',
    text: 'Your pickup code is 428500',
    person: 'Leo',
    sender: 'lab',
    code: '428500',
  ),
);

final _push = Received.message(
  OutboxMessage(
    id: 'lab/2',
    at: _at.add(const Duration(minutes: 3)),
    kind: 'push',
    to: 'u1',
    text: 'Your flat white is ready',
    body: 'Order o3 is at the counter.',
    person: 'Leo',
    sender: 'lab',
    link: 'worldlab://orders/o3',
  ),
);

final _mail = Received.message(
  OutboxMessage(
    id: 'lab/3',
    at: _at.add(const Duration(minutes: 1)),
    kind: 'mail',
    to: 'leo@example.com',
    text: 'Welcome to Pickup',
    body: 'Thanks for signing up, Leo. Your first coffee is on us.',
    person: 'Leo',
    sender: 'lab',
  ),
);

final _notification = Received.notification(
  GuestNotification(
    1,
    'Your cortado is ready',
    'Collect it at the counter.',
    null,
  ),
);

Future<void> _nothing([String _ = '']) async {}

class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 369,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var banner in [
                MessageBanner(
                  received: _code,
                  app: 'Lab',
                  onTap: () {},
                  onEnterCode: _nothing,
                ),
                MessageBanner(received: _push, app: 'Lab', onTap: () {}),
                MessageBanner(received: _mail, app: 'Lab', onTap: () {}),
                MessageBanner(
                  received: _code,
                  app: 'Lab',
                  refused:
                      "Tap the code field in Leo's app first, then try "
                      'again.',
                  onEnterCode: _nothing,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: FwSpacing.sm),
                  child: banner,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Inbox extends StatelessWidget {
  const _Inbox();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MessageRow(
              received: _push,
              app: 'Lab',
              unread: true,
              onDeliver: _nothing,
            ),
            MessageRow(
              received: _notification,
              app: 'Lab',
              unread: true,
              onOpenNotification: () {},
            ),
            MessageRow(
              received: _mail,
              app: 'Lab',
              unread: true,
              onRead: () {},
            ),
            MessageRow(
              received: _code,
              app: 'Lab',
              unread: false,
              onDeliver: _nothing,
            ),
          ],
        ),
      ),
    ),
  );
}
