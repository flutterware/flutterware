import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

// ignore: implementation_imports
import 'package:flutterware/src/device_frames.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutterware/world.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/browser_frame.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'live_guest.dart';
import 'message_banner.dart';
import 'open_world.dart';
import 'world_messages.dart';
import 'world_views.dart';

Device deviceOf(WorldPerson person) => switch (person.spec.on) {
  Studio(:var device) => device,
};

/// Whether [person] has an app to draw, rather than a card saying who acts
/// for them.
bool hasApp(WorldPerson person) => person.spec.app != null;

/// What [person] stands on the stage as, in logical pixels: their device in
/// its body — a phone's, or a browser around a desktop window — or, with no
/// app, a card, whose size is on the screen rather than the device's.
Size personSize(WorldPerson person) {
  if (!hasApp(person)) return HeadlessCard.size;
  var device = deviceOf(person);
  var screen = Size(device.width, device.height);
  return deviceFrameFor(device)?.frameSize ?? BrowserFrame.frameSize(screen);
}

/// `Lab on iPhone 16`, `Lab in a browser, 1280 × 800`.
String appLine(WorldPerson person) {
  var app = person.spec.app;
  if (app == null) return 'No app';
  var device = deviceOf(person);
  return device.kind == DeviceKind.desktop
      ? '${app.entrypoint} in a browser, '
            '${device.width.round()} × ${device.height.round()}'
      : '${app.entrypoint} on ${device.label}';
}

/// A person above their device: their colour, their name, and a count of
/// what they were sent, by kind — only the kinds they got.
class PersonTag extends StatelessWidget {
  const PersonTag({
    super.key,
    required this.name,
    required this.color,
    required this.counts,
    this.onTap,
  });

  final String name;
  final Color color;

  /// By kind, `mail` · `push` · `sms`.
  final Map<String, int> counts;
  final VoidCallback? onTap;

