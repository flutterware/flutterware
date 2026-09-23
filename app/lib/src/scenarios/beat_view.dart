import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/notification.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../previews/devices.dart';
import '../plugins/native/scenarios_results.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'artifacts.dart';
import 'framed_shot.dart';
import 'step_links.dart';

/// A beat that is not a screen, drawn: what the flow canvas puts between two
/// screens, and what the detail page blows up.
///
/// A notification is drawn as the recipient's phone would show it — a banner
/// over the screen it landed on. A document is a paper sheet carrying its
/// content where the format allows (text renders, images show) and its
/// identity where it does not.
class ScenarioBeatShot extends StatelessWidget {
  const ScenarioBeatShot({
    super.key,
    required this.step,
    required this.background,
    required this.device,
    required this.statusFallback,
    this.appLabel,
    this.appIcon,
  });

  /// The beat — a [ScenarioStepKind.document] or a
  /// [ScenarioStepKind.notification].
  final ScenarioRunStep step;

  /// The screen this beat happened on: [scenarioFrameFor]'s answer. Null when
  /// nothing had been drawn yet, which draws a locked phone instead.
  final ScenarioRunStep? background;

  final Device? device;
  final Brightness statusFallback;

  /// What the banner calls the app when the payload does not say — the
  /// project's own name, when the caller knows it.
  final String? appLabel;

  /// The project's launcher icon, when the host could find one — see
  /// [NotificationBanner.appIcon].
  final ImageProvider? appIcon;

  @override
  Widget build(BuildContext context) {
    if (step.notification case var notification?) {
      return _NotificationShot(
        notification: notification,
        background: background,
        device: device,
        statusFallback: statusFallback,
        appLabel: appLabel,
        appIcon: appIcon,
      );
    }
    // On the device's own canvas, so the sheet scales in proportion to the
    // phones beside it on the strip — bare, it was fitted to the cell and
    // came out wider than the screens it sat between.
    var canvas = Size(device?.width ?? 800, device?.height ?? 600);
    var width = canvas.width * 0.86;
    if (step.kind == ScenarioStepKind.setup) {
      return SizedBox(
        width: canvas.width,
        height: canvas.height,
        child: Center(
          child: _SetupCard(step: step, width: width),
        ),
      );
    }
    return SizedBox(
      width: canvas.width,
      height: canvas.height,
      child: Center(
        child: _DocumentSheet(
          step: step,
          width: width,
          height: math.min(width * 1.35, canvas.height * 0.9),
        ),
      ),
    );
  }
}

/// What a beat is called when the scenario gave it no name.
String scenarioBeatFallbackName(ScenarioRunStep step) => switch (step.kind) {
  ScenarioStepKind.notification => 'notification',
  ScenarioStepKind.setup => 'setup',
  _ => 'document',
};

/// A setup beat's facts: how long the preparatory work took and how much of
/// it went over the wire — `154 ms · 4 exchanges`. Empty when neither is
/// known.
String scenarioSetupFacts(ScenarioRunStep step) {
  var exchanges = step.eventChannels?['network'] ?? 0;
  return [
    if (step.ms case var ms?) '$ms ms',
    if (exchanges == 1)
      '1 exchange'
    else if (exchanges > 1)
      '$exchanges exchanges',
  ].join(' · ');
}

