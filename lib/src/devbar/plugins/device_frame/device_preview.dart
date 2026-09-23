import 'package:material_ui/material_ui.dart';

import '../../../../devbar.dart';
import '../../../../devbar_plugins/device_frame.dart';
import '../../../third_party/device_frame/lib/device_frame.dart';
import '../../../ui_catalog/default_device_list.dart';
import '../../../utils/value_stream.dart';

class DevicePreview extends StatelessWidget {
  final Widget child;

  const DevicePreview({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    var plugin = DevbarState.of(context).plugin<DeviceFramePlugin>();

    return ValueStreamBuilder<bool>(
      stream: plugin.showFrame,
      builder: (context, showFrame) {
        if (!showFrame) return child;
        return ValueStreamBuilder<DeviceInfo>(
          stream: plugin.device,
          builder: (context, device) {
            Widget widget = AddDevbarButton(
              button: DevbarDropdown<DeviceInfo?>(
                onChanged: (v) {
                  if (v == null) {
                    plugin.showFrame.value = false;
                  } else {
                    plugin.device.value = v;
                  }
                },
                icon: Icons.phone_android,
                color: Colors.blue,
                values: {
                  for (var device in defaultMobileDevices.entries)
                    device.key: Text(device.value),
                  null: Text('Close frame'),
                },
              ),
              child: Container(
                color: Color(0xffdfdfdf),
                child: Center(
                  child: DeviceFrame(device: device, screen: child),
                ),
              ),
            );

            return widget;
          },
        );
      },
    );
  }
}
