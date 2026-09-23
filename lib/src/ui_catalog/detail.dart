import 'package:material_ui/material_ui.dart';

import '../third_party/device_frame/lib/device_frame.dart';
import 'app.dart';
import 'device_choice_panel.dart';
import 'figma/view.dart';
import 'axes_controls.dart';
import 'knobs.dart';
import 'knobs_editor.dart';
import 'toolbar.dart';
import 'ui_catalog.dart';

class DetailView extends StatefulWidget {
  final TreeEntry entry;
  final dynamic value;
  final void Function(TreeEntry) onSelect;
  final UICatalogAppState appState;

  const DetailView(
    this.entry,
    this.value, {
    super.key,
    required this.onSelect,
    required this.appState,
  });

  @override
  State<DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<DetailView> {
  final _deviceFrameKey = GlobalKey<__SingleDeviceWrapperState>();
  Key _appKey = UniqueKey();
  final _knobsPanelKey = GlobalKey();

  late final EditableKnobs knobs = EditableKnobs(
    onRefresh: _onRefreshKnob,
    onAdded: _onAddedKnob,
  );

  void _onRefreshKnob() {
    setState(() {
      _appKey = UniqueKey();
    });
  }

  void _onAddedKnob() {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    var book = UICatalog.of(context);
    var value = widget.value;
    var device = widget.appState.deviceForEntry(widget.entry);

    Widget mainWidget;
    if (value is Widget) {
      var result = Builder(
        builder: (context) {
          return book.appBuilder(
            context,
            Material(
              child: Center(key: _appKey, child: value),
            ),
          );
        },
      );

      if (device.isEnabled) {
        if (device.useMosaic) {
          mainWidget = _Mosaic(mosaic: device.mosaic, child: result);
        } else {
          mainWidget = DeviceFrame(
            device: device.single.device,
            isFrameVisible: device.single.showFrame,
            orientation: device.single.orientation,
            screen: _SingleDeviceWrapper(key: _deviceFrameKey, child: result),
          );
        }
      } else {
        mainWidget = result;
      }
    } else {
      mainWidget = Center(
        child: Text('Entry is not a widget. Type: ${value.runtimeType}'),
      );
    }

    mainWidget = KnobsProvider(knobs: knobs, child: mainWidget);

    var breadcrumbHeight = 40.0;
    var breadcrumb = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: SizedBox(
        height: breadcrumbHeight,
        child: Breadcrumb(widget.entry, onSelect: widget.onSelect),
      ),
    );
    var toolbar = Toolbar(
      children: [
        // First, because an axis outranks a device: it is the app-wide switch
        // the shell declared, and on a page whose reason for existing is
        // "look at every screen in Dutch" it is the control people came for.
        const AxesControls(),
        ToolbarPanel(
          button: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Device'),
              Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: device.isEnabled,
                  onChanged: (v) {
                    setState(() {
                      widget.appState.setDeviceForEntry(
                        widget.entry,
                        device.copyWith(isEnabled: v),
                      );
                    });
                  },
                ),
              ),
            ],
          ),
          panel: DeviceChoicePanel(
            choice: device,
            onChanged: (v) {
              setState(() {
                widget.appState.setDeviceForEntry(widget.entry, v);
              });
            },
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        breadcrumb,
        toolbar,
        Expanded(
          child: FigmaView(
            entry: widget.entry,
            floatDefaultWidth: () {
              // TODO(xha): try to use _deviceFrameKey.currentState to get the
              // actual size of the element inside the phone frame
              return 300;
            },
            child: mainWidget,
          ),
        ),
        if (knobs.knobs.isNotEmpty) ...[
          Divider(),
          SizedBox(height: 200, child: KnobsEditor(knobs, key: _knobsPanelKey)),
        ],
      ],
    );
  }
}

class Breadcrumb extends StatelessWidget {
  final TreeEntry entry;
  final void Function(TreeEntry) onSelect;

  const Breadcrumb(this.entry, {super.key, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var e in entry.breadcrumb) ...[
          InkWell(
            onTap: e == entry ? null : () => onSelect(e),
            child: Text(e.title),
          ),
          if (e != entry.breadcrumb.last) Icon(Icons.arrow_right),
        ],
      ],
    );
  }
}

class _Mosaic extends StatelessWidget {
  final Widget child;
  final MosaicDeviceChoice mosaic;

  const _Mosaic({required this.child, required this.mosaic});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: ExcludeFocus(
        child: IgnorePointer(
          child: Wrap(
            children: [
              for (var orientation in mosaic.orientations)
                for (var device in mosaic.devices)
                  SizedBox(
                    width: 200,
                    child: DeviceFrame(
                      orientation: orientation,
                      device: device,
                      screen: child,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SingleDeviceWrapper extends StatefulWidget {
  final Widget child;
  const _SingleDeviceWrapper({super.key, required this.child});

  @override
  State<_SingleDeviceWrapper> createState() => __SingleDeviceWrapperState();
}

class __SingleDeviceWrapperState extends State<_SingleDeviceWrapper> {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