  static const height = 26.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var kinds = [
      for (var kind in messageKinds)
        if ((counts[kind] ?? 0) > 0) kind,
    ];
    return Tooltip(
      message: onTap == null ? '' : 'Show only $name',
      child: Tappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.pill),
        child: Container(
          height: height,
          padding: EdgeInsets.only(
            left: FwSpacing.lg,
            right: kinds.isEmpty ? FwSpacing.lg : FwSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            borderRadius: BorderRadius.circular(context.radii.pill),
            boxShadow: [
              BoxShadow(color: colors.line, spreadRadius: 1),
              ...context.elevation.sm,
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PersonDot(color),
              const SizedBox(width: FwSpacing.sm),
              Text(name, style: context.type.bodyStrong),
              if (kinds.isNotEmpty) ...[
                const SizedBox(width: FwSpacing.sm),
                Container(
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
                  decoration: BoxDecoration(
                    color: colors.line2,
                    borderRadius: BorderRadius.circular(context.radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var (i, kind) in kinds.indexed) ...[
                        if (i > 0) const SizedBox(width: FwSpacing.sm),
                        Tooltip(
                          message:
                              '${counts[kind]} ${messageKind(kind)}'
                              '${kind == 'sms' || counts[kind] == 1 ? '' : 's'}',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                messageIcon(kind),
                                size: FwIconSize.xs,
                                color: colors.ink2,
                              ),
                              const SizedBox(width: FwSpacing.xxs),
                              Text(
                                '${counts[kind]}',
                                style: context.type.micro.copyWith(
                                  color: colors.ink2,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A person's colour, as a dot: beside their name, in the switch, on a tag.
class PersonDot extends StatelessWidget {
  const PersonDot(this.color, {super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Someone with no app: the world's actions act for them. Small — they have
/// nothing to show — and read on the screen at its own size.
class HeadlessCard extends StatelessWidget {
  const HeadlessCard({super.key, required this.name, required this.actions});

  final String name;

  /// The world's actions that name them.
  final List<String> actions;

  static const size = Size(220, 120);

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.bodySmall.copyWith(color: colors.ink2);
    return Container(
      width: size.width,
      constraints: BoxConstraints(minHeight: size.height),
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.xl,
        FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        boxShadow: [
          BoxShadow(color: colors.line, spreadRadius: 1),
          ...context.elevation.sm,
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: FwIconSize.lg,
            color: colors.mut,
          ),
          const SizedBox(height: FwSpacing.sm),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: actions.isEmpty
                      ? '$name has no app.'
                      : '$name has no app. Use Actions: ',
                ),
                if (actions.isNotEmpty) ...[
                  for (var (i, action) in actions.indexed) ...[
                    if (i > 0) const TextSpan(text: ', '),
                    TextSpan(
                      text: action,
                      style: style.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                  const TextSpan(text: '.'),
                ],
              ],
            ),
            style: style,
          ),
        ],
      ),
    );
  }
}

/// The world's actions that name [person], as a word: *Mia orders a flat
/// white* acts for Mia.
List<String> actionsFor(String person, Iterable<String> actions) {
  var named = RegExp('\\b${RegExp.escape(person)}\\b', caseSensitive: false);
  return [
    for (var action in actions)
      if (named.hasMatch(action)) action,
  ];
}

/// A person's app in the body it stands in — a phone's, or a browser around
/// a desktop window — laid out at [personSize] and ringed in the accent
/// while it has the keyboard.
class PersonDevice extends StatelessWidget {
  const PersonDevice({
    super.key,
    required this.world,
    required this.person,
    required this.scale,
    required this.ignores,
    this.onRead,
  });

  /// What a browser's reload starts their app again through, and what a
  /// banner on the screen hands a message to the app through.
  final OpenWorld world;
  final WorldPerson person;

  /// Opens an email to read, by its message id: a click on its banner.
  final ValueChanged<String>? onRead;

  /// How much smaller than its size it is drawn: what a note on its screen
  /// grows by, to stay readable.
  final double scale;

  final bool Function(PointerEvent event) ignores;

  @override
  Widget build(BuildContext context) {
    var device = deviceOf(person);
    var screen = Size(device.width, device.height);
    var content = MessageBanners(
      world: world,
      person: person,
      device: device,
      onRead: onRead,
      child: _screen(context, screen),
    );
    var focus = switch (person.guest) {
      LiveWorldGuest live => live.focus,
      _ => null,
    };
    var frame = deviceFrameFor(device);
    Widget framed;
    CustomPainter body;
    if (frame != null) {
      framed = DeviceFrame(device: frame, screen: content);
      body = frame.framePainter;
    } else {
      framed = _Browser(
        world: world,
        person: person,
        screen: screen,
        child: content,
      );
      body = _RoundedBox(Radius.circular(context.radii.radiusLarge));
    }
    // Standing on the stage, the way the phone stands on a table: the shadow
    // is the body's own shape, its corners and buttons, not the frame's box.
    var ink = context.colors.ink;
    framed = CustomPaint(
      painter: _Shadow(body, [
        BoxShadow(
          color: ink.withValues(alpha: 0.22),
          blurRadius: 40,
          offset: const Offset(0, 18),
        ),
        BoxShadow(
          color: ink.withValues(alpha: 0.18),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ]),
      child: framed,
    );
    if (focus == null) return framed;
    return ListenableBuilder(
      listenable: focus,
      builder: (context, child) => CustomPaint(
        foregroundPainter: focus.hasFocus
            ? _Ring(body, context.colors.accent, width: 2 / scale)
            : null,
        child: child,
      ),
      child: framed,
    );
  }

  Widget _screen(BuildContext context, Size size) {
    Widget note(String text, {bool error = false}) => ColoredBox(
      color: context.colors.panel,
      child: MediaQuery.withClampedTextScaling(
        // Drawn at the stage's scale, a note is as small as the app's own
        // words: grown back to the studio's size.
        minScaleFactor: min(4, 1 / scale),
        maxScaleFactor: min(4, 1 / scale),
        child: WorldPhoneNote(text, error: error),
      ),
    );
    return switch ((person.phase, person.guest)) {
      (PersonPhase.failed, _) => note(person.problem ?? 'Failed', error: true),
      (_, LiveWorldGuest live) when live.engine != null => WorldPhone(
        guest: live,
        size: size,
        platform: person.platform,
        shouldIgnorePointer: ignores,
      ),
      (PersonPhase.building, _) => note(
        'Building ${person.spec.app?.entrypoint}…',
      ),
      _ => note('Starting the app…'),
    };
  }
}

/// Whether [body] paints differently from [old]: painters of two kinds
/// always do, and one kind is asked the way a [CustomPaint] would ask it.
bool _bodyChanged(CustomPainter body, CustomPainter old) =>
    body.runtimeType != old.runtimeType || body.shouldRepaint(old);

/// [body] painted as one solid colour, through [filter]: its silhouette.
void _silhouette(
  Canvas canvas,
  Size size,
  CustomPainter body,
  Color color, {
  ImageFilter? filter,
  double reach = 0,
}) {
  canvas.saveLayer(
    (Offset.zero & size).inflate(reach),
    Paint()
      ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn)
      ..imageFilter = filter,
  );
  body.paint(canvas, size);
  canvas.restore();
}

/// A device's shadow, cast by its [body]: whatever the frame paints, so the
/// shadow has the phone's corners and buttons.
class _Shadow extends CustomPainter {
  const _Shadow(this.body, this.shadows);

  final CustomPainter body;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    for (var shadow in shadows) {
      var sigma = shadow.blurSigma;
      canvas
        ..save()
        ..translate(shadow.offset.dx, shadow.offset.dy);
      _silhouette(
        canvas,
        size,
        body,
        shadow.color,
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        reach: 3 * sigma,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Shadow old) =>
      _bodyChanged(body, old.body) || !listEquals(old.shadows, shadows);
}

/// The accent around a device that has the keyboard: its [body] grown by
/// [width] on each side of a gap of half that, so it follows the phone's
/// corners and buttons.
class _Ring extends CustomPainter {
  const _Ring(this.body, this.color, {required this.width});

  final CustomPainter body;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    var outer = width * 1.5;
    var inner = width / 2;
    canvas.saveLayer((Offset.zero & size).inflate(outer), Paint());
    _silhouette(
      canvas,
      size,
      body,
      color,
      filter: ImageFilter.dilate(radiusX: outer, radiusY: outer),
      reach: outer,
    );
    canvas.saveLayer(
      (Offset.zero & size).inflate(inner),
      Paint()..blendMode = BlendMode.dstOut,
    );
    _silhouette(
      canvas,
      size,
      body,
      color,
      filter: ImageFilter.dilate(radiusX: inner, radiusY: inner),
      reach: inner,
    );
    canvas
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(_Ring old) =>
      _bodyChanged(body, old.body) || old.color != color || old.width != width;
}

/// A browser window's body: its box, with [radius] corners.
class _RoundedBox extends CustomPainter {
  const _RoundedBox(this.radius);

  final Radius radius;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRRect(
    RRect.fromRectAndRadius(Offset.zero & size, radius),
    Paint(),
  );

  @override
  bool shouldRepaint(_RoundedBox old) => old.radius != radius;
}

/// The browser around a desktop person's app, showing the title the app
/// gives itself and the route it reports.
class _Browser extends StatefulWidget {
  const _Browser({
    required this.world,
    required this.person,
    required this.screen,
    required this.child,
  });

  final OpenWorld world;
  final WorldPerson person;
  final Size screen;
  final Widget child;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  final _heard = <StreamSubscription<Object?>>[];

  /// While the app starts again: reload greyed, as a browser's is while it
  /// loads.
  var _reloading = false;

  @override
  void initState() {
    super.initState();
    if (widget.person.platform case var platform?) {
      _heard
        ..add(platform.system.titles.listen((_) => setState(() {})))
        ..add(platform.navigation.routes.listen((_) => setState(() {})));
    }
  }

  @override
  void dispose() {
    for (var subscription in _heard) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  /// `lab.localhost`: the entry point's name as a host, since a desktop app
  /// has none of its own.
  String get _host {
    var name = widget.person.spec.app?.entrypoint ?? 'app';
    var slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    return '$slug.localhost';
  }

  /// A typed address, taken where a browser would take it: a link with a
  /// scheme into the app the way a delivered one goes, anything else as the
  /// path to show.
  void _go(String typed) {
    var platform = widget.person.platform;
    if (platform == null || typed.isEmpty) return;
    if (typed.contains('://')) {
      platform.links.open(typed);
      return;
    }
    var path = typed.startsWith(_host) ? typed.substring(_host.length) : typed;
    var slash = path.indexOf('/');
    path = slash < 0 ? '/' : path.substring(slash);
    platform.navigation.go(path);
  }

  Future<void> _reload() async {
    var navigation = widget.person.platform?.navigation;
    if (navigation == null) return;
    setState(() => _reloading = true);
    try {
      await navigation.reload(
        () => widget.world.restartApp(widget.person.name),
      );
    } on Object {
      // The world's log says why; the page stays as it was.
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var platform = widget.person.platform;
    var navigation = platform?.navigation;
    var color = platform?.system.titleColor;
    return BrowserFrame(
      screen: widget.screen,
      title: platform?.system.title ?? widget.person.name,
      titleColor: color == null ? null : Color(color),
      host: _host,
      path: platform?.navigation.route ?? '',
      onBack: navigation != null && navigation.canBack ? navigation.back : null,
      onForward: navigation != null && navigation.canForward
          ? navigation.forward
          : null,
      onReload: navigation == null || _reloading
          ? null
          : () => unawaited(_reload()),
      onGo: platform == null ? null : _go,
      child: widget.child,
    );
  }
}

/// [child] laid out at [size] and drawn [scale] times as large. A pointer
/// over it still lands where it should: hit testing undoes the same
/// transform, so the guest's input region reads positions in its own size.
class ScaledBox extends StatelessWidget {
  const ScaledBox({
    super.key,
    required this.size,
    required this.scale,
    required this.child,
  });

  final Size size;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size.width * scale,
    height: size.height * scale,
    child: FittedBox(
      child: SizedBox.fromSize(size: size, child: child),
    ),
  );
}
