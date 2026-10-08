import 'dart:convert';

/// The layer below the widget tree.
///
/// The drive loop addresses Flutter's own element tree, and that tree ends at
/// the platform's edge. Four things live past it and an agent meets all four
/// in ordinary work: platform views (a webview's contents are pixels to
/// Flutter and a DOM to the platform), native dialogs — permission prompts
/// above all, which today dead-end a flow completely — the soft keyboard, and
/// on iOS an app the OS has suspended, which the drive layer can only
/// *describe* being stuck behind.
///
/// A driver is host-side by construction: it talks to the device the way the
/// platform's own tooling does (`adb`, the macOS accessibility API), so it
/// needs no guest, works on apps flutterware did not launch, and keeps working
/// when the Dart VM is not being scheduled at all.
///
/// This layer is never taken silently. It is slower and blunter than the
/// drive layer — a native observe is seconds where a Flutter observe is
/// milliseconds, and it addresses what the platform chose to publish rather
/// than what the app's code says. The caller asks for it by name (`layer:
/// native`); refusals on both layers teach when to switch. An automatic
/// downgrade would reintroduce the one failure this whole surface exists to
/// prevent — acting on something other than what was addressed, and reporting
/// success.
abstract class NativeDriver {
  /// What this driver drives — `android`, `ios-simulator`, `macos`. Rides
  /// every observation so an agent reading a reply knows which rules apply
  /// (text entry exists on Android only; Flutter content is invisible on
  /// macOS).
  String get platform;

  /// The space [NativeNode.bounds] and [tapAt] speak, named in every reply.
  ///
  /// Coordinates are the one part of this layer an agent can get silently
  /// wrong: a screenshot is retina-scaled and a tap is not, and the two spaces
  /// differ by a factor that is invisible until a tap lands in the wrong place.
  /// So the space is stated rather than implied — `px` on Android, where the dump
  /// and `input tap` already agree, and window points on macOS and the
  /// simulator, where the screenshot is twice that.
  String get coordinateSpace;

  /// The platform's own view tree, plus the real pixels.
  ///
  /// "Real" is the point: this screenshot is what the device shows — keyboard,
  /// platform views, system UI — as opposed to the guest's raster of the
  /// Flutter layer tree.
  Future<NativeObservation> observe({bool screenshot = true});

  /// Taps [node] the best way this platform has.
  ///
  /// Not "taps at a point": where the platform can act on the element itself
  /// (macOS and the simulator's `AXPress`) that is strictly better — no
  /// coordinates to get wrong, and no requirement that the window be raised.
  /// Android has no such door and taps the node's center, which is exact
  /// there because both sides speak physical pixels.
  Future<void> tapNode(NativeNode node);

  /// Taps a bare point in [coordinateSpace].
  ///
  /// The escape hatch for what no tree publishes — a WKWebView's interior on
  /// iOS is invisible to accessibility, so the only way in is the real-pixel
  /// screenshot plus a point.
  Future<void> tapAt(double x, double y);

  /// Types [text] into whatever holds focus.
  ///
  /// Throws [NativeUnsupported] where the platform has no honest mechanism.
  /// That is not a gap to fill later on iOS: `AXSetValue` on a focused field
  /// returns success and writes nothing (measured), and a mechanism that lies
  /// about success is worse than one that refuses.
  Future<void> enterText(String text);

  /// Brings the app to the front.
  ///
  /// The verb that closes iOS's one hard dead end: a backgrounded app is
  /// suspended, answers no drive call, and the existing timeout can only ask a
  /// human to fix it. Here the agent fixes it.
  Future<void> foreground();

  /// Frees whatever the driver holds. A driver is cached per run, so this runs
  /// on stop and dispose, not per call.
  Future<void> close() async {}
}

/// One moment of the platform's tree.
class NativeObservation {
  NativeObservation({
    required this.platform,
    required this.coordinateSpace,
    required this.root,
    this.screenshot,
    this.screenshotScale,
    this.screenshotOrigin,
    this.note,
  });

