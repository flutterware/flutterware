/// What a panel inside a running app declares, and how it serves it.
///
/// Two halves of one vocabulary. The **descriptors** ([PanelDescriptor] and
/// friends) are pure data — a cockpit, `fw` and MCP all render from them, and
/// so does the in-app overlay, which is what stops the two surfaces drifting.
/// The **serving** side ([Panels], [Panel]) turns a declaration into channels
/// and handlers on the app's [InspectorCore], reached over the VM service.
///
/// Commands are `PluginAction` from `package:flutterware/plugins.dart` and
/// knobs are `KnobDescriptor` from the catalog's vocabulary — reused, not
/// re-invented, so an agent that has learned one flutterware surface has
/// learned this one.
///
/// No Flutter in here. The renderers live next door in
/// `package:flutterware/channels_ui.dart`, because everything that only wants
/// to *talk* to a panel is not a Flutter program: `fw` and the MCP server are
/// pure Dart entry points, and a library that pulled `material.dart` in behind
/// a `PanelDescriptor` would make them ones. A test pins that
/// (`app/test/utils/entry_point_purity_test.dart`), and it is what caught the
/// original single library.
library;

export 'src/channels/descriptor.dart'
    show
        FeedDescriptor,
        FieldDescriptor,
        FieldKind,
        PanelDescriptor,
        StateDescriptor,
        panelFeedChannel;
export 'src/channels/panels.dart'
    show
        KnobReader,
        KnobWriter,
        Panel,
        PanelActionHandler,
        PanelStateReader,
        Panels,
        panelKnobsMethod,
        panelSetKnobMethod,
        panelStateMethod,
        panelsChannel,
        panelsList;
export 'src/plugins/action.dart'
    show ActionOption, ActionParameter, ActionParameterKind, PluginAction;
export 'src/server/attach_session.dart' show InspectorEvent;
export 'src/server/inspector_core.dart'
    show InspectorCommandHandler, InspectorCore, InspectorPeer;
export 'src/server/vm_transport.dart'
    show GuestChannels, VmServiceTransport, channelExtension, channelNudgeKind;
export 'src/ui_catalog/knob.dart' show KnobDescriptor, KnobKind;
