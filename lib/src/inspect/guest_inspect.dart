import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

// `rendering` as well as `widgets`, for the layout half: `widgets.dart`
// re-exports a curated slice of rendering that has `RenderFlex` in it and not
// `FlexParentData`, and the parent data is where a child's flex actually
// lives. Still no `material` — a guest should not have to link Material to be
// inspectable.
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../translations/index.dart';
import 'node.dart';
import 'semantics.dart';
import 'semantics_capture.dart';

/// Reads the live widget tree out of a running guest.
///
/// The structure and the source locations come from the framework's own
/// inspector, and everything else is ours. That split is forced rather than
/// chosen: `--track-widget-creation` stores a widget's location behind
/// `_HasCreationLocation`, a private interface in `package:flutter`, and Dart
/// mangles private names per library — so no code here can read it, by
/// language rule rather than by omission. `WidgetInspectorService` is the only
/// thing that can, and [WidgetInspectorService.getRootWidgetSummaryTree] is
/// how it hands the value out.
///
/// What we keep is the part that matters across processes: the identity. The
/// inspector's ids are per-object-group and die with the process; ours are
/// derived from the tree's shape, so a tree read by one `fw` invocation can be
/// asked about by the next. See [InspectNode.id].
class GuestInspector {
  GuestInspector({required this.rootOf, required this.entryIdOf});

  /// The element the reported tree should start at — the demo, rather than the
  /// catalog chrome above it.
  ///
  /// A function because the subtree is remounted on every entry switch, so
  /// anything holding an [Element] would be holding the previous entry's.
  final Element? Function() rootOf;

  final String? Function() entryIdOf;

  /// Which way of describing a widget this walk writes, stamped on every tree
  /// it reads as [InspectTree.format].
  ///
  /// **Bump it whenever the same widgets would read back differently** — a
  /// description spelled out where it was not, a node the walk now keeps or
  /// drops, a key read another way. A comparison's two sides are captured by
  /// two checkouts' own copies of this class, and the stamp is the only thing
  /// that lets it tell a widget that changed from a walk that did: the tree
  /// differences between two formats are carried, and do not count.
  /// `test/inspect/tree_format_test.dart` fails when the reading of a fixed set
  /// of widgets moves and this did not.
  ///
  /// 1 — the first stamped. `Text.rich` and `RichText` describe themselves
  /// by their words, which is why the stamp exists: a tree read before it
  /// carries none, and against one it reported every such node as changed.
  ///
  /// 2 — boxes in logical pixels on a walk rooted at the view (a run, a
  /// scenario), where 1 reported them ×devicePixelRatio. See [boxWithin].
  static const treeFormat = 2;

