import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Desktop-sized, to exercise `formFactor: FormFactor.desktop` resolving to a
/// 1440x900 `Preview.size` through `transform()`.
@Preview(name: 'Dashboard', wrapper: wrapInApp)
Widget dashboard() => const _Dashboard();

class _Dashboard extends StatelessWidget {
  const _Dashboard();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: 1,
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.table_chart_outlined),
                label: Text('Environments'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Text(
                    'Environments',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Expanded(child: _Table()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListView(
        children: [
          for (var (name, region, status) in const [
            ('production', 'eu-west-1', 'healthy'),
            ('staging', 'eu-west-1', 'healthy'),
            ('preview', 'us-east-1', 'degraded'),
          ])
            ListTile(
              title: Text(name),
              subtitle: Text(region),
              trailing: Chip(label: Text(status)),
            ),
        ],
      ),
    );
  }
}

void main() => runApp(wrapInApp(dashboard()));