/// Preparatory work as a card: the name, its facts, and the exchanges it
/// made — a `setup` beat has no picture, because nothing was on screen for
/// it, and what a reader wants from it is what it did to the backend.
///
/// A card rather than a sheet: a sheet is a document, and the folded corner
/// says so at the strip's half-scale. This is a list of requests, and reads
/// as one.
class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.step, required this.width});

  final ScenarioRunStep step;
  final double width;

  /// How many exchange lines the card shows before it counts the rest.
  static const _shown = 12;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var titles = step.eventTitles ?? const <String>[];
    var facts = scenarioSetupFacts(step);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.build_outlined,
                size: FwIconSize.lg,
                color: colors.mut,
              ),
              const Gap(FwSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.name ?? 'setup',
                      style: context.type.heading,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (facts.isNotEmpty) ...[
                      const Gap(FwSpacing.xs),
                      Text(
                        facts,
                        style: context.type.caption.copyWith(
                          color: colors.mut2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const Gap(FwSpacing.lg),
          const Divider(height: 1),
          const Gap(FwSpacing.lg),
          if (titles.isEmpty)
            Text('Nothing went over the wire.', style: context.type.bodyMuted)
          else ...[
            for (var title in titles.take(_shown))
              Padding(
                padding: const EdgeInsets.only(bottom: FwSpacing.xs),
                child: Text(
                  title,
                  style: context.type.mono.copyWith(fontSize: 12, height: 1.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (titles.length > _shown)
              Text(
                '+${titles.length - _shown} more',
                style: context.type.bodyMuted,
              ),
          ],
        ],
      ),
    );
  }
}

/// The banner over the screen it arrived on — or over a dark lock screen
/// when it arrived before the flow drew anything.
class _NotificationShot extends StatelessWidget {
  const _NotificationShot({
    required this.notification,
    required this.background,
    required this.device,
    required this.statusFallback,
    required this.appLabel,
    required this.appIcon,
  });

  /// Read straight off the step: three strings, typed on both ends of the
  /// wire, so there is no file to fetch and nothing to decode before drawing.
  final ScenarioNotification notification;
  final ScenarioRunStep? background;
  final Device? device;
  final Brightness statusFallback;
  final String? appLabel;
  final ImageProvider? appIcon;

  @override
  Widget build(BuildContext context) {
    // Dark runs got light status icons; the banner follows the run.
    var dark = statusFallback == Brightness.light;
    var overlay = Stack(
      fit: StackFit.expand,
      children: [
        // The dim that says "this moment is about the banner" — the screen
        // stays legible under it, the way a real notification leaves the app
        // visible.
        Container(color: Colors.black.withValues(alpha: 0.3)),
        Positioned(
          top: (device?.insetTop ?? 0) + 8,
          left: 8,
          right: 8,
          child: NotificationBanner(
            notification: notification,
            appLabel: appLabel,
            appIcon: appIcon,
            dark: dark,
          ),
        ),
      ],
    );
    if (background case var step?) {
      return FramedShot(
        step: step,
        device: device,
        fallbackBrightness: statusFallback,
        screenOverlay: overlay,
      );
    }
    // No screen yet: the phone was locked, which is where a real one lands
    // anyway.
    var size = Size(device?.width ?? 390, device?.height ?? 844);
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFF15151A),
            alignment: Alignment.topCenter,
            padding: EdgeInsets.only(top: (device?.insetTop ?? 0) + 40),
            child: Text(
              '9:41',
              style: TextStyle(
                fontSize: 68,
                fontWeight: FontWeight.w300,
                color: Colors.white.withValues(alpha: 0.9),
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Positioned(
            top: (device?.insetTop ?? 0) + 140,
            left: 8,
            right: 8,
            child: NotificationBanner(
              notification: notification,
              appLabel: appLabel,
              appIcon: appIcon,
              dark: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// A real-looking notification banner, drawn in the screen's own logical
/// coordinates — dev_studio's trick, back on the attachment system.
///
/// Everything the payload leaves out is supplied here: the icon tile, the
/// "now", the light/dark chrome. Fully explicit text styles because the
/// banner floats over the app's pixels, outside any Material.
class NotificationBanner extends StatelessWidget {
  const NotificationBanner({
    super.key,
    required this.notification,
    required this.dark,
    this.appLabel,
    this.appIcon,
  });

  final ScenarioNotification notification;
  final String? appLabel;

  /// The project's real launcher icon, when the host could find one — the
  /// panel can, an exported page cannot. Falls back to the initial tile,
  /// including when the image itself fails to load.
  final ImageProvider? appIcon;

  final bool dark;

  @override
  Widget build(BuildContext context) {
    var name = notification.appName ?? appLabel;
    var title = notification.title ?? name;
    var primary = dark ? Colors.white : const Color(0xFF111111);
    var secondary = dark
        ? Colors.white.withValues(alpha: 0.55)
        : const Color(0x8C3C3C43);
    TextStyle style(double size, FontWeight weight, Color color) => TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      decoration: TextDecoration.none,
      height: 1.25,
    );
    Widget tile = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFF3478F6),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: name == null || name.isEmpty
          ? const Icon(Icons.notifications, size: 22, color: Colors.white)
          : Text(
              name.substring(0, 1).toUpperCase(),
              style: style(20, FontWeight.w600, Colors.white),
            ),
    );
    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xF22C2C2E) : const Color(0xF2F2F2F7),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The real icon has no corner baked in — the OS masks it, so this
          // does too.
          if (appIcon case var icon?)
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image(
                image: icon,
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => tile,
              ),
            )
          else
            tile,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        title ?? 'Notification',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style(15, FontWeight.w600, primary),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('now', style: style(13, FontWeight.w400, secondary)),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  notification.body,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: style(15, FontWeight.w400, primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A document as a sheet of paper: identity on top, content below where the
/// format renders — text and images do, everything else shows what it is and
/// leaves opening to the desktop.
///
/// The anatomy is a paper sheet's rather than a panel card's: a soft shadow
/// lifting it off the canvas and a folded corner — the cue that reads as
/// "document" at the strip's half-scale, where the words are too small.
class _DocumentSheet extends StatelessWidget {
  const _DocumentSheet({
    required this.step,
    this.width = 440,
    this.height = 580,
  });

  final ScenarioRunStep step;
  final double width;
  final double height;

  /// The folded corner's side.
  static const _ear = 36.0;

  static bool _textish(String? mime) {
    if (mime == null) return false;
    return mime.startsWith('text/') ||
        mime.endsWith('/json') ||
        mime.endsWith('+json') ||
        mime.endsWith('/xml') ||
        mime.endsWith('+xml');
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mime = step.mimeType;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _PaperPainter(
              fill: colors.bg,
              line: colors.line,
              fold: colors.panel2,
              ear: _ear,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(FwSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Out from under the folded corner.
                  padding: const EdgeInsets.only(right: _ear),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.name ?? 'document',
                        style: context.type.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Gap(FwSpacing.xs),
                      Text(
                        [
                          if (step.file case var file?) p.basename(file),
                          ?mime,
                          if (step.bytes case var bytes?)
                            scenarioBeatSize(bytes),
                        ].join(' · '),
                        style: context.type.caption.copyWith(
                          color: colors.mut2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Gap(FwSpacing.lg),
                const Divider(height: 1),
                const Gap(FwSpacing.lg),
                Expanded(child: _content(context, mime)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, String? mime) {
    var artifacts = ScenarioArtifactsScope.of(context);
    if (mime != null && mime.startsWith('image/')) {
      return Align(
        alignment: Alignment.topCenter,
        child: Image(
          image: artifacts.encodedImage(step.file!),
          fit: BoxFit.contain,
        ),
      );
    }
    if (_textish(mime)) {
      return FutureBuilder<String?>(
        future: artifacts.readString(step.file!),
        builder: (context, snapshot) {
          var text = snapshot.data;
          if (text == null) return const SizedBox.shrink();
          // A preview, not a reader: enough to say what the document is,
          // capped so a megabyte of JSON does not become a megabyte of
          // glyphs on a flow card.
          const cap = 4000;
          return Text(
            text.length > cap ? '${text.substring(0, cap)}…' : text,
            style: context.type.mono.copyWith(fontSize: 12, height: 1.5),
            overflow: TextOverflow.fade,
          );
        },
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 64,
            color: context.colors.mut3,
          ),
          const Gap(FwSpacing.md),
          Text(
            step.file == null ? '' : p.basename(step.file!),
            style: context.type.bodyMuted,
          ),
        ],
      ),
    );
  }
}

/// The sheet itself: fill, hairline, shadow and the folded corner, one
/// painter — a border cannot follow a cut corner, so the outline is drawn
/// rather than decorated.
class _PaperPainter extends CustomPainter {
  const _PaperPainter({
    required this.fill,
    required this.line,
    required this.fold,
    required this.ear,
  });

  final Color fill;
  final Color line;
  final Color fold;
  final double ear;

  @override
  void paint(Canvas canvas, Size size) {
    var sheet = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width - ear, 0)
      ..lineTo(size.width, ear)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawShadow(sheet, Colors.black.withValues(alpha: 0.4), 10, true);
    canvas.drawPath(sheet, Paint()..color = fill);
    // The flap, folded down over the front.
    var flap = Path()
      ..moveTo(size.width - ear, 0)
      ..lineTo(size.width, ear)
      ..lineTo(size.width - ear, ear)
      ..close();
    canvas.drawPath(flap, Paint()..color = fold);
    var outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = line;
    canvas.drawPath(sheet, outline);
    canvas.drawPath(flap, outline);
  }

  @override
  bool shouldRepaint(_PaperPainter old) =>
      old.fill != fill || old.line != line || old.fold != fold;
}

String scenarioBeatSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} kB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// One beat, blown up: the thing big, its facts and the way out to the
/// desktop underneath.
class ScenarioBeatPage extends StatelessWidget {
  const ScenarioBeatPage({
    super.key,
    required this.steps,
    required this.step,
    required this.background,
    required this.device,
    required this.onBack,
    required this.onOpenStep,
    required this.statusFallback,
    this.appLabel,
    this.appIcon,
  });

  /// The run this beat is one of, so the page can offer the steps around it.
  final List<ScenarioRunStep> steps;

  /// The beat — a document or a notification.
  final ScenarioRunStep step;

  /// The screen it happened on — see [ScenarioBeatShot.background].
  final ScenarioRunStep? background;

  final Device? device;
  final VoidCallback onBack;

  /// Walking on from here. A receipt in the middle of a flow is a step like
  /// any other, and a walk that had to go back to the canvas to get past it
  /// would not be a walk.
  final void Function(ScenarioRunStep) onOpenStep;
  final Brightness statusFallback;
  final String? appLabel;
  final ImageProvider? appIcon;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.lg,
            vertical: FwSpacing.md,
          ),
          child: Row(
            children: [
              Tappable(
                onTap: onBack,
                child: Icon(
                  Icons.arrow_back,
                  size: FwIconSize.lg,
                  color: colors.mut,
                ),
              ),
              const Gap(FwSpacing.lg),
              Expanded(
                child: Text(
                  step.name ?? scenarioBeatFallbackName(step),
                  style: context.type.heading,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // A document's facts, or a setup beat's. A notification has
              // none — it is three strings and they are all on screen
              // already — so the line is absent rather than empty.
              if (switch (step.kind) {
                    ScenarioStepKind.setup => scenarioSetupFacts(step),
                    _ => [
                      if (step.file case var file?) p.basename(file),
                      ?step.mimeType,
                      if (step.bytes case var bytes?) scenarioBeatSize(bytes),
                    ].join(' · '),
                  }
                  case var facts when facts.isNotEmpty)
                Text(
                  facts,
                  style: context.type.caption.copyWith(color: colors.mut2),
                ),
              // Only a document has a file to open; a notification is three
              // strings and is entirely on screen already.
              if (step.file case var file?) ...[
                const Gap(FwSpacing.lg),
                Tappable(
                  onTap: () => unawaited(
                    launchUrl(ScenarioArtifactsScope.of(context).uriOf(file)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.open_in_new,
                        size: FwIconSize.sm,
                        color: colors.mut,
                      ),
                      const Gap(FwSpacing.xs),
                      Text('Open', style: context.type.bodySmall),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: colors.panel2,
                  padding: const EdgeInsets.all(FwSpacing.xl),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ScenarioBeatShot(
                      step: step,
                      background: background,
                      device: device,
                      statusFallback: statusFallback,
                      appLabel: appLabel,
                      appIcon: appIcon,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: ScenarioStepLinks(
                  steps: steps,
                  step: step,
                  onOpenStep: onOpenStep,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
