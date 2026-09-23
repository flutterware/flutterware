import 'package:material_ui/material_ui.dart';
import 'package:flutterware/devbar.dart';
import 'package:flutterware/devbar_plugins/variables.dart';

import 'devbar_example.dart';

void main() => runApp(App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return Devbar(
      plugins: [VariablesPlugin.init()],
      flags: [],
      child: _InnerApp(),
    );
  }
}

class _InnerApp extends StatelessWidget {
  const _InnerApp();

  @override
  Widget build(BuildContext context) {
    return AddDevbarVariable.group6<
      ApiEnvironment,
      String,
      bool,
      num,
      int,
      double
    >(
      DevbarVariable.picker(
        'Secondary environment',
        defaultValue: ApiEnvironment.prod,
        options: {for (var entry in ApiEnvironment.values) entry: entry.name},
        fromJson: ApiEnvironment.fromJson,
      ),
      DevbarVariable.text('text'),
      DevbarVariable.checkbox('ahaha'),
      DevbarVariable.slider(
        'ahaha',
        defaultValue: 0,
        min: 0,
        max: 1,
        step: 0.1,
      ),
      DevbarVariable.slider<int>(
        'ahaha',
        defaultValue: 0,
        min: 0,
        max: 10,
        step: 2,
      ),
      DevbarVariable.slider<double>(
        'ahaha3',
        defaultValue: 0,
        min: 0,
        max: 10,
        step: 1,
      ),
      builder: (context, environment, text, checkbox, slider, v5, v6) {
        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: () {
                      Devbar.of(context)!.ui.open();
                    },
                    child: Text('Open'),
                  ),
                  Text('$environment $text $checkbox $slider $v5 $v6'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
