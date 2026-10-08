/// A [PanelDescriptor] drawn — the widgets the cockpit and the in-app overlay
/// both use.
///
/// Split from `package:flutterware/channels.dart` rather than exported beside
/// it: the vocabulary is for anything that talks to a panel, and most of that
/// is not a Flutter program. `fw` and the MCP server are pure Dart, and a
/// single library would have made importing `PanelDescriptor` enough to pull
/// `material.dart` into both.
///
/// Everything here is a **View**: it takes the descriptor, the events and the
/// snapshots as plain data and hands every interaction back as a callback. It
/// holds no channel and fetches nothing, which is what lets one widget serve a
/// cockpit attached over a VM service and an overlay inside the app itself.
library;

export 'src/channels/ui/controls_view.dart'
    show ActionControl, ControlsView, KnobControl;
export 'src/channels/ui/feed_view.dart'
    show FeedView, formatBytes, formatDuration, formatFieldValue;
export 'src/channels/ui/panel_view.dart' show PanelView, StateView;
export 'src/channels/ui/style.dart' show PanelGap, PanelStyle, PanelSurface;
