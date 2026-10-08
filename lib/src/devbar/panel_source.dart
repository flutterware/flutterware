/// How a devbar plugin says it can be rendered from outside the app.
///
/// Implementing this is what puts a plugin in descriptor mode — there is no
/// enum and no flag. A plugin that implements it is mirrored to the cockpit,
/// `fw` and MCP, and (later) drawn in the overlay from the same declaration. A
/// plugin that does not implement it is widget mode: it draws its own tab with
/// its own widgets and is invisible to everything outside the app, which is
/// the escape hatch for anything the vocabulary cannot express.
library;

import '../channels/panels.dart';

abstract class DevbarPanelSource {
  /// Stable, and unique among the plugins of one devbar. Two devbars mounted at
  /// once do not have to coordinate: the bridge disambiguates.
  String get panelId;

  String get panelLabel;

  /// Declares feeds, states, knobs and actions onto [panel], each with the code
  /// that serves it.
  ///
  /// Called once per mount. The plugin keeps [panel] if it has anything to emit
  /// or announce later.
  void describePanel(Panel panel);
}
