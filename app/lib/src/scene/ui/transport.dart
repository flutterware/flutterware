import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';
import '../playback.dart';

/// Play, stop, where the playhead is, how fast. One row, 28px tall, so it
/// fits a toolbar or a timeline gutter without either making room.
class SceneTransport extends StatelessWidget {
  const SceneTransport(this.playback, {super.key, this.compact = false});

  final ScenePlayback playback;

  /// Without the rate control, for a gutter that cannot spare it.
  final bool compact;

  static const _rates = [0.5, 1.0, 2.0];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([playback, playback.editor.doc.listenable]),
    builder: (context, _) {
      var colors = context.colors;
      var total = playback.duration.inMilliseconds;
      var at = playback.position.inMilliseconds.clamp(0, total);
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: FwSpacing.xxs,
        children: [
          _Button(
            icon: playback.isPlaying ? Icons.pause : Icons.play_arrow,
            tooltip: playback.isPlaying ? 'Pause' : 'Play',
            onTap: playback.toggle,
          ),
          _Button(
            icon: Icons.stop,
            tooltip:
                'Stop — back to the start, and the scene as authored, '
                'with no motion applied',
            onTap: playback.isApplied ? playback.stop : null,
          ),
          Tooltip(
            message: playback.autoKey
                ? 'Recording: an edit at the playhead becomes a key'
                : 'Record: make edits at the playhead into keys',
            child: Tappable(
              onTap: () => playback.autoKey = !playback.autoKey,
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              child: Padding(
                padding: const EdgeInsets.all(FwSpacing.xs),
                child: Icon(
                  Icons.fiber_manual_record,
                  size: FwIconSize.md,
                  color: playback.autoKey ? colors.red : colors.mut3,
                ),
              ),
            ),
          ),
          const Gap(FwSpacing.xs),
          Text(
            '${_seconds(at)} / ${_seconds(total)}s',
            style: context.type.caption.copyWith(
              color: colors.mut,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (!compact) ...[
            const Gap(FwSpacing.xs),
            Tappable(
              onTap: () {
                var i = _rates.indexOf(playback.rate);
                playback.rate = _rates[(i + 1) % _rates.length];
              },
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.sm,
                  vertical: FwSpacing.xxs,
                ),
                child: Text(
                  '${playback.rate}×',
                  style: context.type.caption.copyWith(color: colors.mut),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );

  static String _seconds(int ms) => (ms / 1000).toStringAsFixed(2);
}

class _Button extends StatelessWidget {
  const _Button({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xs),
        child: Icon(
          icon,
          size: FwIconSize.md,
          color: onTap == null ? context.colors.mut3 : context.colors.ink,
        ),
      ),
    ),
  );
}
