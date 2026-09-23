import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../devbar.dart';
import '../../../third_party/device_frame/lib/device_frame.dart';
import '../../../utils/value_stream.dart';
import 'device_preview.dart';

/// A plugin for the Devbar which allow to preview the app on different screen sizes.
class DeviceFramePlugin extends DevbarPlugin {
  final DevbarState devbar;
  final showFrame = ValueStream<bool>(false);
  final device = ValueStream<DeviceInfo>(Devices.ios.iPhoneSE);

  DeviceFramePlugin._(this.devbar) {
    devbar.ui.addTab(Tab(text: 'Simulator'), _DeviceFramePanel(this));

    devbar.ui.addWrapper(DevicePreview.new);
  }

  static DeviceFramePlugin Function(DevbarState) init() {
    return (devbar) => DeviceFramePlugin._(devbar);
  }

  @override
  void dispose() {
    showFrame.dispose();
    device.dispose();
  }
}

class _DeviceFramePanel extends StatefulWidget {
  final DeviceFramePlugin plugin;

  const _DeviceFramePanel(this.plugin);

  @override
  State<_DeviceFramePanel> createState() => _DeviceFramePanelState();
}

class _DeviceFramePanelState extends State<_DeviceFramePanel> {
  @override
  Widget build(BuildContext context) {
    return ListView(children: [_devicePreview(), _targetPlatform()]);
  }

  Widget _devicePreview() {
    return ValueStreamBuilder<bool>(
      stream: widget.plugin.showFrame,
      builder: (context, showFrame) {
        return ListTile(
          title: Text('Enable frame'),
          subtitle: Text(
            'Approximate how the app looks and performs on another device.',
          ),
          trailing: Switch.adaptive(
            value: showFrame,
            onChanged: (enabled) {
              setState(() {
                widget.plugin.showFrame.value = enabled;
              });
            },
          ),
        );
      },
    );
  }

  Widget _targetPlatform() {
    return ListTile(
      dense: true,
      title: Text('Target platform'),
      trailing: FractionallySizedBox(
        widthFactor: 0.5,
        child: DropdownButton<TargetPlatform>(
          isDense: true,
          value: debugDefaultTargetPlatformOverride,
          onChanged: (value) {
            setState(() {
              debugDefaultTargetPlatformOverride = value;
            });
          },
          isExpanded: true,
          items: [
            DropdownMenuItem(value: null, child: Text('Default')),
            for (var os in TargetPlatform.values)
              DropdownMenuItem(value: os, child: Text(os.name)),
          ],
        ),
      ),
    );
  }
}
