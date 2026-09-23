import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/devbar.dart';
import 'package:os_detect/os_detect.dart' as platform;
import 'package:package_info_plus/package_info_plus.dart';

class InfoPlugin extends DevbarPlugin {
  final DevbarState devbar;

  InfoPlugin(this.devbar) {
    devbar.ui.addTab(Tab(text: 'Info'), InfoPanel());
  }

  @override
  void dispose() {}
}

class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    var isAndroid = platform.isAndroid;
    var tabs = [
      Tab(child: Text('App')),
      Tab(child: Text('Device')),
      if (isAndroid) Tab(child: Text('Android ID')),
    ];
    var tabsContent = [
      _PackageInfoList(),
      _GenericInfoList(),
      if (isAndroid) _AndroidIdPanel(),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: TabBar(tabs: tabs, isScrollable: true),
        body: TabBarView(children: tabsContent),
      ),
    );
  }
}

class _Tab<T> extends StatefulWidget {
  final Future<T> Function() future;
  final Widget Function(BuildContext, T) builder;

  const _Tab({super.key, required this.future, required this.builder});

  @override
  __TabState<T> createState() => __TabState<T>();
}

class __TabState<T> extends State<_Tab<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.future();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorWidget(snapshot.error!);
        }
        var info = snapshot.data;
        if (info != null) {
          return widget.builder(context, info);
        } else {
          return Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}

class _PackageInfoList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _Tab<PackageInfo>(
      future: PackageInfo.fromPlatform,
      builder: (context, info) {
        return ListView(
          children: [
            _row('App name', info.appName),
            _row('Package name', info.packageName),
            _row('Version', info.version),
            _row('Build number', info.buildNumber),
          ],
        );
      },
    );
  }

  Widget _row(String label, String value) {
    return ListTile(title: Text(label), subtitle: Text(value));
  }
}

final _deviceInfoPlugin = DeviceInfoPlugin();

class _GenericInfoList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _Tab<BaseDeviceInfo>(
      future: () => _deviceInfoPlugin.deviceInfo,
      builder: (context, info) {
        return ListView(
          children: [
            for (var entry in info.data.entries)
              _row(entry.key, entry.value.toString()),
          ],
        );
      },
    );
  }

  Widget _row(String label, String? value) {
    return ListTile(title: Text(label), subtitle: Text(value ?? ''));
  }
}

class _AndroidIdPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _Tab<String?>(
      future: () => AndroidId().getId(),
      builder: (context, info) {
        return ListView(
          children: [
            ListTile(title: Text('Android ID'), subtitle: Text(info ?? '')),
          ],
        );
      },
    );
  }
}