  /// Registers the extensions. Call once, before `runApp`, beside the knobs and
  /// axes ones — an extension has to outlive every entry switch.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.tree', (_, _) async {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(read().toJson()),
      );
    });
    GuestExtensions.register('ext.flutterware.semantics', (_, args) async {
      switch (args['on']) {
        case 'true':
          enableSemantics(true);
        case 'false':
          enableSemantics(false);
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(readSemantics().toJson()),
      );
    });
    GuestExtensions.register('ext.flutterware.hitTest', (_, args) async {
      var x = double.tryParse(args['x'] ?? '');
      var y = double.tryParse(args['y'] ?? '');
      if (x == null || y == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.invalidParams,
          jsonEncode({'error': 'x and y are required, as numbers'}),
        );
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'ids': hitTest(x, y)}),
      );
    });
  }

  /// The tree as of the last build.
  ///
  /// Always the *summary* tree — the widgets the framework attributes to the
  /// user's code. There is deliberately no "give me everything" here, and the
  /// reason is worth recording because it looks like an omission: of the two
  /// public in-process readers, [WidgetInspectorService.getRootWidgetSummaryTree]
  /// returns a whole tree and `getRootWidget` returns the root and one level.
  /// The unfiltered whole tree is reachable only through the *service
  /// extension*, over a socket, from another process.
  ///
  /// So a `full` option here could only have been a filter over an
  /// already-filtered list — which is to say, a parameter that reads as a
  /// capability and does nothing. It was written that way first and measured:
  /// 44 nodes either way, zero of them non-local. If the whole tree is ever
  /// wanted it is a host-side call and its own decision.
  ///
  /// [filter] narrows what comes back and nothing else — the walk is the same
  /// walk, because the ids have to keep meaning positions in the whole tree.
  /// Unfiltered by default, which is what the inspect panel and the previews
  /// client have always been handed; the drive loop is the caller that asks
  /// for less.
  InspectTree read({InspectFilter? filter}) {
    var tree = _build().tree;
    return filter == null ? tree : tree.filtered(filter);
  }

  /// The handle that keeps semantics on while a panel is watching.
  ///
  /// A live app has semantics **off** — unlike `testWidgets`, which holds a
  /// handle by default — and building the tree costs every frame, so it runs
  /// only between the panel opening the Semantics tab and closing it. Held
  /// here rather than in the extension closure so [enableSemantics] is
  /// callable in-process too.
  SemanticsHandle? _semantics;

  /// Turns the semantics tree on or off.
  ///
  /// Idempotent both ways. Turning on schedules a frame, because the tree is
  /// built *by* a frame and an idle guest would otherwise never produce one —
  /// the read polls until it appears.
  void enableSemantics(bool on) {
    if (on) {
      if (_semantics != null) return;
      _semantics = SemanticsBinding.instance.ensureSemantics();
      SchedulerBinding.instance.ensureVisualUpdate();
    } else {
      _semantics?.dispose();
      _semantics = null;
    }
  }

  /// The semantics tree, as `semantics_capture.dart` shapes it.
  ///
  /// The entry id is withheld until there is a tree, so a poll settling on
  /// the id keeps waiting through the frame that builds it rather than
  /// accepting "nothing yet" as this entry's answer.
  InspectSemantics readSemantics() {
    var root = captureSemanticsTree();
    return InspectSemantics(
      entryId: root == null ? null : entryIdOf(),
      root: root,
    );
  }

  /// The nodes under a point, outermost first.
  ///
  /// Answers "what is at these pixels", which is one question asked by two
  /// callers: a panel turning a click into a selection, and an agent turning a
  /// screenshot into a node id. Both get the *chain* rather than the innermost
  /// hit, because the useful answer is usually a few levels out — the thing
  /// under the cursor is a `RenderParagraph` and the thing you meant is the
  /// button around it.
  ///
  /// [x] and [y] are in the guest's own coordinates, the same space
  /// [InspectLayout.x] reports and a capture is taken in.
  List<String> hitTest(double x, double y) {
    var (:tree, :byRenderObject) = _build();
    if (tree.root == null) return const [];
    var root = rootOf()?.renderObject;
    if (root is! RenderBox || !root.hasSize) return const [];

    // In the demo root's own coordinates — the window's for an embedder
    // guest, whose root is the window, and the picture's for a guest drawn
    // inside its host. The boxes the tree reports are in the same space.
    var result = BoxHitTestResult();
    root.hitTest(result, position: Offset(x, y));

    // Innermost first out of the framework, and reversed on the way out: a
    // caller reading a chain wants it the way the tree reads.
    var ids = <String>[];
    for (var entry in result.path) {
      var id = byRenderObject[entry.target];
      // The hit path is render objects, and most of them belong to widgets no
      // summary tree mentions. Those are not "no answer", they are the
      // framework's internals, so they are skipped rather than reported.
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    return ids.reversed.toList();
  }

  /// The render object [id] names, or null when this tree has no such node.
  ///
  /// The expensive direction, and deliberately not offered as something to call
  /// often: it costs a whole summary-tree walk, because an id *is* a position
  /// in the summary tree and nothing cheaper knows where that is. [GuestWatch]
  /// calls it once when the selection changes and holds the result — which is
  /// only safe because it also drops it whenever the shape moves.
  ///
  /// The map is keyed the other way round because the hit test needs it that
  /// way, and inverting a few dozen entries here beats building both.
  RenderObject? renderObjectFor(String id) {
    var (:tree, :byRenderObject) = _build();
    if (tree.root == null) return null;
    for (var entry in byRenderObject.entries) {
      if (entry.value == id) return entry.key;
    }
    return null;
  }

  ({InspectTree tree, Map<RenderObject, String> byRenderObject}) _build() {
    var entryId = entryIdOf();
    var byRenderObject = <RenderObject, String>{};
    // One entry per distinct style rather than per text — see [_describeStyle].
    var styles = <TextStyle, Map<String, String>>{};
    // One paragraph, one set of keys. Several widget nodes share a
    // `RenderParagraph` — a `Text` builds a `RichText` and both report it — so
    // without this the same key is recorded two or three times per screen,
    // each with a different box. Found by the gate run: 19 939 spans where the
    // screen had 6 750. Outermost wins, the same rule `byRenderObject` uses,
    // because the outermost node is the one a click means.
    var claimedParagraphs = <RenderObject>{};
    // Before the conversion, and for a reason — see [_sourceClaims].
    var sources = _sourceClaims(rootOf());
    // A group name of our own: the inspector refcounts these and the panel or
    // DevTools may be holding others against the same isolate.
    const group = 'flutterware.inspect';
    try {
      var decoded = jsonDecode(
        WidgetInspectorService.instance.getRootWidgetSummaryTree(group),
      );
      if (decoded is! Map) {
        return (
          tree: InspectTree(entryId: entryId, format: treeFormat),
          byRenderObject: byRenderObject,
        );
      }
      var json = decoded.cast<String, Object?>();
      var demo = _findPreview(json) ?? json;
      // The marker is ours, added so this could find the demo at all. Reporting
      // it would be reporting the observer: a caller would see a root whose
      // source is a file inside `package:flutterware` and reasonably wonder
      // what it had to do with their demo. It always has exactly one child.
      if (_elementOf(demo) == rootOf()) {
        if (demo['children'] case [Map only, ...]) {
          demo = only.cast<String, Object?>();
        }
      }
      return (
        tree: InspectTree(
          entryId: entryId,
          format: treeFormat,
          root: _convert(
            demo,
            '',
            byRenderObject,
            styles,
            claimedParagraphs,
            sources,
            null,
            false,
            false,
          ),
        ),
        byRenderObject: byRenderObject,
      );
    } finally {
      // Always: a group that outlives the read pins every Element in it, and
      // this runs on a live app rather than a debugger's breakpoint.
      //
      // `@protected` here means "reach these through the service extensions",
      // which is advice for a debugger talking over the VM service. We are
      // inside the guest, and going out to our own isolate over a socket to
      // ask it something it can answer synchronously would be the strange
      // choice. Same for `toObject` below.
      // ignore: invalid_use_of_protected_member
      WidgetInspectorService.instance.disposeGroup(group);
    }
  }

  /// The shallowest inspector node at or below the demo's root.
  ///
  /// Found by identity rather than by matching descriptions: every node in the
  /// JSON carries a `valueId`, and [WidgetInspectorService.toObject] turns that
  /// back into the very [DiagnosticsNode] it was made from. So this compares
  /// elements, not strings.
  ///
  /// It asks "at or below" rather than "is" because the marker itself need not
  /// be *in* the summary tree. A summary tree contains what the framework
  /// considers the user's code, and that verdict moves: today the marker
  /// qualifies because it is not in `package:flutter`, but a caller that
  /// narrows the pub roots to the project would drop it — and the demo below
  /// it would still be there. Matching on ancestry survives that; matching on
  /// the node itself would silently stop trimming.
  ///
  /// Null when nothing below the marker is in the tree, in which case the
  /// caller reports the whole thing: a tree with catalog chrome on top beats
  /// no tree.
  Map<String, Object?>? _findPreview(Map<String, Object?> json) {
    var marker = rootOf();
    if (marker == null) return null;

    Map<String, Object?>? search(Map<String, Object?> node) {
      if (_elementOf(node) case var element?) {
        if (_isAtOrBelow(element, marker)) return node;
      }
      for (var child in node['children'] as List? ?? const []) {
        if (child is! Map) continue;
        var hit = search(child.cast<String, Object?>());
        if (hit != null) return hit;
      }
      return null;
    }

    return search(json);
  }

  static bool _isAtOrBelow(Element element, Element marker) {
    if (identical(element, marker)) return true;
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (!identical(ancestor, marker)) return true;
      found = true;
      return false;
    });
    return found;
  }

  /// The words a node puts on screen, when it puts any there.
  ///
  /// The summary tree describes a `Text` as `Text` and nothing more — the
  /// framework's richer `Text("Save")` form comes from `withPreviews`, which is
  /// only reachable through the service extension. So this reads the widget
  /// itself, which is public API and exact.
  ///
  /// It is what makes searching by the words on screen work at all. Without it
  /// `find --query=Save` matches nothing, because no node's type or description
  /// has ever contained "Save" — which is the first thing anybody would try.
  ///
  /// `Text.rich` and a hand-written `RichText` too, spelled out of their spans.
  /// A chat bubble with a bold name and a link is one of those, and without
  /// them its words were in the picture and the `texts` and nowhere a `find`
  /// or a `screen` looks — the semantics label it sometimes matched by is the
  /// bubble's own only when nothing above it merges. The drawn words, not the
  /// spoken ones: a span's `semanticsLabel` is what a screen reader says, and
  /// `find` is asked about what is on the glass.
  ///
  /// `Tooltip` and the rest of the labelled widgets live in
  /// `package:flutter/material.dart`, and this file imports `widgets` so that
  /// a guest is not made to link Material to be inspected.
  static String? _preview(Element? element) => switch (element) {
    Element(widget: Text(:var data?)) => 'Text("$data")',
    Element(widget: Text(:var textSpan?)) => 'Text("${_plain(textSpan)}")',
    Element(widget: RichText(:var text)) => 'RichText("${_plain(text)}")',
    _ => null,
  };

  static String _plain(InlineSpan span) => span.toPlainText(
    includeSemanticsLabels: false,
    includePlaceholders: false,
  );

  Element? _elementOf(Map<String, Object?> node) {
    var id = node['valueId'];
    if (id is! String) return null;
    // ignore: invalid_use_of_protected_member
    var object = WidgetInspectorService.instance.toObject(id);
    return switch (object) {
      DiagnosticsNode(value: Element element) => element,
      Element element => element,
      _ => null,
    };
  }

  /// One inspector node and its children, in our shape, with [path] as the id.
  ///
  /// [ancestorRender] and [ancestorOffstage] carry the nearest converted
  /// ancestor's render object and verdict, so each render edge is judged once
  /// on the way down rather than re-climbed per node — and a subtree under an
  /// offstage ancestor is marked without climbing at all.
  InspectNode _convert(
    Map<String, Object?> json,
    String path,
    Map<RenderObject, String> byRenderObject,
    Map<TextStyle, Map<String, String>> styles,
    Set<RenderObject> claimedParagraphs,
    ({Map<Element, InspectKey> claims, Set<RenderObject> paragraphs}) sources,
    RenderObject? ancestorRender,
    bool ancestorOffstage,
    bool ancestorClaimed,
  ) {
    var children = json['children'] as List? ?? const [];
    var described = json['description'] as String?;
    var type = json['widgetRuntimeType'] as String? ?? described ?? '';
    // The key is a fact of its own, and one that has to survive the wire —
    // see [InspectNode.splitKey], which the VM-service path calls too.
    var (:description, key: widgetKey) = InspectNode.splitKey(described, type);
    // Resolved once for the three readers below: the id round-trips through
    // the inspector's object registry, which is not free per node.
    var element = _elementOf(json);
    var render = element?.renderObject;
    var textStyle = _textStyleOf(render, styles);
    // **The widget's own property, for anything that renders text its own way.**
    // A markdown renderer builds its spans out of substrings and a chart paints
    // its labels with no paragraph at all, so identity finds nothing below
    // here — but the string the catalog handed out is still sitting on the
    // widget, and reading it there is exact rather than inferred.
    var claimed = element == null ? null : sources.claims[element];
    var spans = _keysOf(
      render,
      claimedParagraphs,
      sources.paragraphs,
      isSource: claimed != null,
    );
    // A source with more than one paragraph under it — which any real markdown
    // block has — is only partly covered by the paragraph set above, so the
    // rest are silenced on the way down. Keys are *not* silenced: a resolved
    // key under here came from a second read and is a fact of its own.
    var underClaim = ancestorClaimed || claimed != null;
    if (render != null) {
      // First writer wins. Several widgets in a summary tree can share one
      // render object — a `Padding` under a `Semantics` under a builder all
      // report the same box — and the outermost is the one a click means.
      byRenderObject.putIfAbsent(render, () => path);
    }
    var offstage =
        ancestorOffstage ||
        (render != null && !_shown(render, upTo: ancestorRender));
    return InspectNode(
      id: path,
      type: type,
      // Only when it says more than the type does. `Text("Save")` earns its
      // place; a `Padding` described as "Padding" is the type twice.
      description:
          _preview(element) ?? (description == type ? null : description),
      widgetKey: widgetKey,
      createdByLocalProject: json['createdByLocalProject'] as bool? ?? false,
      offstage: offstage,
      properties: _propertiesOf(element?.widget, textStyle.keys.toSet()),
      textStyle: textStyle,
      // Only for something that draws words. Every one of these is another
      // walk up the element tree or another style described, and a tree is
      // mostly nodes with no glyphs in them at all.
      inheritedStyle: textStyle.isEmpty
          ? const {}
          : _ambientStyleOf(element, styles),
      styleReplacesInherited: textStyle.isEmpty
          ? null
          : _replacesInherited(element?.widget),
      keys: claimed == null ? spans.keys : [claimed, ...spans.keys],
      unkeyedText: underClaim ? const [] : spans.unkeyed,
      textOverflowed: spans.overflowed,
      source: switch (json['creationLocation']) {
        Map location => InspectSource.fromJson(
          location.cast<String, Object?>(),
        ),
        _ => null,
      },
      layout: _layoutOf(render, within: rootOf()?.renderObject),
      label: _labelOf(render),
      selected: _selectedOf(render),
      children: [
        for (var (index, child) in children.indexed)
          if (child is Map)
            _convert(
              child.cast<String, Object?>(),
              path.isEmpty ? '$index' : '$path/$index',
              byRenderObject,
              styles,
              claimedParagraphs,
              sources,
              render ?? ancestorRender,
              offstage,
              underClaim,
            ),
      ],
    );
  }

  /// Whether [render] is actually shown, judged over the render chain up to
  /// (and excluding) [upTo] — the nearest converted ancestor's render object.
  ///
  /// The oracle is `visitChildrenForSemantics`. The summary tree keeps the
  /// user's widgets and drops the framework's, and the framework's is where
  /// all the hiding happens — `_RenderTheater` skipping the routes a pushed
  /// screen covers, `RenderOffstage`, `RenderIndexedStack` showing one child
  /// of several. So the marker never survives into the tree, only the hidden
  /// content does, wearing rects from the last time it was laid out. What
  /// every one of those hiders has in common is that it also keeps the hidden
  /// child out of the semantics walk, by overriding this exact method — it is
  /// the same mechanism that keeps a covered route out of a screen reader.
  ///
  /// The known exceptions — the classes that skip the semantics walk while
  /// still painting the child — are exempted by type. All four are public,
  /// and the list was taken from the SDK's overrides, not guessed (see
  /// `2026-08-10-inspect-consolidation.md`).
  static bool _shown(RenderObject render, {required RenderObject? upTo}) {
    var node = render;
    while (!identical(node, upTo)) {
      var parent = node.parent;
      if (parent == null) break;
      if (!_visitsForSemantics(parent, node)) return false;
      node = parent;
    }
    return true;
  }

  /// What [widget] says about itself, filtered to what a reader would keep.
  ///
  /// The framework's diagnostics are written for dumps and are mostly noise
  /// at a detail pane's distance, so three cuts: only `DiagnosticLevel.info`
  /// and up (`fine` is `dependencies: [MediaQuery]` and friends), the value
  /// itself cut down by [shortenPropertyValue] (a colour to its hex, a
  /// `TextStyle`'s paragraph to its head), and at most twelve per node. The
  /// walk pays this on every node of every read — measured before keeping,
  /// like the semantics capture before it: +168µs on the shop tree's 1.5ms
  /// read, +6KB on its 37KB JSON (see the consolidation spec).
  /// [styleKeys] are the fields the resolved style already carries, and they
  /// are exempt from the cap — see the counter below.
  static Map<String, String> _propertiesOf(
    Widget? widget,
    Set<String> styleKeys,
  ) {
    if (widget == null) return const {};
    var properties = <String, String>{};
    var configuration = 0;
    for (var property in widget.toDiagnosticsNode().getProperties()) {
      if (property.isFiltered(DiagnosticLevel.info)) continue;
      var name = property.name;
      if (name == null) continue;
      // Every `Text` inlines its style's diagnostics, and these three say the
      // same thing on every one of them — see [_plumbing].
      if (_plumbing.contains(name)) continue;
      var value = property.toDescription();
      if (value.isEmpty || value == 'null') continue;
      properties[name] = shortenPropertyValue(value);
      // **The cap counts the widget's own configuration, not its style.**
      // A `Text` handed a whole theme slot reports fifteen properties, eleven
      // of them style fields — measured, `overflow` and `maxLines` fell off
      // the end of a cap of twelve, and they are exactly the two rows the
      // detail pane's `widget` block exists to show. The style fields used to
      // be the noise this cap was defending against; now the pane groups by
      // them, so they may ride along, but they must not be what starves the
      // rest.
      if (!styleKeys.contains(name) && ++configuration >= 12) break;
    }
    return properties;
  }

  /// The default text style in force where this widget sits.
  ///
  /// The third column of the merge, and the only one that cannot be derived
  /// from the other two: what the *theme* offered here, including for the
  /// fields the widget went on to override. Without it "you set 13" cannot be
  /// told from "you set 13, and it was already 13" — an override that changes
  /// nothing is a line of source that could go, and a design system wants to
  /// know which of its overrides are those.
  ///
  /// Read without registering a dependency.
  /// [BuildContext.getInheritedWidgetOfExactType] is documented O(1) and,
  /// unlike `dependOnInheritedWidgetOfExactType`, leaves no trace: an
  /// inspector that dirtied the elements it looked at would change the app it
  /// is reporting on. Measured at 13µs for a whole walk's worth of lookups —
  /// the describing is the cost, not the finding, which is what
  /// [_describeStyle] is for.
  ///
  /// It is *ambient*, not necessarily inherited: see [_replacesInherited].
  static Map<String, String> _ambientStyleOf(
    Element? element,
    Map<TextStyle, Map<String, String>> styles,
  ) {
    var style = element
        ?.getInheritedWidgetOfExactType<DefaultTextStyle>()
        ?.style;
    return style == null ? const {} : _describeStyle(style, styles);
  }

  /// Whether the widget's own style **replaced** the ambient one rather than
  /// merging with it — or null when this kind of widget cannot say.
  ///
  /// `Text.build` merges the default style only when the widget's own is null
  /// or `inherit: true`. Material's type-ramp entries are `inherit: false`, so
  /// `style: theme.textTheme.titleLarge` throws the ambient style away
  /// wholesale — measured, the resolved provenance then names `titleLarge` and
  /// never mentions the `bodyMedium` that was in scope.
  ///
  /// This is the difference between a column of values that contributed and a
  /// column that merely *was in the air*, and a pane that showed the second as
  /// the first would be confidently wrong. Null for a widget that builds its
  /// paragraph internally — an `Icon` — because a guess there would be the
  /// same mistake in miniature.
  static bool? _replacesInherited(Widget? widget) => switch (widget) {
    Text(:var style?) => !style.inherit,
    RichText(text: TextSpan(style: var style?)) => !style.inherit,
    _ => null,
  };

  /// The style this node's glyphs were painted with — **resolved, and read off
  /// the render tree rather than off the widget.**
  ///
  /// [_propertiesOf] answers what the author wrote, because
  /// `Text.debugFillProperties` reports `style?.debugFillProperties(…)` and
  /// that style is null for most of the text in a themed app. Measured, a bare
  /// `Text` under a `MaterialApp` reports exactly one property — its words —
  /// while drawing 14pt Roboto at `#1D1B20` with `letterSpacing: 0.3`. Ten
  /// facts, none of them reported, and the one place they were being consumed
  /// (`InspectTree.styles`, the type ramp) was silently answering about the
  /// exceptions.
  ///
  /// `Text.build` merges the ambient `DefaultTextStyle`, then
  /// `MediaQuery.boldTextOf` and the line-height/letter-spacing/word-spacing
  /// overrides, into the span it hands down; `RenderParagraph.text` is where
  /// that merged span is public. So this is the answer after every inherit,
  /// merge, apply and accessibility override — the thing a person means when
  /// they ask what a style *is*.
  ///
  /// `debugLabel` rides along under its own name, and it is the provenance:
  /// Material seeds one per type-ramp slot and every `merge`, `apply` and
  /// `copyWith` extends it, so ordinary body text reads `(englishLike
  /// bodyMedium 2021).merge((blackMountainView bodyMedium).apply)`. A
  /// hand-written `TextStyle` literal contributes `unknown` and a style no
  /// labelled ancestor touched has none at all — both are absences of
  /// authorship rather than failures of the read, and are left to say so.
  ///
  /// Measured before keeping, like the properties and the semantics capture
  /// before it: **+47µs on a 2367µs property pass** over 984 elements, 72 of
  /// them paragraphs. Only paragraphs pay, and a summary tree is a few dozen
  /// nodes. `Icon` comes along for nothing — it is a `RichText` over an icon
  /// font, so its size and colour arrive by the same route.
  static Map<String, String> _textStyleOf(
    RenderObject? render,
    Map<TextStyle, Map<String, String>> styles,
  ) {
    var style = _paragraphOf(render)?.text.style;
    return style == null ? const {} : _describeStyle(style, styles);
  }

  /// Which translation keys this node's glyphs came from, and how many of its
  /// spans came from no catalog at all.
  ///
  /// Per span, not per `Text`. A first version read `Text.data` and
  /// flattened a `Text.rich` with `toPlainText()`, which destroyed exactly the
  /// case worth resolving — a sentence assembled from a translated fragment and
  /// a name. The paragraph's own span tree keeps the pieces apart, and `Text`
  /// passes its `data` straight into its span, so reading the paragraph is
  /// every glyph exactly once either way.
  ///
  /// Offsets are over the paragraph's plain text, so a range lines up with what
  /// a reader sees. A placeholder — a `WidgetSpan` — occupies one code unit
  /// there, and is counted as such rather than skipped, or every range after an
  /// inline icon would be off by one.
  ///
  /// Free when nothing registered: [TranslationIndex.recording] is false under
  /// a bare `flutter test`, and this returns before touching the render tree.
  static ({List<InspectKey> keys, List<String> unkeyed, bool overflowed})
  _keysOf(
    RenderObject? render,
    Set<RenderObject> claimed,
    Set<RenderObject> fromSource, {
    required bool isSource,
  }) {
    const none = (keys: <InspectKey>[], unkeyed: <String>[], overflowed: false);
    if (!TranslationIndex.recording) return none;
    var paragraph = _paragraphOf(render);
    if (paragraph == null) return none;
    // Every span in here is one widget's string, reparsed into substrings by
    // the widget itself — debris rather than text anybody wrote. The key comes
    // off the property instead. Checked before the claim so a wrapper above
    // does not consume the paragraph and leave the source with nothing: the
    // source is the one node still worth asking whether it fits.
    if (fromSource.contains(paragraph)) {
      return isSource
          ? (
              keys: <InspectKey>[],
              unkeyed: <String>[],
              overflowed: _overflowed(paragraph),
            )
          : none;
    }
    if (!claimed.add(paragraph)) return none;
    var root = paragraph.text;

    var keys = <InspectKey>[];
    var unkeyed = <String>[];
    var offset = 0;
    void visit(InlineSpan span) {
      if (span is! TextSpan) {
        offset += 1;
        return;
      }
      if (span.text case var text?) {
        // An `Icon` is a `RichText` over an icon font, so it arrives here as a
        // one-glyph span in the Private Use Area. Not text, and counting it
        // would put every icon in the app in the unkeyed pile — measured at
        // 1146 of 7896 spans on one real suite, 17%.
        if (!_isIconGlyph(text)) {
          if (TranslationIndex.keyOf(text) case var found?) {
            keys.add(
              InspectKey(
                catalog: found.catalog,
                key: found.key,
                start: offset,
                end: offset + text.length,
              ),
            );
          } else {
            unkeyed.add(text);
          }
        }
        offset += text.length;
      }
      for (var child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }

    visit(root);
    return (
      keys: keys,
      unkeyed: unkeyed,
      // Free: the paragraph is already in hand, and this is the whole of "does
      // it still fit in the other language".
      overflowed: _overflowed(paragraph),
    );
  }

  /// Whether this paragraph ran out of room — **false where it has not been
  /// laid out**, because that is not a fact about the text.
  ///
  /// `didExceedMaxLines` asserts `!debugNeedsLayout`, and a mounted paragraph
  /// with no layout is ordinary rather than exotic: `RenderTheatre` lays out
  /// only its onstage children, so **every route kept below an opaque one is
  /// in the tree with no size**, and this walk goes through offstage subtrees
  /// on purpose. An app that deep-links straight past its first screen has
  /// two of them on the very first capture, which is where this was found —
  /// the assertion took the whole scenario down before it captured a step.
  ///
  /// `hasSize` rather than `debugNeedsLayout`: it is the guard the rest of
  /// this file already uses, and it is the one that means the same thing in
  /// release.
  static bool _overflowed(RenderParagraph paragraph) =>
      paragraph.hasSize && paragraph.didExceedMaxLines;

  /// Every key a registered widget property names, found *before* the walk.
  ///
  /// A pre-pass rather than a lookup during the conversion, because of who
  /// reaches the paragraph first. [_paragraphOf] descends a single-child render
  /// chain, so a `Center` three levels *above* a markdown block arrives at its
  /// paragraph too — and the walk being top-down, it claims those fragments as
  /// unkeyed before the widget still holding the original string is converted
  /// at all. Suppression that only flows downward cannot reach it. Knowing the
  /// paragraphs up front is what lets every node above one decline it.
  ///
  /// Free when nothing registered, which is every project that has not asked
  /// for it: the element tree is not walked.
  static ({Map<Element, InspectKey> claims, Set<RenderObject> paragraphs})
  _sourceClaims(Element? root) {
    var claims = <Element, InspectKey>{};
    var paragraphs = <RenderObject>{};
    if (root == null ||
        !TranslationIndex.recording ||
        TranslationIndex.sources.isEmpty) {
      return (claims: claims, paragraphs: paragraphs);
    }
    void visit(Element element) {
      if (_sourceKeyOf(element.widget) case var key?) {
        claims[element] = key;
        if (_paragraphOf(element.renderObject) case var paragraph?) {
          paragraphs.add(paragraph);
        }
      }
      element.visitChildren(visit);
    }

    visit(root);
    return (claims: claims, paragraphs: paragraphs);
  }

  /// The key a registered widget property names, or null.
  ///
  /// First source that both matches the widget *and* resolves wins. A source
  /// whose property holds a string no catalog minted does not stop the next
  /// one being tried, so registering two for one widget is safe.
  static InspectKey? _sourceKeyOf(Widget? widget) {
    if (!TranslationIndex.recording || widget == null) return null;
    for (var source in TranslationIndex.sources) {
      if (source(widget) case var text?) {
        if (TranslationIndex.keyOf(text) case var found?) {
          return InspectKey(catalog: found.catalog, key: found.key);
        }
      }
    }
    return null;
  }

  static bool _isIconGlyph(String text) =>
      text.runes.isNotEmpty &&
      text.runes.every((rune) => rune >= 0xE000 && rune <= 0xF8FF);

  /// One style as rows — **memoised across the walk**, which is most of what
  /// it costs.
  ///
  /// A screen has far fewer styles than texts. Measured on a thirty-card list:
  /// 112 paragraphs and three distinct resolved styles, two distinct
  /// ambient ones. `debugFillProperties` and a `toDescription` per field is
  /// the expensive half and it was being paid per *text*. Keyed on the style
  /// itself, so two equal styles built in different places still share an
  /// entry — `TextStyle` has value equality.
  ///
  /// On that tree: resolved 288µs → 135µs, ambient 304µs → 84µs. Which is why
  /// adding the ambient style *lowered* the cost of the pass it joined, and
  /// why the memo is threaded through the walk rather than kept on the
  /// inspector — it must not outlive the read and pin styles.
  static Map<String, String> _describeStyle(
    TextStyle style,
    Map<TextStyle, Map<String, String>> styles,
  ) => styles.putIfAbsent(style, () {
    var builder = DiagnosticPropertiesBuilder();
    style.debugFillProperties(builder);
    var resolved = <String, String>{};
    for (var property in builder.properties) {
      if (property.isFiltered(DiagnosticLevel.info)) continue;
      var name = property.name;
      if (name == null) continue;
      if (_plumbing.contains(name)) continue;
      var value = property.toDescription();
      if (value.isEmpty || value == 'null') continue;
      // A decoration that decorates nothing. The value is spelled
      // `#3A3D43 TextDecoration.none` — a colour, which reads like an answer,
      // for a line that is not drawn.
      if (name == 'decoration' && value.endsWith('TextDecoration.none')) {
        continue;
      }
      resolved[name] = shortenPropertyValue(value);
    }
    return resolved;
  });

  /// Fields every resolved style carries and no reader acts on.
  ///
  /// The same cut [_propertiesOf] makes, one level down and for a sharper
  /// reason: these are not *usually* uninteresting, they are filled in on
  /// literally every text a Material app draws, so a row for each is three
  /// lines of `alphabetic` / `even` / `false` on every node of every read.
  /// `inherit` is here because a resolved style is `inherit: false` by
  /// construction — it is the resolution saying it happened.
  ///
  /// Seen in the pane before being cut: the detail of a heading read
  /// `baseline alphabetic`, `leadingDistribution even`, and a `decoration`
  /// whose value was a colour and the word `none`.
  static const _plumbing = {'inherit', 'baseline', 'leadingDistribution'};

  /// The paragraph [render] draws through, or null.
  ///
  /// Nearly always [render] itself: `Element.renderObject` already descends to
  /// the first descendant render object, so an ordinary `Text` node arrives
  /// here holding its own `RenderParagraph` and this returns on the first line.
  ///
  /// The walk is for the two shapes where it does not. An `Icon` puts a sized
  /// box and a centre above its `RichText`, and a `Text` inside a
  /// `SelectionContainer` builds a `MouseRegion` and a selection container
  /// first — in both, the widget being asked about is a couple of render
  /// objects above the glyphs.
  ///
  /// It follows only-children, and a depth bound was tried first and was
  /// wrong in both directions. Render depth is not widget depth: two render
  /// levels can span fifteen widgets, so "two levels down" let a `Scaffold`
  /// adopt the style of a `Text` two `Column`s inside it, while an `Icon` —
  /// three render objects, all of them plumbing — still came back empty. Both
  /// were caught by `test/inspect/guest_properties_test.dart` rather than
  /// reasoned about, and both cases are pinned there.
  ///
  /// A chain of only-children is a more accurate version of what the bound was
  /// reaching for, and it is the noise filter's rule seen from another angle:
  /// a render object with one child is not deciding anything about it, so a
  /// paragraph at the end of such a chain *is* what this node draws. The
  /// moment a node has two children it is composing rather than wrapping, and
  /// the walk stops — which is what keeps a `Column` of texts from claiming
  /// the first one's style. The depth cap that remains is a runaway guard, not
  /// the rule.
  static RenderParagraph? _paragraphOf(RenderObject? render) {
    var node = render;
    for (var depth = 0; node != null && depth < 6; depth++) {
      if (node is RenderParagraph) return node;
      RenderObject? only;
      var many = false;
      node.visitChildren((child) {
        if (only == null) {
          only = child;
        } else {
          many = true;
        }
      });
      node = many ? null : only;
    }
    return null;
  }

  static bool _visitsForSemantics(RenderObject parent, RenderObject child) {
    // Semantics-excluded but painted: skipping the semantics walk is these
    // classes' entire job, and their child is on screen all the same.
    if (parent is RenderExcludeSemantics ||
        parent is RenderIgnorePointer ||
        parent is RenderAbsorbPointer ||
        parent is RenderSliverIgnorePointer ||
        parent is SemanticsAnnotationsMixin) {
      return true;
    }
    var found = false;
    parent.visitChildrenForSemantics((visited) {
      if (identical(visited, child)) found = true;
    });
    return found;
  }
}

