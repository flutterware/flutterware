import 'dart:async';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/app_events.dart';
import 'package:flutterware/devbar.dart';
import 'package:flutterware/devbar_plugins/device_frame.dart';
import 'package:flutterware/devbar_plugins/log_analytics.dart';
import 'package:flutterware/devbar_plugins/log_network.dart';
import 'package:flutterware/devbar_plugins/log_queries.dart';
import 'package:flutterware/devbar_plugins/logger.dart';
import 'package:flutterware/devbar_plugins/variables.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/database/app_database.dart';
import 'src/devbar/info_panel.dart';
import 'src/devbar/storage_panel.dart';

final _logger = Logger('devbar_example');

final superCoolFeature = FeatureFlag('superCoolFeature', false);
final otherFeature = FeatureFlag('otherFeature', false);
final numFeature = FeatureFlag.slider(
  'numFeature',
  0,
  min: 0,
  max: 10,
  step: 1,
);
final pickerFeature = FeatureFlag.picker<ApiEnvironment>(
  'pickerFeature',
  ApiEnvironment.prod,
  options: {for (var entry in ApiEnvironment.values) entry: entry.name},
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_EntryPoint(database: await AppDatabase.open()));
}

class _EntryPoint extends StatelessWidget {
  const _EntryPoint({this.database});

  final AppDatabase? database;

  @override
  Widget build(BuildContext context) {
    return MyDevBar(
      availableUsers: ['John', 'Jane', 'Jack'],
      database: database,
      child: MyApp(),
    );
  }
}

class MyDevBar extends StatelessWidget {
  final Widget child;
  final List<String> availableUsers;

  /// The db panel's subject, when the entry point opened one. The recipe
  /// from 2026-08-12-sqlite-watch-design.md: the app hands over
  /// query/updates/watch; flutterware imports no sqlite.
  final AppDatabase? database;

  MyDevBar({
    super.key,
    required this.child,
    required this.availableUsers,
    this.database,
  });

  @override
  Widget build(BuildContext context) {
    return Devbar(
      plugins: [
        LoggerPlugin.init(),
        LogNetworkPlugin.init(),
        LogAnalyticsPlugin.init(),
        LogQueriesPlugin.init(),
        VariablesPlugin.init(
          filePath: () async => p.join(
            (await getApplicationSupportDirectory()).path,
            'variables.json',
          ),
        ),
        InfoPlugin.new,
        StoragePlugin.new,
        DeviceFramePlugin.init(),
        if (database case var database?)
          DatabasePlugin.init(
            database: DatabaseAdapter(
              query: (sql, args) => database.db.getAll(sql, args),
              updates: database.db.updates.map((u) => u.tables),
              watch: (sql) =>
                  database.db.watch(sql, throttle: Duration(milliseconds: 250)),
              // The write door, deliberately present here: providing the
              // function is the whole opt-in, and the cockpit marks it danger.
              execute: (sql, args) => database.db.execute(sql, args),
            ),
          ),
      ],
      flags: [
        superCoolFeature.withDefaultValue,
        otherFeature.withValue(true),
        numFeature.withDefaultValue,
        pickerFeature.withDefaultValue,
      ],
      child: child,
    );
  }

