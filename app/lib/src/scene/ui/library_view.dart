import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';
import '../tokens_file.dart';
import '../tokens_library.dart';
import 'inline_name.dart';
import 'swatches.dart';
import 'token_editor.dart';
import 'tokens_host.dart';

/// A token library, on its own page: a table of contents down the left, and
/// the tokens drawn as what they are — with the one you are editing opened
/// where it stands.
///
/// **A library is a design system.** Colours, numbers, type styles: what a
/// package's scenes share about how they look. Not a bag of values — copy is
/// a scene's parameter or the app's, a flag is configuration, and the file
/// grammar refuses both by name ([notADesignValue]). They were only ever
/// here because a token reused the *parameter* kinds.
///
/// **What you edit opens beside its picture.** A style's fields open under
/// its own specimen; a colour's picker under the palette it has to work
/// against. There is no side column: editing sixteen fields on the right
/// while the thing they describe sat in the middle, scrolled away, was the
/// first shape and it did not survive being used.
///
/// Grouped by kind rather than kept in the file's order, and the emitter
/// writes the grouped order back, so the file and the page agree.
class SceneLibraryView extends StatefulWidget {
  const SceneLibraryView(
    this.library, {
    super.key,
    this.exports = const [],
    this.readersOf,
    this.deleteProblem,
    this.onRename,
    this.onDelete,
    this.taken = const {},
    this.onImport,
    this.initialSelection,
  });

  final TokensLibrary library;

  /// The tokens the app exports — named here because a scene reads them the
  /// same way, and read-only because their value is the app's.
  final List<SceneTokenDecl> exports;

  /// Who reads [name], as `Scene · node.prop`, across every group.
  final List<String> Function(String name)? readersOf;

  /// Why [name] cannot be deleted, or null.
  final String? Function(String name)? deleteProblem;

  /// Renames across the library and every reader. Throws an [ArgumentError]
  /// to refuse.
  final void Function(String name, String wanted)? onRename;

  final void Function(String name)? onDelete;

  /// Names the group's other libraries and the exports already use — what a
  /// new token must not collide with.
  final Set<String> taken;

  /// Merges a design file's variables in; null hides the door.
  final VoidCallback? onImport;

  /// The token to open on. Applied again when it changes.
  final String? initialSelection;

  static const railWidth = 176.0;

  @override
  State<SceneLibraryView> createState() => _SceneLibraryViewState();
}

/// The sheet's sections, in order: the two value kinds a design system holds
/// ([libraryTokenOrder]), then the styles, then the app's own.
const _colours = 'Colours';
const _numbers = 'Numbers';
const _styles = 'Type styles';
const _exports = 'From the app';

class _SceneLibraryViewState extends State<SceneLibraryView> {
  /// The token opened for editing, by name, or null. By name rather than by
  /// declaration: an edit replaces the object.
  String? _selected;

  /// The token being named right after it was added, so the first thing
  /// typed is its name.
  String? _naming;

  /// Where each section starts, so the rail can scroll to it.
  final _anchors = <String, GlobalKey>{
    _colours: GlobalKey(),
    _numbers: GlobalKey(),
    _styles: GlobalKey(),
    _exports: GlobalKey(),
  };

