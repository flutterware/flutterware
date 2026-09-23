import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

/// One line of a multi-line block, so that a selection crossing it pastes back
/// as a line.
///
/// Two things are wrong with the obvious ways to make a list of lines
/// selectable, and this fixes both.
///
/// A [SelectableText] per line cannot be crossed at all: each one is its own
/// selection scope, so a drag stops at the line it started in. That is what the
/// run cockpit's log tab had, and "I can't select more than one line" is what it
/// looks like from outside.
///
/// One [SelectionArea] over the list crosses lines and then loses them.
/// Measured: four rows of `Text` selected and copied come back as
/// `line-2line-3line-4line-5`, run together, because nothing puts a separator
/// between two sibling [Text]s. A log you cannot paste is not much better than
/// a log you cannot select. The obvious repair — one joining
/// [SelectionContainer] over the whole list — does not work either: a
/// [Scrollable] under a [SelectionArea] installs a container of its own, so the
/// outer one is handed a single already-flattened child. The join has to happen
/// per line, which is what this is.
///
/// The terminator is conditional, and the condition is the one a terminal uses:
/// a line ends with a newline when the selection *reached its end*. Pick four
/// lines and you get four lines. Pick a path out of the middle of one and you
/// get the path — not the path and a line break, which would run as a command
/// the moment it was pasted into a shell.
///
/// A line with no text at all does not survive, and cannot be made to from
/// here: an empty [Text] reports no content, so the enclosing region skips the
/// container without ever asking it, and there is nothing to tell a blank line
/// inside the selection from a line outside it. Copying a stretch of a diff
/// therefore closes up its blank lines.
///
/// Wrapping is unaffected, which is the point of doing this per line rather
/// than per visual row: a line 208 characters long that wraps to eleven rows on
/// screen is still one [Text], so it copies as one line with no breaks
/// introduced at the wrap points. A line carrying its own newlines — a message
/// with a stack trace under it — keeps them.
class FwSelectableLine extends StatefulWidget {
  const FwSelectableLine({super.key, required this.child});

  /// The line. Usually a [Text], possibly inside a [Row] with a gutter — put
  /// anything the reader should not get in the clipboard, such as a line
  /// number, in a [SelectionContainer.disabled].
  final Widget child;

  @override
  State<FwSelectableLine> createState() => _FwSelectableLineState();
}

class _FwSelectableLineState extends State<FwSelectableLine> {
  /// Owned rather than built in `build`: a delegate is a [ChangeNotifier] the
  /// selection machinery registers with, and a fresh one per rebuild would
  /// drop the selection every time the list repaints.
  final _delegate = _LineDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

class _LineDelegate extends MultiSelectableSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    var parts = <String>[];
    var taken = false;
    var reachedEnd = false;
    for (var selectable in selectables) {
      if (selectable.getSelectedContent() case var content?) {
        parts.add(content.plainText);
      }
      if (selectable.getSelection() case var range?) {
        // The offsets are not ordered — a drag upwards reports the end first.
        var from = math.min(range.startOffset, range.endOffset);
        var to = math.max(range.startOffset, range.endOffset);
        // Whether this line is *in* the selection, which is not the same as
        // being touched by it. A drag that begins on the top edge of one line
        // rests its start on the end of the line above, and that line then
        // reports a range — empty, but at the very end of its text. Counting
        // that as taken handed it back as nothing plus a terminator, which put
        // a blank first line in front of everything anybody pasted.
        if (to > from) taken = true;
        // Where the terminator is decided. A row the selection passes through
        // is taken to its end and gets one; the row it stops in is not and
        // does not.
        if (to >= selectable.contentLength) reachedEnd = true;
      }
    }
    if (!taken) return null;
    return SelectedContent(
      plainText: '${parts.join()}${reachedEnd ? '\n' : ''}',
    );
  }

  /// Nothing to bring up to date. The base class calls this for a child that
  /// registers while a selection is already live, so that a list materialising
  /// rows mid-drag can catch them up. A line holds its child for its whole
  /// life, so there is never a late arrival to catch up here — the rows
  /// themselves arrive at the *scrollable's* delegate, not at this one.
  @override
  void ensureChildUpdated(Selectable selectable) {}
}
