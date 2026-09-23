import 'package:material_ui/material_ui.dart';

/// Shown on the home page, to prove which build is on the device.
///
/// A **knob**: an optional named parameter of `main`, so the cockpit offers it
/// with its own default and changing it costs a hot restart. It used to be a
/// `--dart-define`, which cost a rebuild.
String marker = '<none>';

void main({String fwMarker = '<none>'}) {
  marker = fwMarker;
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.white,
        //appBarTheme: AppBarTheme(
        //  color: Colors.white,
        //  titleTextStyle: TextStyle(color: Colors.black87),
        //  elevation: 1,
        //  scrolledUnderElevation: 2,
        //),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
      localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
      supportedLocales: [
        Locale('en'),
        Locale('fr'),
        Locale('es'),
        Locale('de'),
      ],
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        children: [
          Text(
            'FW_MARKER: $marker',
            key: const Key('fw-marker'),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('Language: ${Localizations.localeOf(context).languageCode}'),
          Text(MaterialLocalizations.of(context).alertDialogLabel),
          Text(MaterialLocalizations.of(context).invalidTimeLabel),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Text(
                  'You have pushed the button this many times: and this need',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text(
                '$_counter',
                style: Theme.of(context).textTheme.displayMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          Divider(),
          TextField(
            decoration: InputDecoration(
              suffixIcon: Icon(Icons.access_alarm),
              prefixIcon: Icon(Icons.password),
            ),
          ),
          Switch(value: true, onChanged: (v) {}),
          ElevatedButton(onPressed: () {}, child: Text('OK')),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