  static MyDevBar? maybeOf(BuildContext context) {
    return context.findAncestorWidgetOfExactType<MyDevBar>();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _userController = TextEditingController();
  StreamSubscription? _variableSubscription;
  DevbarVariable<ApiEnvironment>? _environmentVariable;

  @override
  void initState() {
    super.initState();

    _logger.info('Init MyAppState');

    var devbar = Devbar.of(context);
    if (devbar != null) {
      var userVariable = devbar.variables.text('User');
      _userController.text = userVariable.currentValue;
      _variableSubscription = userVariable.value.listen((event) {
        _userController.text = event;
      });

      _environmentVariable = devbar.variables.picker<ApiEnvironment>(
        'Environment',
        defaultValue: ApiEnvironment.prod,
        fromJson: ApiEnvironment.fromJson,
        options: {for (var entry in ApiEnvironment.values) entry: entry.name},
      );
    }
  }

  int _networkId = 0;
  @override
  Widget build(BuildContext context) {
    Widget widget = MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text('My app')),
        body: Builder(
          builder: (context) {
            return ListView(
              children: [
                TextFormField(
                  controller: _userController,
                  decoration: InputDecoration(labelText: 'User'),
                ),
                Divider(),
                ElevatedButton(
                  onPressed: () {
                    // The door to prefer. No devbar in hand, no null check,
                    // and the same call fills a scenario's Events pane.
                    recordAppEvent(AppEvent.analytics('Open popup event'));

                    showDialog(
                      context: context,
                      builder: (context) => _MyPopup(),
                    );
                  },
                  child: Text('Open popup'),
                ),
                Divider(),
                ElevatedButton(
                  onPressed: () {
                    recordAppEvent(
                      AppEvent.query(
                        sql:
                            'SELECT id, email\n'
                            'FROM sessions\n'
                            'WHERE expires_at > ?',
                        args: ['2026-08-21'],
                        rows: 2,
                      ),
                    );
                  },
                  child: Text('Add Query'),
                ),
                Divider(),
                ElevatedButton(
                  onPressed: () {
                    recordAppEvent(AppEvent.analytics('Add network event'));

                    // The plugin's own two-part API, which is what
                    // `DevbarHttpClient` uses: it shows a request while it is
                    // still in flight, which one completed report cannot.
                    var id = _networkId++;
                    context.devbar?.network.request(
                      id,
                      method: 'GET',
                      path: 'https://www.google.com',
                    );
                    context.devbar?.network.response(
                      id,
                      body: {'hello': 'world'},
                    );
                  },
                  child: Text('Add Network'),
                ),
                Divider(),
                ElevatedButton(
                  onPressed: () {
                    _logger.info('One Log');
                  },
                  child: Text('Add log'),
                ),
                Divider(),
                ElevatedButton(
                  onPressed: () {
                    context.devbar?.ui.open();
                  },
                  child: Text('Open devbar'),
                ),
                Divider(),
                Text(
                  'Super cool feature: ${superCoolFeature.dependsOnValue(context)}',
                ),
                Divider(),
                Text('Other feature: ${otherFeature.dependsOnValue(context)}'),
                Divider(),
                Text('Num feature: ${numFeature.dependsOnValue(context)}'),
                Divider(),
                Text(
                  'Picker feature: ${pickerFeature.dependsOnValue(context)}',
                ),
                Divider(),
                StreamBuilder<ApiEnvironment>(
                  stream: _environmentVariable?.value,
                  initialData: _environmentVariable?.currentValue,
                  builder: (context, snapshot) {
                    return Text('Environment: ${snapshot.data}');
                  },
                ),
                Divider(),
                AddDevbarVariable.text(
                  name: 'MyTextVar',
                  builder: (context, value) {
                    return Text('MyTextVar: $value');
                  },
                ),
                Divider(),
                AddDevbarVariable.picker<ApiEnvironment>(
                  name: 'Secondary environment',
                  defaultValue: ApiEnvironment.prod,
                  fromJson: ApiEnvironment.fromJson,
                  options: {
                    for (var entry in ApiEnvironment.values) entry: entry.name,
                  },
                  builder: (context, value) {
                    return Text('2nd environment: $value');
                  },
                ),
              ],
            );
          },
        ),
      ),
    );

    if (Devbar.of(context) != null) {
      var availableUsers = MyDevBar.maybeOf(context)?.availableUsers;
      if (availableUsers != null) {
        widget = AddDevbarButton(
          button: DevbarDropdown<String>(
            icon: Icons.account_circle,
            onChanged: (v) {
              setState(() {
                _userController.text = v;
              });
            },
            values: {
              for (var entry in availableUsers)
                entry: Text(entry, textAlign: TextAlign.right),
            },
          ),
          child: widget,
        );
      }
    }
    return widget;
  }

  @override
  void dispose() {
    _userController.dispose();
    _variableSubscription?.cancel();
    super.dispose();
  }
}

class _MyPopup extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('My popup'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AddDevbarButton(
            position: DevbarButtonPosition.bottomRight,
            button: DevbarIcon(
              onTap: () {
                Devbar.of(context)?.ui.toast(Text('Hello'));
              },
              icon: Icons.ac_unit,
            ),
            child: Text('Child'),
          ),
        ],
      ),
    );
  }
}

enum ApiEnvironment {
  dev,
  staging,
  prod;

  const ApiEnvironment();

  static ApiEnvironment? fromJson(Object json) {
    return ApiEnvironment.values.firstWhereOrNull((e) => e.name == json);
  }

  String toJson() => name;
}
