import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'design/design.dart';
import 'syntax.dart';
import 'tappable.dart';
import 'theme.dart';

/// A block of machine text on the panel's own recessed surface: highlighted if
/// it is a language we colour, copiable, and scrolled rather than wrapped.
///
/// Four call sites drew this by hand before it existed — the server panel's
/// `_Slab` (whose own comment already opened *"Three call sites drew this by
/// hand"*), the scenarios help page's `_CodeBlock` and `_CommandLine`, and the
/// server panel's no-info hint. Between them they disagreed about the surface
/// (`panel` or `panel2`), the radius, whether long lines wrapped, and whether
/// the text could be taken anywhere. This is the one answer.
///
/// **Scrolled, never wrapped.** A wrapped line of code reads as a syntax
/// error, and a wrapped `select … where … order by …` reads as three
/// statements. The scrollbar is the safety net for the long line, not the
/// normal case.
///
/// **[SelectableText], always.** The one thing everybody does with a query or
/// a command is take it somewhere else. [copy] adds the one-click version of
/// the same thing for when the whole block is what is wanted.
class FwCodeBlock extends StatelessWidget {
  const FwCodeBlock(
    this.source, {
    super.key,
    this.language,
    this.copy = true,
    this.wrap = false,
    this.maxHeight,
    this.padding = const EdgeInsets.all(FwSpacing.lg),
  });

  final String source;

  /// A key of `syntax.dart`'s table — `'sql'`, `'dart'`, `'bash'`. Null draws
  /// the text plain, which is what an unknown language does anyway.
  final String? language;

  /// A quiet copy button in the top-right corner.
  final bool copy;

  /// Wrap long lines instead of scrolling them.
  ///
  /// Off by default, because the block's usual subject is *code*: a wrapped
  /// `select … where … order by …` reads as three statements. On for text
  /// that is not code and has no line breaks of its own — an HTTP body is
  /// often one line as wide as it is long, and a horizontal scrollbar the
  /// width of the whole payload is not a way to read it.
  final bool wrap;

  /// Above this the block scrolls vertically as well. Null lets it be as tall
  /// as it is, for a caller that is already inside a list.
  final double? maxHeight;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var text = SelectableText.rich(
      TextSpan(
        children: language == null
            ? [TextSpan(text: source)]
            : codeSpans(context, source, language: language!),
      ),
      style: context.type.mono,
    );

    var body = wrap
        ? Padding(padding: padding, child: text)
        : Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: padding,
              child: text,
            ),
          );
    if (maxHeight case var it?) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: it),
        child: SingleChildScrollView(child: body),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      // The button gets a gutter rather than floating over the text. Floated,
      // it sat on top of the last word of every line long enough to need
      // scrolling — which is every line anybody reaches for the button on.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          if (copy)
            Padding(
              padding: const EdgeInsets.only(
                top: FwSpacing.xs,
                right: FwSpacing.xs,
              ),
              child: CopyIconButton(source),
            ),
        ],
      ),
    );
  }
}

/// Copy [text], and say so for a moment afterwards.
///
/// The tick matters more than it looks: a clipboard write has no effect
/// anybody can see, so a copy button that does not answer is a button people
/// press twice and still do not trust.
class CopyIconButton extends StatefulWidget {
  const CopyIconButton(this.text, {super.key, this.tooltip = 'Copy'});

  final String text;
  final String tooltip;

  @override
  State<CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<CopyIconButton> {
  var _done = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _done = false);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: _done ? 'Copied' : widget.tooltip,
      child: Tappable.builder(
        onTap: _copy,
        borderRadius: BorderRadius.circular(context.radii.micro),
        builder: (context, hovered) => Padding(
          padding: const EdgeInsets.all(FwSpacing.xs),
          child: Icon(
            _done ? Icons.check : Icons.copy,
            size: FwIconSize.sm,
            color: _done
                ? colors.grn
                : hovered
                ? colors.accent
                : colors.mut3,
          ),
        ),
      ),
    );
  }
}
