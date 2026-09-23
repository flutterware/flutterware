import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutterware/devbar.dart';
import 'package:flutterware/devbar_plugins/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StoragePlugin extends DevbarPlugin {
  final DevbarState devbar;

  StoragePlugin(this.devbar) {
    devbar.ui.addTab(Tab(text: 'Storage'), StoragePanel());
  }

  @override
  void dispose() {}
}

class StoragePanel extends StatelessWidget {
  const StoragePanel({super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);
    var variablePlugin = devbar.maybePlugin<VariablesPlugin>();

    var tabs = [
      Tab(child: Text('Preferences')),
      Tab(child: Text('Secure')),
      if (variablePlugin != null) Tab(child: Text('Variables')),
    ];
    var tabsContent = [
      _SharedPreferencesList(),
      _SecureStorageList(),
      if (variablePlugin != null) _VariablesStorageList(variablePlugin),
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

class _SharedPreferencesList extends StatefulWidget {
  @override
  __SharedPreferencesListState createState() => __SharedPreferencesListState();
}

class __SharedPreferencesListState extends State<_SharedPreferencesList> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorWidget(snapshot.error!);
        }
        var preferences = snapshot.data;
        if (preferences != null) {
          return ListView(
            children: [
              for (var key in preferences.getKeys())
                ListTile(
                  title: Text(key),
                  subtitle: Text(preferences.get(key).toString()),
                  trailing: IconButton(
                    onPressed: () {
                      setState(() {
                        preferences.remove(key);
                      });
                    },
                    icon: Icon(Icons.delete),
                  ),
                ),
            ],
          );
        } else {
          return Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}

final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

class _SecureStorageList extends StatefulWidget {
  @override
  __SecureStorageListState createState() => __SecureStorageListState();
}

class __SecureStorageListState extends State<_SecureStorageList> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, String>>(
      future: _secureStorage.readAll(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorWidget(snapshot.error!);
        }

        var allValues = snapshot.data;
        if (allValues != null) {
          return ListView(
            children: [
              for (var key in allValues.keys)
                ListTile(
                  title: Text(key),
                  subtitle: Text(allValues[key].toString()),
                  trailing: IconButton(
                    onPressed: () {
                      setState(() {
                        _secureStorage.delete(key: key);
                      });
                    },
                    icon: Icon(Icons.delete),
                  ),
                ),
            ],
          );
        } else {
          return Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}

class _VariablesStorageList extends StatefulWidget {
  final VariablesPlugin variables;

  const _VariablesStorageList(this.variables);

  @override
  __VariablesStorageListState createState() => __VariablesStorageListState();
}

class __VariablesStorageListState extends State<_VariablesStorageList> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DevbarVariable>>(
      stream: widget.variables.variables,
      initialData: widget.variables.currentVariables,
      builder: (context, variables) {
        return ListView(
          children: [
            for (var entry in variables.requireData)
              if (entry.storeValue != null)
                ListTile(
                  title: Text(entry.key),
                  subtitle: Text(entry.currentValue.toString()),
                  trailing: IconButton(
                    onPressed: () {
                      setState(() {
                        entry.storeValue = null;
                      });
                    },
                    icon: Icon(Icons.delete),
                  ),
                ),
          ],
        );
      },
    );
  }
}
