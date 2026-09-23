import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The folder's shots policy, end to end: nothing here says `shots:` except
/// the one scenario that disagrees with its folder.
void main() {
  scenario('takes the folder policy', (s) async {
    expect(s.shots, Shots.manual);
    await s.pumpWidget(const MaterialApp(home: Text('hello')));
  });

  scenario('says its own and wins', shots: Shots.auto, (s) async {
    expect(s.shots, Shots.auto);
    await s.pumpWidget(const MaterialApp(home: Text('hello')));
  });
}
