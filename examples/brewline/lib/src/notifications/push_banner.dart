import 'package:material_ui/material_ui.dart';

import 'push_service.dart';

/// Stable identities for the banner, so a scenario or a drive step can reach
/// it without knowing what the notification says.
class PushKeys {
  static const banner = Key('push.banner');
  static const open = Key('push.open');
  static const dismiss = Key('push.dismiss');
}

/// The notification the app is currently showing over itself.
///
/// In the tree rather than in a platform overlay, and that is the interesting
/// part: it means a screenshot has it, `observe` lists its text, and an agent
/// can tap it. A real OS banner would be none of those things.
class PushBanner extends StatelessWidget {
  const PushBanner({super.key, required this.service});

  final PushService service;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        var message = service.banner;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: message == null
              ? const SizedBox.shrink()
              : _Card(
                  key: ValueKey(message.id),
                  service: service,
                  message: message,
                ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.service, required this.message});

  final PushService service;
  final PushMessage message;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var body = message.body;
    var link = message.link;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Material(
          key: PushKeys.banner,
          color: scheme.surfaceContainerHighest,
          elevation: 8,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: PushKeys.open,
            onTap: link == null ? null : () => service.open(message.id),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('☕', style: TextStyle(fontSize: 17)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (body != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (link != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Tap to open $link',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: PushKeys.dismiss,
                    visualDensity: VisualDensity.compact,
                    onPressed: service.dismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
