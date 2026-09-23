import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

const _members = [
  ('DS', 'Dr. Sarah Chen', 'Dermatologist'),
  ('DL', 'Dr. Lena Kruger', 'Pathologist'),
  ('DJ', 'Dr. James Okafor', 'Plastic Surgeon'),
];

const _longText = [
  (
    'VL',
    'Dr. Valentina Lowenstein-Schwarzenberg',
    'Senior Consultant in Dermatology and Venereology',
  ),
];

@Preview(name: 'Members', group: 'Avatar tile', wrapper: wrapInApp)
Widget avatarTileMembers() => _list(_members);

@Preview(name: 'Empty', group: 'Avatar tile', wrapper: wrapInApp)
Widget avatarTileEmpty() => _list(const []);

@Preview(name: 'Long text', group: 'Avatar tile', wrapper: wrapInApp)
Widget avatarTileLongText() => _list(_longText);

Widget _list(List<(String, String, String)> people) {
  return Scaffold(
    appBar: AppBar(title: const Text('Team')),
    body: people.isEmpty
        ? const Center(child: Text('No members yet'))
        : ListView(
            children: [
              for (var (initials, name, subtitle) in people)
                ListTile(
                  leading: CircleAvatar(child: Text(initials)),
                  title: Text(name),
                  subtitle: Text(subtitle),
                ),
            ],
          ),
  );
}

/// The real-device path: every demo file is its own runnable app.
void main() => runApp(wrapInApp(avatarTileMembers()));
