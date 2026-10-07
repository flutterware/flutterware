import 'package:flutter/foundation.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/worktree_session.dart';
import '../shell/shell_controller.dart';

/// What the page's tab says: the place the address names, in the words the
/// window uses for it.
///
/// `Order placed · Previews · flutterware`. The thing is named by the row of
/// the plugin's own report whose address is the longest prefix of this one —
/// the same rows search offers — so a step of a scenario reads as its scenario
/// and no plugin has to know a title is being asked for. Before the report has
/// that row it is the plugin alone, and the title catches up when it lands.
String pageTitle(ShellController shell, {String site = 'flutterware'}) {
  var address = shell.address;
  var place = switch (address.plugin) {
    _ when shell.isExplorer => ['Worktrees'],
    null => const <String>[],
    Address.shellConfig => ['Config'],
    Address.shellChanges => ['Changes'],
    Address.shellAbout => ['About'],
    var plugin => _pluginPlace(shell.selectedSession, plugin, address),
  };
  return [...place, site].join(' · ');
}

List<String> _pluginPlace(
  WorktreeSession? session,
  String plugin,
  Address address,
) {
  var report = session?.reports.where((r) => r.id == plugin).firstOrNull;
  if (report == null) return const [];
  var item = _deepestRow(report.view.nodes, plugin, address.segments);
  return [?item, report.label];
}

String? _deepestRow(
  List<ViewNode> nodes,
  String plugin,
  List<String> segments,
) {
  String? best;
  var depth = 0;
  void walk(List<ViewNode> nodes) {
    for (var node in nodes) {
      switch (node) {
        case ViewSection section:
          walk(section.children);
        case ViewItems items:
          for (var item in items.items) {
            var at = item.address;
            if (at == null || at.plugin != plugin) continue;
            var length = at.segments.length;
            if (length <= depth || length > segments.length) continue;
            if (!listEquals(at.segments, segments.sublist(0, length))) continue;
            best = item.label;
            depth = length;
          }
        case ViewText() || ViewField() || ViewTable():
          break;
      }
    }
  }

  walk(nodes);
  return best;
}

/// Writes [pageTitle] through [write] whenever it would read differently:
/// the address moved, a worktree opened, or the plugin on screen reported the
/// row that names where the address is.
///
/// Returns what stops it.
VoidCallback followPageTitle(
  ShellController shell,
  void Function(String title) write,
) {
  String? written;
  WorktreeSession? session;

  void update() {
    var title = pageTitle(shell);
    if (title == written) return;
    written = title;
    write(title);
  }

  void resubscribe() {
    var next = shell.selectedSession;
    if (!identical(next, session)) {
      session?.removeListener(update);
      session = next?..addListener(update);
    }
    update();
  }

  shell.addListener(resubscribe);
  shell.addressListenable.addListener(resubscribe);
  resubscribe();
  return () {
    shell.removeListener(resubscribe);
    shell.addressListenable.removeListener(resubscribe);
    session?.removeListener(update);
  };
}
