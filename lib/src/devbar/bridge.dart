/// What connects a mounted [Devbar] to the channels a host reads.
///
/// The devbar is the *plugin host* — where plugins are constructed, because
/// that is where the app author writes them. This is the other half: when
/// flutterware is watching, every descriptor-mode
/// plugin of every mounted devbar becomes a panel, and stops being one when the
/// devbar unmounts.
///
/// Nothing here runs outside flutterware. Mirroring is gated on
/// [GuestChannels.installed], so an app carrying a devbar for its own sake —
/// a tester's build, a phone in someone's hand — pays nothing and keeps the
/// overlay as its only surface.
library;

import '../server/vm_transport.dart';
import 'add_panel.dart';
import 'devbar.dart';
import 'panel_source.dart';

class DevbarBridge {
  DevbarBridge._();

  /// Which panel ids each mounted devbar claimed, so unmounting gives back
  /// exactly those.
  static final _mounted = <DevbarState, List<String>>{};

  /// Whether a mount would do anything. False outside flutterware.
  static bool get active => GuestChannels.installed;

  /// Publishes [devbar]'s descriptor-mode plugins as panels.
  ///
  /// Called after the plugins have loaded, not in `initState`: a plugin that
  /// has not finished constructing has nothing to describe.
  static void mount(DevbarState devbar, List<DevbarPlugin> plugins) {
    if (!active || _mounted.containsKey(devbar)) return;
    var claimed = <String>[];
    for (var plugin in plugins) {
      if (plugin case DevbarPanelSource source) {
        var id = add(source);
        if (id != null) claimed.add(id);
      }
    }
    _mounted[devbar] = claimed;
  }

  static void unmount(DevbarState devbar) {
    for (var id in _mounted.remove(devbar) ?? const <String>[]) {
      remove(id);
    }
  }

  /// Starts serving [source], and answers with **the id it actually got** —
  /// which is not always [DevbarPanelSource.panelId], because [_freeId] steps
  /// aside for a panel already using that name.
  ///
  /// Null when nothing is watching, which is all a caller has to handle: hold
  /// the answer, hand it back to [remove], and an app running outside
  /// flutterware has quietly done nothing.
  ///
  /// The other door into this is [mount], for the panels a devbar's own
  /// plugins declare. This one is for [AddDevbarPanel] — a panel that belongs
  /// to a subtree rather than to the devbar, and so comes and goes with it.
  static String? add(DevbarPanelSource source) {
    if (!active) return null;
    var id = _freeId(source.panelId);
    source.describePanel(GuestChannels.panels.add(id, source.panelLabel));
    return id;
  }

  /// Stops serving the panel [add] claimed. Null is the no-op that lets a
  /// caller hold the answer without checking it.
  static void remove(String? id) {
    if (id != null) GuestChannels.panels.remove(id);
  }

  /// `network`, then `network#2`, then `network#3`.
  ///
  /// The common case — one devbar — reads clean, and the multi-devbar case
  /// (`fixtures/probe_app/lib/multi_devbar_variables.dart` is one) cannot have
  /// the second instance silently replace the first's panel. A suffix rather
  /// than an index prefix, so the id an agent sees in the ordinary app is the
  /// id the plugin declared.
  static String _freeId(String wanted) {
    if (GuestChannels.panels[wanted] == null) return wanted;
    for (var n = 2; ; n++) {
      var candidate = '$wanted#$n';
      if (GuestChannels.panels[candidate] == null) return candidate;
    }
  }
}