  final String platform;
  final String coordinateSpace;

  /// The tree as the platform published it, already filtered to what can be
  /// addressed or read (see [NativeNode]).
  final NativeNode root;

  /// PNG bytes of what the device actually shows.
  final List<int>? screenshot;

  /// How many screenshot pixels one [coordinateSpace] unit is.
  ///
  /// 1.0 on Android; 2.0 or 3.0 on a retina simulator or Mac. Stated because
  /// an agent that reads a point off the picture must divide by this before
  /// passing it to `{"at": …}` — the trap the capture work already paid for
  /// once.
  final double? screenshotScale;

  /// Where the picture's top-left corner sits in [coordinateSpace], when the
  /// capture is a crop rather than the whole screen.
  ///
  /// Null means the picture starts at the origin the tree's coordinates do, so
  /// dividing by [screenshotScale] is the whole translation. macOS crops to
  /// the app's own windows — the desktop around them is other people's
  /// business — and a crop moves the origin, which is a silent off-by-a-window
  /// unless it is stated.
  final NativeBounds? screenshotOrigin;

  /// Anything true about this observation that the tree cannot say — "the
  /// Flutter layer is invisible here", "the app is backgrounded".
  final String? note;

  /// Every node, depth first — what a target resolves against.
  ///
  /// Everything, deliberately: a node with nothing to say can still be the one
  /// you mean. A `WebView` publishes no label and no click handler, and
  /// `{"role": "android.webkit.WebView"}` is exactly how an agent asks "where
  /// is the thing Flutter could not show me".
  List<NativeNode> get nodes {
    var out = <NativeNode>[];
    void walk(NativeNode node) {
      out.add(node);
      for (var child in node.children) {
        walk(child);
      }
    }

    walk(root);
    return out;
  }

  /// The nodes with something to say — a label, or a click handler.
  ///
  /// The projection a human or an agent reads: what a refusal quotes back and
  /// what [texts] is built from. Separate from [nodes] because the two
  /// questions are different — "what can I name" is everything, "what is this
  /// screen saying" is this.
  List<NativeNode> get speaking => [
    for (var node in nodes)
      if (node.label != null || node.clickable) node,
  ];

  /// What [speaking] says out loud, capped the way the drive layer caps its
  /// own texts — one screen of a chatty app should not tax every reply.
  List<String> get texts => [
    for (var node in speaking)
      if (node.label case var label?) _capText(label),
  ];

  Map<String, Object?> toJson() => {
    'platform': platform,
    'coordinateSpace': coordinateSpace,
    if (screenshotScale != null) 'screenshotScale': screenshotScale,
    if (screenshotOrigin != null)
      'screenshotOrigin': screenshotOrigin!.toJson(),
    if (note != null) 'note': note,
    'root': root.toJson(),
  };
}

/// The same cap the drive layer applies at the source, for the same reason:
/// one essay-length string should not tax a reply, and an agent re-targeting
/// the truncated form is taught to use `{"containing": <prefix>}` instead.
const nativeTextCap = 200;

String _capText(String text) => text.length <= nativeTextCap
    ? text
    : '${text.substring(0, nativeTextCap)}…';

/// One node of a platform view tree.
///
/// Deliberately not a mirror of either platform's own node type: the fields
/// here are the ones both platforms publish and a verb can use. What is left
/// out is left out on purpose — resource ids, style attributes and the rest
/// describe a view, and this layer addresses a *thing on screen*.
class NativeNode {
  NativeNode({
    required this.role,
    this.label,
    this.bounds,
    this.clickable = false,
    this.enabled = true,
    this.focused = false,
    this.checked,
    this.children = const [],
  });

  /// The platform's own name for what this is — `android.widget.Button`,
  /// `AXButton`. Passed through rather than normalised: an agent reading
  /// `android.webkit.WebView` learns something a normalised `button|text|
  /// other` would have thrown away.
  final String role;

