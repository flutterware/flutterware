import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../third_party/device_frame/lib/device_frame.dart';
import 'toolbar.dart';

class DeviceChoice {
  final bool isEnabled;
  final bool useMosaic;
  final SingleDeviceChoice single;
  final MosaicDeviceChoice mosaic;
  final Map<DeviceInfo, String> availableDevices;

  DeviceChoice({
    required this.isEnabled,
    required this.single,
    required this.mosaic,
    required this.useMosaic,
    required this.availableDevices,
  });

  DeviceChoice copyWith({
    bool? isEnabled,
    SingleDeviceChoice? single,
    MosaicDeviceChoice? mosaic,
    bool? useMosaic,
  }) {
    return DeviceChoice(
      isEnabled: isEnabled ?? this.isEnabled,
      single: single ?? this.single,
      mosaic: mosaic ?? this.mosaic,
      useMosaic: useMosaic ?? this.useMosaic,
      availableDevices: availableDevices,
    );
  }
}

class SingleDeviceChoice {
  final DeviceInfo device;
  final Orientation orientation;
  final bool showFrame;

  SingleDeviceChoice({
    required this.device,
    required this.orientation,
    required this.showFrame,
  });

  SingleDeviceChoice copyWith({
    bool? showFrame,
    DeviceInfo? device,
    Orientation? orientation,
  }) {
    return SingleDeviceChoice(
      device: device ?? this.device,
      orientation: orientation ?? this.orientation,
      showFrame: showFrame ?? this.showFrame,
    );
  }
}

class MosaicDeviceChoice {
  final Set<DeviceInfo> devices;
  final Set<Orientation> orientations;

  MosaicDeviceChoice({required this.devices, required this.orientations});

  MosaicDeviceChoice copyWith({
    Set<DeviceInfo>? devices,
    Set<Orientation>? orientations,
  }) {
    return MosaicDeviceChoice(
      devices: devices ?? this.devices,
      orientations: orientations ?? this.orientations,
    );
  }
}

class DeviceChoicePanel extends StatefulWidget {
  final DeviceChoice choice;
  final void Function(DeviceChoice) onChanged;

  const DeviceChoicePanel({
    super.key,
    required this.choice,
    required this.onChanged,
  });

  @override
  State<DeviceChoicePanel> createState() => _DeviceChoicePanelState();
}

class _DeviceChoicePanelState extends State<DeviceChoicePanel>
    with TickerProviderStateMixin {
  late final _tabController = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.choice.useMosaic ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();

    _tabController.addListener(() {
      setState(() {
        widget.onChanged(
          widget.choice.copyWith(useMosaic: _tabController.index == 1),
        );
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 500,
      width: 350,
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Scaffold(
        appBar: AppBar(
          title: TabBar(
            controller: _tabController,
            tabs: [
              Tab(icon: Icon(Icons.phone_android)),
              Tab(icon: Icon(Icons.grid_view)),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            RadioGroup<DeviceInfo>(
              groupValue: widget.choice.single.device,
              onChanged: (device) {
                widget.onChanged(
                  widget.choice.copyWith(
                    single: widget.choice.single.copyWith(device: device),
                  ),
                );
              },
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: SegmentedButton<Orientation>(
                      segments: [
                        ButtonSegment(
                          value: Orientation.portrait,
                          label: Text('Portrait'),
                        ),
                        ButtonSegment(
                          value: Orientation.landscape,
                          label: Text('Landscape'),
                        ),
                      ],
                      selected: {widget.choice.single.orientation},
                      onSelectionChanged: (v) {
                        widget.onChanged(
                          widget.choice.copyWith(
                            single: widget.choice.single.copyWith(
                              orientation: v.first,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Divider(),
                  for (var device in widget.choice.availableDevices.entries)
                    _DeviceTile(
                      leading: Radio<DeviceInfo>(value: device.key),
                      title: device.value,
                      device: device.key,
                      onTap: () {
                        widget.onChanged(
                          widget.choice.copyWith(
                            single: widget.choice.single.copyWith(
                              device: device.key,
                            ),
                          ),
                        );
                        ToolbarPanel.of(context).hideMenu();
                      },
                    ),
                ],
              ),
            ),
            ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SegmentedButton<Orientation>(
                    multiSelectionEnabled: true,
                    segments: [
                      ButtonSegment(
                        value: Orientation.portrait,
                        label: Icon(Icons.phone_android),
                      ),
                      ButtonSegment(
                        value: Orientation.landscape,
                        label: Transform.rotate(
                          angle: pi / 2,
                          child: Icon(Icons.phone_android),
                        ),
                      ),
                    ],
                    selected: widget.choice.mosaic.orientations,
                    onSelectionChanged: (v) {
                      widget.onChanged(
                        widget.choice.copyWith(
                          mosaic: widget.choice.mosaic.copyWith(
                            orientations: v,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Divider(),
                ListTile(
                  title: Text('All'),
                  leading: Checkbox(
                    value:
                        widget.choice.mosaic.devices.length ==
                            widget.choice.availableDevices.length
                        ? true
                        : widget.choice.mosaic.devices.isEmpty
                        ? false
                        : null,
                    tristate: true,
                    onChanged: (v) {
                      Set<DeviceInfo> newDevices;
                      if (widget.choice.mosaic.devices.isNotEmpty) {
                        newDevices = {};
                      } else {
                        newDevices = widget.choice.availableDevices.keys
                            .toSet();
                      }
                      widget.onChanged(
                        widget.choice.copyWith(
                          mosaic: widget.choice.mosaic.copyWith(
                            devices: newDevices,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                for (var device in widget.choice.availableDevices.entries)
                  _DeviceTile(
                    title: device.value,
                    device: device.key,
                    leading: Checkbox(
                      value: widget.choice.mosaic.devices.contains(device.key),
                      onChanged: (v) {
                        var newList = widget.choice.mosaic.devices.toSet();
                        if (v!) {
                          newList.add(device.key);
                        } else {
                          newList.remove(device.key);
                        }
                        widget.onChanged(
                          widget.choice.copyWith(
                            mosaic: widget.choice.mosaic.copyWith(
                              devices: newList,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}

class _DeviceTile extends StatelessWidget {
  final String title;
  final DeviceInfo device;
  final Widget? leading;
  final void Function()? onTap;

  const _DeviceTile({
    required this.device,
    this.leading,
    required this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      dense: true,
      leading: leading,
      title: Text(title),
      subtitle: Text(
        '(${device.screenSize.width.round()}x${device.screenSize.height.round()}, ${device.pixelRatio}x)',
      ),
      trailing: Icon(
        device.identifier.platform == TargetPlatform.iOS
            ? Icons.apple
            : Icons.android,
      ),
    );
  }
}