/// The semantics node [render] contributes to, or null.
///
/// Up the render tree, never by comparing rectangles. A widget with no
/// semantics of its own sits inside another's, so the walk climbs until it
/// finds one — exact, and cheap because the render object is already in
/// hand. The rectangle alternative was tried and is wrong in both directions:
/// a `Checkbox`'s node is smaller than the `CheckboxListTile` that owns it and
/// a `Tab`'s is 9.5× larger than the `Tab` widget, so a containment test
/// reported that Flutter publishes no tab selection. It does. Measured 60 of 60
/// controls matched this way — see the S6 spike findings.
///
/// Null outside debug mode and whenever the app holds no `SemanticsHandle`;
/// both are absences rather than answers, which is why [InspectNode.selected]
/// is a tri-state.
SemanticsNode? _semanticsOf(RenderObject? render) {
  var at = render;
  while (at != null) {
    if (at.debugSemantics case var node?) return node;
    at = at.parent;
  }
  return null;
}

/// This widget's own accessibility label — **no climbing.**
///
/// The two fields want different walks, and running one for both was a bug
/// worth recording. Semantics merges: a header wrapped in `MergeSemantics`
/// owns one node whose label is every string under it concatenated, and its
/// descendants own nothing. Climbing from a `Text` in that header therefore
/// returns the *whole header* as that text's label — measured live, eight
/// different texts on one screen all reporting
/// `"Changes / …/ Watching / 14 files / +583 / …"`.
///
/// A label describes the thing it is on, so it is read off the render object
/// itself or not at all. A widget with nothing of its own falls through to the
/// words inside it, which is what [Screen] does next and what the Brewline
/// cards needed anyway. [_selectedOf] still climbs, because a selection state
/// genuinely belongs to the control above: a `Tab`'s flags live on the tab's
/// semantics node, not on the `Tab` widget's 38pt label box.
/// Down, not up, and only when the answer is unambiguous: the *one* semantics
/// node in this widget's subtree, when there is exactly one.
///
/// This is what a `TextField` needs. Its hint is built by the framework's own
/// internals, so it is not in the summary tree and no roll-up can reach it —
/// measured, `find "Filter"` matches nothing on a screen with a "Filter paths"
/// field on it — but the `EditableText` inside does publish it. One node in
/// the subtree is that widget describing itself through a child. Two or more
/// is a container, and the roll-up is the right answer there.
///
/// Bounded on both counts, because this runs per node of every read: it stops
/// at the second node it finds and six render objects down.
String? _labelOf(RenderObject? render) {
  if (render == null) return null;
  var own = render.debugSemantics?.getSemanticsData().label;
  if (own != null && own.isNotEmpty) return own;

  SemanticsNode? only;
  var many = false;
  void descend(RenderObject node, int depth) {
    if (many || depth > 6) return;
    node.visitChildren((child) {
      if (many) return;
      if (child.debugSemantics case var semantics?) {
        if (only != null) {
          many = true;
          return;
        }
        only = semantics;
        return;
      }
      descend(child, depth + 1);
    });
  }

  descend(render, 0);
  if (many || only == null) return null;
  var label = only!.getSemanticsData().label;
  return label.isEmpty ? null : label;
}