  /// What it says: text, content description, or accessibility label,
  /// whichever the platform filled in.
  final String? label;

  final NativeBounds? bounds;
  final bool clickable;
  final bool enabled;
  final bool focused;

  /// Checkbox and switch state; null when the node is neither.
  final bool? checked;

  final List<NativeNode> children;

  Map<String, Object?> toJson() => {
    'role': role,
    if (label != null) 'label': _capText(label!),
    if (bounds != null) 'bounds': bounds!.toJson(),
    if (clickable) 'clickable': true,
    if (!enabled) 'enabled': false,
    if (focused) 'focused': true,
    if (checked != null) 'checked': checked,
    if (children.isNotEmpty)
      'children': [for (var child in children) child.toJson()],
  };

  /// How a refusal names this node. The same spelling the drive layer uses for
  /// a visible string, so a candidate list reads the same on both layers.
  String describe() {
    var name = label == null ? role : '"${_capText(label!)}"';
    return bounds == null ? name : '$name at ${bounds!.describe()}';
  }
}

/// A rectangle in the driver's [NativeDriver.coordinateSpace].
///
/// Its own type rather than `dart:ui`'s `Rect` because this file is host code:
/// `fw` is a plain Dart binary with no Flutter in it, and the run plugin's
/// files are shared by the CLI, the GUI and the MCP server alike.
class NativeBounds {
  const NativeBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  double get width => right - left;
  double get height => bottom - top;

  bool get isEmpty => width <= 0 || height <= 0;

  Map<String, Object?> toJson() => {
    'x': left,
    'y': top,
    'width': width,
    'height': height,
  };

  String describe() =>
      '${left.round()},${top.round()} ${width.round()}x${height.round()}';
}

/// The native layer refusing, in the drive layer's own voice.
///
/// One exception type with a written message, because every surface renders a
/// refusal by stringifying it, and the message is the product: it says what to
/// do next, and lists what the layer *did* see so a wrong guess teaches the
/// right call.
class NativeRefusal implements Exception {
  NativeRefusal(this.message, {this.failure});

  final String message;

  /// Which way it was refused — `notFound`, `multiple`, `unsupported`,
  /// `unavailable` — mirroring the drive layer's own vocabulary.
  final String? failure;

  @override
  String toString() => message;
}

/// This platform has no honest mechanism for this verb.
class NativeUnsupported extends NativeRefusal {
  NativeUnsupported(super.message) : super(failure: 'unsupported');
}

/// A target, resolved against a native tree.
///
/// The wire grammar is the drive layer's, so an agent that has been tapping
/// Flutter widgets all session types the same thing here. What cannot mean
/// anything below the widget tree — `key`, `tooltip` — refuses and says so,
/// rather than matching nothing and looking like a missing button.
class NativeTarget {
  NativeTarget._(this._match, this.description, {this.index, this.point});

  /// Parses the wire spelling: a bare string is visible text, an object names
  /// the form. Adds one form the drive layer has no use for — `{"at": {"x":
  /// …, "y": …}}` — because a WKWebView publishes no tree and a point is the
  /// only way in.
  factory NativeTarget.parse(String spec) {
    Object? json;
    try {
      json = jsonDecode(spec);
    } on FormatException {
      // Bare text that never was JSON: `target=Allow` should not need quoting
      // rules, on either layer.
      return NativeTarget._((node) => node.label == spec, '"$spec"');
    }
    return _parse(json, spec);
  }

