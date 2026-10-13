import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
// ignore: implementation_imports
import 'package:flutterware/src/device_frames.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'app_theme.dart';

/// Every phone and tablet the device table offers, in the body it is drawn in.
///
/// What this is for. A body is artwork from `device_frame` and the glass inside
/// it is laid out with the table's own safe areas, so the question nobody can
/// answer from the code is whether the two still agree: whether the status bar
/// band ends where the artwork's camera does, whether a 62-point top leaves
/// the island inside the band. Each screen paints its safe areas darker and
/// says its size, so a disagreement is a band that misses the cutout.

@Preview(
  name: 'Device frames · phones',
  group: 'Devices',
  wrapper: wrapInAppTheme,
)
Widget deviceFramesPhones() => _Sheet([
  for (var device in Devices.all)
    if (device.kind == DeviceKind.phone) device,
]);

@Preview(
  name: 'Device frames · tablets',
  group: 'Devices',
  wrapper: wrapInAppTheme,
)
Widget deviceFramesTablets() => _Sheet([
  for (var device in Devices.all)
    if (device.kind == DeviceKind.tablet) device,
]);

class _Sheet extends StatelessWidget {
  const _Sheet(this.devices);

  final List<Device> devices;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var device in devices)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: DeviceFrame(
                        device: deviceFrameFor(device)!,
                        screen: _Glass(device),
                      ),
                    ),
                    const SizedBox(height: FwSpacing.sm),
                    Text(
                      device.label,
                      textAlign: TextAlign.center,
                      style: context.type.body,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The screen, with what the table says is not drawable shaded.
class _Glass extends StatelessWidget {
  const _Glass(this.device);

  final Device device;

  @override
  Widget build(BuildContext context) {
    var padding = MediaQuery.paddingOf(context);
    var band = context.colors.accent.withValues(alpha: 0.6);
    return ColoredBox(
      color: context.colors.accentSoft,
      child: Column(
        children: [
          Container(height: padding.top, color: band),
          Expanded(
            child: Center(
              child: Text(
                '${describeDevice(device)}\n'
                'top ${padding.top.toStringAsFixed(0)} · '
                'bottom ${padding.bottom.toStringAsFixed(0)}',
                textAlign: TextAlign.center,
                style: context.type.heading,
              ),
            ),
          ),
          Container(height: padding.bottom, color: band),
        ],
      ),
    );
  }
}