  TokensLibrary get library => widget.library;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelection;
  }

  @override
  void didUpdateWidget(SceneLibraryView old) {
    super.didUpdateWidget(old);
    var wanted = widget.initialSelection;
    if (wanted != null && wanted != old.initialSelection) _selected = wanted;
  }

  List<SceneTokenDecl> _of(SceneParamKind kind) => [
    for (var t in library.tokens)
      if (!t.isStyle && t.kind == kind) t,
  ];

  List<SceneTokenDecl> get _styleTokens => [
    for (var t in library.tokens)
      if (t.isStyle) t,
  ];

  bool _isOpen(SceneTokenDecl t) => _selected == t.name;

  void _select(SceneTokenDecl t) => setState(() {
    // Clicking the open one closes it, which is how the palette comes back
    // whole once a colour has been picked.
    _selected = _isOpen(t) ? null : t.name;
    _naming = null;
  });

  void _add(SceneParamKind kind) {
    var free = library.freeName(kind.name, taken: widget.taken);
    library.add(free, kind, taken: widget.taken);
    setState(() {
      _selected = free;
      _naming = free;
    });
  }

  void _addStyle() {
    var free = library.freeName('style', taken: widget.taken);
    library.addStyle(free, taken: widget.taken);
    setState(() {
      _selected = free;
      _naming = free;
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library.listenable,
    builder: (context, _) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: SceneLibraryView.railWidth, child: _rail(context)),
        Container(width: 1, color: context.colors.line),
        Expanded(child: _sheet(context)),
      ],
    ),
  );

  // --- The rail ------------------------------------------------------------

  /// A table of contents and the design file. Nothing is edited here: a row
  /// scrolls the sheet to its section, which is all a rail is for once the
  /// tokens are drawn full size beside it.
  Widget _rail(BuildContext context) {
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.md),
      children: [
        _railRow(context, _colours, _of(SceneParamKind.color).length),
        _railRow(context, _numbers, _of(SceneParamKind.number).length),
        _railRow(context, _styles, _styleTokens.length),
        if (widget.exports.isNotEmpty)
          _railRow(context, _exports, widget.exports.length),
        const Gap(FwSpacing.lg),
        Container(height: 1, color: colors.line),
        const Gap(FwSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
          child: Text(
            'DESIGN FILE',
            style: context.type.caption.copyWith(color: colors.mut3),
          ),
        ),
        const Gap(FwSpacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
          child: _import(context),
        ),
      ],
    );
  }

  Widget _railRow(BuildContext context, String title, int count) => Tappable(
    key: ValueKey('library:rail:$title'),
    onTap: () {
      var anchor = _anchors[title]?.currentContext;
      if (anchor == null) return;
      Scrollable.ensureVisible(
        anchor,
        duration: const Duration(milliseconds: 180),
        alignment: 0.02,
      );
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: context.type.body,
            ),
          ),
          Text(
            '$count',
            style: context.type.caption.copyWith(color: context.colors.mut2),
          ),
        ],
      ),
    ),
  );

  Widget _import(BuildContext context) {
    var colors = context.colors;
    var micro = context.type.micro.copyWith(color: colors.mut2);
    var note = library.importNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (note == null)
          Text(
            "Nothing imported yet. A design file's colours and numbers merge "
            'in by name: yours stay, theirs update.',
            style: micro,
          )
        else ...[
          Text(
            'Imported ${note.from} on ${note.when} — ${note.summary}.',
            key: const ValueKey('library:import-note'),
            style: micro,
          ),
          if (note.notImported.isNotEmpty) ...[
            const Gap(FwSpacing.xs),
            Text(
              '${note.notImported.length} not imported',
              style: micro.copyWith(color: colors.warningText),
            ),
          ],
          if (note.kept.isNotEmpty) ...[
            const Gap(FwSpacing.xs),
            Text('Kept: ${note.kept.join(', ')}', style: micro),
          ],
        ],
        if (widget.onImport case var import?) ...[
          const Gap(FwSpacing.sm),
          Tappable(
            onTap: import,
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            child: Text(
              note == null ? 'import…' : 'import again…',
              style: context.type.caption.copyWith(color: colors.accent),
            ),
          ),
        ],
      ],
    );
  }

  // --- The sheet -----------------------------------------------------------

  Widget _sheet(BuildContext context) {
    var colours = _of(SceneParamKind.color);
    var numbers = _of(SceneParamKind.number);
    var styles = _styleTokens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.xl,
        FwSpacing.xxl,
      ),
      children: [
        if (library.tokens.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.lg),
            child: Text(
              'No token yet. The + on a section adds one — a colour, a '
              'number or a type style.',
              style: context.type.micro.copyWith(color: context.colors.mut2),
            ),
          ),
        // The palette is judged whole, so the picker opens under the grid
        // rather than inside it: the tiles never move.
        _section(context, _colours, onAdd: () => _add(SceneParamKind.color), [
          if (colours.isEmpty)
            _none(context, 'No colour yet.')
          else
            Wrap(
              spacing: FwSpacing.lg,
              runSpacing: FwSpacing.lg,
              children: [for (var t in colours) _swatch(context, t)],
            ),
          for (var t in colours)
            if (_isOpen(t)) _editor(context, t),
        ]),
        _section(context, _numbers, onAdd: () => _add(SceneParamKind.number), [
          if (numbers.isEmpty) _none(context, 'No number yet.'),
          for (var t in numbers) ...[
            _numberRow(context, t, numbers),
            if (_isOpen(t)) _editor(context, t),
          ],
        ]),
        _section(context, _styles, onAdd: _addStyle, [
          if (styles.isEmpty) _none(context, 'No type style yet.'),
          for (var t in styles) _styleCard(context, t),
        ]),
        if (widget.exports.isNotEmpty)
          _section(context, _exports, [
            for (var t in widget.exports) ...[
              _exportRow(context, t),
              if (_isOpen(t)) _editor(context, t),
            ],
          ]),
      ],
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<Widget> children, {
    VoidCallback? onAdd,
  }) => Padding(
    key: _anchors[title],
    padding: const EdgeInsets.only(bottom: FwSpacing.xxl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: FwSpacing.sm,
          children: [
            Text(
              title.toUpperCase(),
              style: context.type.caption.copyWith(color: context.colors.mut3),
            ),
            if (onAdd != null)
              Tooltip(
                message: 'New ${title.toLowerCase()} token',
                child: Tappable(
                  key: ValueKey('library:add:$title'),
                  onTap: onAdd,
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(FwSpacing.xxs),
                    child: Icon(
                      Icons.add,
                      size: FwIconSize.sm,
                      color: context.colors.mut,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Gap(FwSpacing.md),
        ...children,
      ],
    ),
  );

  /// The token's own editor, opened where it stands: what it is, its value
  /// in the kind's control, who reads it, and the verbs that are not edits.
  Widget _editor(
    BuildContext context,
    SceneTokenDecl t, {
    bool inCard = false,
  }) {
    var colors = context.colors;
    return Container(
      key: ValueKey('library:editor:${t.name}'),
      margin: EdgeInsets.only(top: inCard ? 0 : FwSpacing.md),
      padding: const EdgeInsets.all(FwSpacing.lg),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: inCard
            ? null
            : BorderRadius.circular(context.radii.radius),
        border: inCard
            ? Border(top: BorderSide(color: colors.line))
            : Border.all(color: colors.accent),
      ),
      child: SceneTokenEditor(
        t,
        library: t.isExport ? null : library,
        readers: widget.readersOf?.call(t.name) ?? const [],
        deleteProblem: widget.deleteProblem?.call(t.name),
        // The card above already carries the name; a row that has none
        // shows it here, where it is renamed.
        showName: !inCard,
        renaming: _naming == t.name && !inCard,
        onRenaming: (on) => setState(() => _naming = on ? t.name : null),
        onRename: t.isExport || widget.onRename == null
            ? null
            : (wanted) {
                widget.onRename!(t.name, wanted);
                setState(() {
                  _naming = null;
                  _selected = wanted.trim();
                });
              },
        onDelete: t.isExport || widget.onDelete == null
            ? null
            : () {
                widget.onDelete!(t.name);
                setState(() => _selected = null);
              },
      ),
    );
  }

  // --- Colours -------------------------------------------------------------

  Widget _swatch(BuildContext context, SceneTokenDecl t) {
    var colors = context.colors;
    var open = _isOpen(t);
    var value = t.value! as SceneColor;
    return Tappable(
      key: ValueKey('library:token:${t.name}'),
      onTap: () => _select(t),
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: SizedBox(
        width: 108,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 62,
              decoration: BoxDecoration(
                color: value.flutter,
                borderRadius: BorderRadius.circular(context.radii.radius),
                border: Border.all(
                  color: open ? colors.accent : colors.line,
                  width: open ? 2 : 1,
                ),
              ),
            ),
            const Gap(FwSpacing.xs),
            Text(
              t.name,
              overflow: TextOverflow.ellipsis,
              style: context.type.mono.copyWith(
                color: open ? colors.accent : colors.accentDark,
              ),
            ),
            Text(
              SceneColorField.hexOf(value),
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ],
        ),
      ),
    );
  }

  // --- Numbers -------------------------------------------------------------

  /// The name, the value, and a rule as long as it is — so a spacing ramp
  /// reads as a ramp instead of as five numbers. One number alone has
  /// nothing to be longer than, so it gets no rule.
  Widget _numberRow(
    BuildContext context,
    SceneTokenDecl t,
    List<SceneTokenDecl> all,
  ) {
    var colors = context.colors;
    var open = _isOpen(t);
    var widest = 1.0;
    for (var other in all) {
      var v = (other.value! as double).abs();
      if (v > widest) widest = v;
    }
    return Tappable(
      key: ValueKey('library:token:${t.name}'),
      onTap: () => _select(t),
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.sm),
        child: Row(
          spacing: FwSpacing.lg,
          children: [
            SizedBox(
              width: 140,
              child: Text(
                t.name,
                overflow: TextOverflow.ellipsis,
                style: context.type.mono.copyWith(
                  color: open ? colors.accent : colors.accentDark,
                ),
              ),
            ),
            SizedBox(
              width: 60,
              child: Text(
                tokenValueLabel(t),
                overflow: TextOverflow.ellipsis,
                style: context.type.micro.copyWith(color: colors.mut2),
              ),
            ),
            if (all.length > 1)
              Expanded(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: ((t.value! as double).abs() / widest).clamp(
                    0.02,
                    1.0,
                  ),
                  child: Container(
                    height: 2,
                    color: open ? colors.accent : colors.mut3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- Type styles ---------------------------------------------------------

  /// A style, set in itself, with its fields opening under its own picture.
  /// The whole argument for the page: `54 · w700` says nothing that a
  /// picture of the words does not say better, and the fields belong beside
  /// the picture they change.
  Widget _styleCard(BuildContext context, SceneTokenDecl t) {
    var colors = context.colors;
    var open = _isOpen(t);
    var style = t.style!;
    var dark = _needsDarkGround(style);
    return Container(
      margin: const EdgeInsets.only(bottom: FwSpacing.md),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: open ? colors.accent : colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tappable(
            key: ValueKey('library:token:${t.name}'),
            onTap: () => _select(t),
            child: Container(
              // A style whose colour is nearly the page is invisible on it —
              // `body` at #D8C9BD drew as a blank card. The specimen gets a
              // ground its own colour reads on, which is what a type sheet
              // does and what the scene it is for will do anyway.
              color: dark ? colors.ink : null,
              padding: const EdgeInsets.all(FwSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _specimen(context, style),
                  const Gap(FwSpacing.sm),
                  Row(
                    spacing: FwSpacing.sm,
                    children: [
                      Flexible(
                        child: _naming == t.name && widget.onRename != null
                            ? _nameField(context, t)
                            : Text(
                                t.name,
                                overflow: TextOverflow.ellipsis,
                                style: context.type.mono.copyWith(
                                  color: dark
                                      ? colors.bg
                                      : open
                                      ? colors.accent
                                      : colors.accentDark,
                                ),
                              ),
                      ),
                      Text(
                        tokenValueLabel(t),
                        style: context.type.micro.copyWith(
                          color: dark ? colors.mut3 : colors.mut2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (open) _editor(context, t, inCard: true),
        ],
      ),
    );
  }

  /// Whether the style's colour is too near the page to read on it. The
  /// threshold is where a hairline of it would vanish, not a hard white:
  /// #D8C9BD is not white and is still unreadable.
  static bool _needsDarkGround(SceneTextStyle style) {
    var color = style.color;
    if (color == null) return false;
    return color.flutter.computeLuminance() > 0.55;
  }

  /// The style's own words, drawn by the SCENE's own renderer — the same
  /// [LayeredText] over the same [sceneTextStyleFor] that the canvas uses,
  /// off a throwaway node the style is written onto.
  ///
  /// Hand-rolling a `TextStyle` here was the first version and it was wrong
  /// in a way a specimen must never be: it silently dropped the paint stack
  /// and the word spacing, so a style with an outline previewed without one
  /// and an edit changed nothing you could see. A picture that does not
  /// draw what the scene draws is worse than no picture, and the only way
  /// to be sure of that is to call the same code.
  ///
  /// Sized down so a poster face does not push the sheet around: every
  /// length the style carries is scaled by the same factor, so the specimen
  /// is the style at another size rather than the style with a smaller
  /// font and the wrong everything else.
  Widget _specimen(BuildContext context, SceneTextStyle style) {
    const cap = 44.0;
    var size = style.fontSize ?? 16;
    var scale = size > cap ? cap / size : 1.0;
    var sample = switch (style.textCase) {
      SceneTextCase.upper => 'THE QUICK BROWN FOX',
      SceneTextCase.lower => 'the quick brown fox',
      _ => 'The quick brown fox',
    };
    var node = TextNode(sample, name: 'specimen', style: _scaled(style, scale));
    // No colour of its own means "the app's", which the canvas gets from
    // the guest's theme and this page has to say for itself.
    if (style.color == null) {
      node.color = SceneColor(context.colors.ink.toARGB32());
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: LayeredText(
            span: TextSpan(children: sceneTextRuns(node)),
            style: sceneTextStyleFor(node),
            layers: node.layers,
            textAlign: TextAlign.left,
            maxLines: 1,
          ),
        ),
        if (scale != 1.0)
          Padding(
            padding: const EdgeInsets.only(left: FwSpacing.sm, bottom: 2),
            child: Text(
              'shown at ${(size * scale).round()}',
              style: context.type.micro.copyWith(
                color: _needsDarkGround(style)
                    ? context.colors.mut
                    : context.colors.mut3,
              ),
            ),
          ),
      ],
    );
  }

  /// Every length in [style] multiplied by [scale] — the size, the tracking,
  /// the word spacing, and each paint pass's own widths and offsets. Leading
  /// is a multiple of the size and shadow blur scales with the rest.
  static SceneTextStyle _scaled(SceneTextStyle style, double scale) {
    if (scale == 1.0) return style;
    var values = Map<String, Object?>.of(style.values);
    for (var prop in const [
      'fontSize',
      'letterSpacing',
      'wordSpacing',
      'decorationThickness',
    ]) {
      if (values[prop] case double v) values[prop] = v * scale;
    }
    if (values['layers'] case List layers) {
      values['layers'] = [
        for (var l in layers.cast<TextLayer>()) _scaledLayer(l, scale),
      ];
    }
    return SceneTextStyle.fromValues(values);
  }

  static TextLayer _scaledLayer(TextLayer layer, double scale) {
    var scaled = layer.copyWith(
      dx: layer.dx * scale,
      dy: layer.dy * scale,
      blur: layer.blur * scale,
    );
    return switch (scaled) {
      StrokeLayer s => s.copyWith(width: s.width * scale),
      FillLayer f => f,
    };
  }

  // --- The app's own -------------------------------------------------------

  Widget _exportRow(BuildContext context, SceneTokenDecl t) {
    var colors = context.colors;
    return Tappable(
      key: ValueKey('library:token:${t.name}'),
      onTap: () => _select(t),
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.sm),
        child: Row(
          spacing: FwSpacing.lg,
          children: [
            Icon(
              Icons.ios_share_outlined,
              size: FwIconSize.sm,
              color: colors.mut,
            ),
            SizedBox(
              width: 140,
              child: Text(
                t.name,
                overflow: TextOverflow.ellipsis,
                style: context.type.mono.copyWith(
                  color: _isOpen(t) ? colors.accent : colors.accentDark,
                ),
              ),
            ),
            Text(
              t.type,
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ],
        ),
      ),
    );
  }

  // --- Bits ----------------------------------------------------------------

  /// The field a token is named in right after it is added, so a new one is
  /// named before anything else happens to it.
  Widget _nameField(BuildContext context, SceneTokenDecl t) => InlineNameField(
    initial: t.name,
    dense: true,
    style: context.type.mono,
    onCommit: (wanted) {
      try {
        widget.onRename!(t.name, wanted);
      } on ArgumentError catch (e) {
        return '${e.message}';
      }
      setState(() {
        _naming = null;
        _selected = wanted.trim();
      });
      return null;
    },
    onCancel: () => setState(() => _naming = null),
  );

  Widget _none(BuildContext context, String what) => Text(
    what,
    style: context.type.micro.copyWith(color: context.colors.mut3),
  );
}