  static NativeTarget _parse(Object? json, String spec) {
    switch (json) {
      case String text:
        return NativeTarget._((node) => node.label == text, '"$text"');
      case {'text': String text}:
        return NativeTarget._((node) => node.label == text, '"$text"');
      case {'label': String label}:
        // On a native tree the accessibility label *is* the text: both
        // platforms publish one field. Accepted rather than refused so a
        // target that worked on the Flutter layer keeps working here.
        return NativeTarget._((node) => node.label == label, '"$label"');
      case {'containing': String text}:
        return NativeTarget._(
          (node) => node.label?.contains(text) ?? false,
          'text containing "$text"',
        );
      case {'role': String role}:
        return NativeTarget._((node) => node.role == role, 'role $role');
      case {'at': {'x': num x, 'y': num y}}:
        return NativeTarget._(
          (_) => false,
          'the point $x,$y',
          point: (x.toDouble(), y.toDouble()),
        );
      case {'nth': {'target': Object target, 'index': int index}}:
        var inner = _parse(target, spec);
        return NativeTarget._(
          inner._match,
          '${inner.description} #$index',
          index: index,
        );
      case {'key': _}:
        throw NativeRefusal(
          'A key is a Flutter widget property, and the native layer sees only '
          'what the platform publishes: text, labels and roles. Target this '
          'by its visible text, or drop `layer` to address the widget tree.',
          failure: 'unsupported',
        );
      case {'tooltip': _}:
        throw NativeRefusal(
          'A tooltip is a Flutter widget property, and the native layer sees '
          'only what the platform publishes. On a native tree the tooltip is '
          "usually the element's label, so try it as bare text, or drop "
          '`layer` to address the widget tree.',
          failure: 'unsupported',
        );
      case {'within': _}:
        throw NativeRefusal(
          '`within` scopes one widget inside another, which the native layer '
          'does not model. Use {"nth": {"target": …, "index": …}} to pick '
          'among several matches, or drop `layer` to address the widget tree.',
          failure: 'unsupported',
        );
      default:
        throw NativeRefusal(
          'not a native target: $spec. Use a bare string for visible text, or '
          'one of {"text"}, {"label"}, {"containing"}, {"role"}, '
          '{"nth": {"target", "index"}}, {"at": {"x", "y"}}.',
          failure: 'unsupported',
        );
    }
  }

  final bool Function(NativeNode) _match;

  /// How the refusal and the journal name it — the drive layer's spelling, so
  /// one story reads the same across both layers.
  final String description;

  /// Set by `nth`: which match was asked for.
  final int? index;

  /// Set by `at`: a bare point, in the observation's coordinate space.
  final (double, double)? point;

  /// The one node this names, or a refusal that says why not.
  ///
  /// The exactly-one rule is the drive layer's, kept verbatim because it is
  /// the rule that makes acting trustworthy: zero matches and several matches
  /// are both refusals, and neither is ever resolved by picking one.
  NativeNode resolve(NativeObservation observation) {
    var matches = [
      for (var node in observation.nodes)
        if (_match(node) && (node.bounds?.isEmpty ?? true) == false) node,
    ];
    if (index case var wanted?) {
      if (wanted < matches.length) return matches[wanted];
      throw NativeRefusal(
        'the native layer sees ${matches.length} match(es) for '
        '$description, so index $wanted is out of range.'
        '${_candidates(observation)}',
        failure: 'notFound',
      );
    }
    if (matches.length == 1) return matches.single;
    if (matches.isEmpty) {
      throw NativeRefusal(
        'the native layer sees nothing matching $description on '
        '${observation.platform}.${_candidates(observation)}',
        failure: 'notFound',
      );
    }
    throw NativeRefusal(
      'the native layer sees ${matches.length} things matching $description. '
      'Pick one with {"nth": {"target": …, "index": …}}. In order, they are: '
      '${matches.map((node) => node.describe()).join(', ')}.',
      failure: 'multiple',
    );
  }

  String _candidates(NativeObservation observation) {
    var seen = observation.speaking
        .where((node) => node.label != null)
        .map((node) => '"${node.label}"')
        .take(40)
        .join(', ');
    if (seen.isEmpty) {
      return ' It published no labelled elements at all, as happens with a '
          'screen drawn entirely in a platform view or a canvas. Only the '
          'screenshot shows it, and only {"at": {"x": …, "y": …}} can tap it.';
    }
    return ' It sees: $seen.';
  }
}
