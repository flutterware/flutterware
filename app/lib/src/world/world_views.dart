import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../embedder/embedded_engine.dart';
import '../embedder/guest_texture.dart';
import '../embedder/input_region.dart';
import '../ui/action_button.dart';
import '../ui/theme.dart';
import 'live_guest.dart';
import 'platform/studio_platform.dart';

/// One person's app, live: the guest's texture at the device's logical size,
/// taking the mouse and the keyboard when it is clicked, as a window would.
class WorldPhone extends StatelessWidget {
  const WorldPhone({
    super.key,
    required this.guest,
    required this.size,
    this.platform,
  });

  final LiveWorldGuest guest;

  /// The device, in logical pixels.
  final Size size;

  /// What the studio answers for the app — here, the cursor it asks for.
  final StudioPlatform? platform;

  @override
  Widget build(BuildContext context) {
    var engine = guest.engine;
    return ListenableBuilder(
      listenable: Listenable.merge([guest.focus, ?engine]),
      builder: (context, _) => Container(
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          color: context.colors.panel,
          borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        ),
        // In front, not around: a border in `decoration` pads the child by
        // its width, and the guest — sized to the phone — would be drawn 4px
        // smaller than it is and clicked 2px off.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radii.radiusLarge),
          border: Border.all(
            color: guest.focus.hasFocus
                ? context.colors.accent
                : context.colors.line,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: switch ((engine?.phase, engine?.textureId)) {
          (EmbeddedEnginePhase.error, _) => WorldPhoneNote(
            '${engine?.errorMessage}',
            error: true,
          ),
          (_, null) => const WorldPhoneNote('Starting'),
          (_, var textureId?) => _Cursor(
            system: platform?.system,
            child: EmbedderInputRegion(
              engine: engine!,
              focusNode: guest.focus,
              child: GuestTexture(textureId: textureId),
            ),
          ),
        },
      ),
    );
  }
}

/// What stands where a phone will be: why it is not there yet, or why it
/// will not be.
class WorldPhoneNote extends StatelessWidget {
  const WorldPhoneNote(this.text, {super.key, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(FwSpacing.lg),
    child: Center(
      child: SelectableText(
        text,
        textAlign: TextAlign.center,
        style: error
            ? context.type.body.copyWith(color: context.colors.red)
            : context.type.bodyMuted,
      ),
    ),
  );
}

/// The cursor the guest's app asked for, over the guest — what its
/// `flutter/mousecursor` calls reach when the studio is its platform.
class _Cursor extends StatelessWidget {
  const _Cursor({required this.system, required this.child});

  final GuestSystem? system;
  final Widget child;

  static final _byKind = {
    for (var cursor in [
      SystemMouseCursors.basic,
      SystemMouseCursors.click,
      SystemMouseCursors.text,
      SystemMouseCursors.forbidden,
      SystemMouseCursors.grab,
      SystemMouseCursors.grabbing,
      SystemMouseCursors.precise,
      SystemMouseCursors.move,
      SystemMouseCursors.resizeLeftRight,
      SystemMouseCursors.resizeUpDown,
      SystemMouseCursors.wait,
    ])
      cursor.kind: cursor,
  };

  @override
  Widget build(BuildContext context) {
    var system = this.system;
    if (system == null) return child;
    return StreamBuilder<String>(
      stream: system.cursors,
      initialData: system.cursor,
      builder: (context, kind) => MouseRegion(
        cursor: _byKind[kind.data] ?? SystemMouseCursors.basic,
        child: child,
      ),
    );
  }
}

/// What one person's app did through the platform the studio stands in for —
/// the notifications it posted, the URLs it opened — and what the studio can
/// do to it: open a link in it, delivered where the OS would deliver one, and
/// send it to the background.
class WorldPlatformPanel extends StatefulWidget {
  const WorldPlatformPanel({
    super.key,
    required this.person,
    required this.platform,
  });

  final String person;
  final StudioPlatform platform;

  @override
  State<WorldPlatformPanel> createState() => _WorldPlatformPanelState();
}

class _WorldPlatformPanelState extends State<WorldPlatformPanel> {
  final _link = TextEditingController();
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _said;
  var _background = false;

  @override
  void initState() {
    super.initState();
    var platform = widget.platform;
    _subscriptions
      ..add(platform.notifications.shows.listen((_) => setState(() {})))
      ..add(platform.urls.opens.listen((_) => setState(() {})));
  }

  @override
  void dispose() {
    for (var subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var platform = widget.platform;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Notifications', style: context.type.sectionLabel),
        const SizedBox(height: FwSpacing.xs),
        if (platform.notifications.shown.isEmpty)
          Text('None posted', style: context.type.bodyMuted),
        for (var notification in platform.notifications.shown)
          Row(
            children: [
              Expanded(child: Text('$notification', style: context.type.body)),
              FwActionButton(
                label: 'Tap',
                onPressed: () async => platform.notifications.tap(notification),
              ),
            ],
          ),
        const SizedBox(height: FwSpacing.md),
        Text('Opened', style: context.type.sectionLabel),
        const SizedBox(height: FwSpacing.xs),
        Text(
          platform.urls.opened.isEmpty
              ? 'Nothing'
              : platform.urls.opened.join('\n'),
          style: platform.urls.opened.isEmpty
              ? context.type.bodyMuted
              : context.type.body,
        ),
        const SizedBox(height: FwSpacing.md),
        Text('Open a link', style: context.type.sectionLabel),
        const SizedBox(height: FwSpacing.xs),
        TextField(controller: _link),
        const SizedBox(height: FwSpacing.sm),
        FwActionButton(
          label: "Open in ${widget.person}'s app",
          onPressed: () async {
            var opened = platform.links.open(_link.text);
            setState(() => _said = opened ? null : 'The app is not listening');
          },
        ),
        if (_said case var said?) Text(said, style: context.type.bodyMuted),
        const SizedBox(height: FwSpacing.md),
        Text('App', style: context.type.sectionLabel),
        const SizedBox(height: FwSpacing.xs),
        // What a phone does to an app it no longer shows: the framework stops
        // asking for frames, and its memory is given back.
        FwActionButton(
          label: _background ? 'Bring to the front' : 'Send to the background',
          onPressed: () async {
            setState(() => _background = !_background);
            platform.system.lifecycle(_background ? 'paused' : 'resumed');
          },
        ),
      ],
    );
  }
}
