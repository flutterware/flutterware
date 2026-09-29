import 'package:material_ui/material_ui.dart';

import '../embedder/embedded_engine.dart';
import '../embedder/guest_texture.dart';
import '../embedder/input_region.dart';
import '../ui/theme.dart';
import 'live_guest.dart';
import 'platform/studio_platform.dart';

/// One person's app, live: the guest's texture at the device's logical size,
/// taking the mouse and the keyboard when it is clicked, as a window would.
///
/// Edge to edge: what stands around it — a phone's body, a browser — is the
/// caller's, and so is showing which app has the keyboard.
class WorldPhone extends StatelessWidget {
  const WorldPhone({
    super.key,
    required this.guest,
    required this.size,
    this.platform,
    this.shouldIgnorePointer,
  });

  final LiveWorldGuest guest;

  /// The device, in logical pixels.
  final Size size;

  /// What the studio answers for the app — here, the cursor it asks for.
  final StudioPlatform? platform;

  /// Pointer events the stage around the phone keeps: a pinch, a ⌘-scroll,
  /// a drag that is moving the stage.
  final bool Function(PointerEvent event)? shouldIgnorePointer;

  @override
  Widget build(BuildContext context) {
    var engine = guest.engine;
    return ListenableBuilder(
      listenable: Listenable.merge([guest.focus, ?engine]),
      builder: (context, _) => Container(
        width: size.width,
        height: size.height,
        color: context.colors.panel,
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
              shouldIgnorePointer: shouldIgnorePointer,
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
