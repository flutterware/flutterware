import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import 'menu.dart';

/// A [Menu] opened at a point — what a right-click gets.
///
/// The same rows as every other menu in the app, anchored to a one-pixel
/// widget dropped into the overlay where the pointer was, so positioning,
/// dismissal and focus are the popover's as usual. Resolves when it closes.
Future<void> showContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<MenuEntry> entries,
) {
  var overlay = Overlay.of(context, rootOverlay: true);
  var done = Completer<void>();
  var removed = false;
  var opened = false;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: globalPosition.dx,
      top: globalPosition.dy,
      child: Menu(
        entries: entries,
        builder: (context, controller) {
          // Once, not per build: opening rebuilds the anchor, and a second
          // open() on an open RawMenuAnchor closes it first — which fired
          // onClose, which removed the entry, and the menu showed for one
          // frame.
          if (!opened) {
            opened = true;
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (entry.mounted) controller.open();
            });
          }
          return const SizedBox(width: 1, height: 1);
        },
        onClose: () {
          // Fires on dismissal and again on dispose; the entry goes once.
          if (!removed) {
            removed = true;
            entry.remove();
          }
          if (!done.isCompleted) done.complete();
        },
      ),
    ),
  );
  overlay.insert(entry);
  return done.future;
}