/// Whether this is the current one of its group: true, false, or *nothing
/// said*. See [InspectNode.selected] for why the third state is load-bearing.
bool? _selectedOf(RenderObject? render) {
  var data = _semanticsOf(render)?.getSemanticsData();
  if (data == null) return null;
  var flags = data.flagsCollection.toStrings().toSet();
  if (flags.contains('isSelected') ||
      flags.contains('isChecked') ||
      flags.contains('isToggled')) {
    return true;
  }
  if (flags.contains('hasSelectedState') ||
      flags.contains('hasCheckedState') ||
      flags.contains('hasToggledState')) {
    return false;
  }
  return null;
}

/// [render]'s box in [within]'s coordinates, which are logical pixels.
///
/// A root that is the view itself — a run guest's, a scenario's — measures to
/// the window instead. The view's own paint transform is the device pixel
/// ratio, and `getTransformTo` applies it when the view is named and skips it
/// when it is not: naming it reported every box ×3 on a phone, in a space no
/// `at` and no hit test speaks.
Rect boxWithin(RenderBox render, RenderObject? within) =>
    MatrixUtils.transformRect(
      render.getTransformTo(within is RenderView ? null : within),
      Offset.zero & render.size,
    );

/// The geometry of one render object, or null when it has none to report.
///
/// Null rather than zeroes for a widget with no box of its own, and null for
/// one that has not been laid out: a size read before layout is not a size, it
/// is whatever was there last time.
///
/// Relative to [within] — the demo's root — rather than to the window. The
/// two coincide in an embedder guest, whose root *is* the window, and differ
/// for a guest drawn inside its host, where a box in window coordinates
/// would be a box on the studio.
InspectLayout? _layoutOf(RenderObject? render, {RenderObject? within}) {
  if (render is! RenderBox || !render.hasSize) return null;
  // The whole rect through the transform, not an origin from `localToGlobal`
  // beside a raw `render.size`. Those two are in different spaces the moment
  // any ancestor scales — a preview stage fitting a device to its pane, the
  // shell scaling itself below its minimum window size — and mixing them
  // reports a box whose position is on screen and whose size is not. Every
  // number a reader compares (a centre against `at "x,y"`, a width against the
  // screenshot) then quietly disagrees with the picture.
  var bounds = boxWithin(render, within);
  return InspectLayout(
    x: bounds.left,
    y: bounds.top,
    width: bounds.width,
    height: bounds.height,
    constraints: InspectConstraints(
      minWidth: render.constraints.minWidth,
      maxWidth: render.constraints.maxWidth,
      minHeight: render.constraints.minHeight,
      maxHeight: render.constraints.maxHeight,
    ),
    isRepaintBoundary: render.isRepaintBoundary,
    flex: switch (render) {
      RenderFlex flex => InspectFlex(
        direction: flex.direction.name,
        mainAxisAlignment: flex.mainAxisAlignment.name,
        crossAxisAlignment: flex.crossAxisAlignment.name,
        mainAxisSize: flex.mainAxisSize.name,
      ),
      _ => null,
    },
    // Read off the parent data rather than off a widget, because that is where
    // it lives: `Expanded` is a widget that writes a number onto its child.
    flexFactor: switch (render.parentData) {
      FlexParentData(:var flex) => flex,
      _ => null,
    },
    flexFit: switch (render.parentData) {
      FlexParentData(fit: var fit?) => fit.name,
      _ => null,
    },
  );
}
