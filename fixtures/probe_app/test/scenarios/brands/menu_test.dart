import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// One screen, themed by the brand this pass runs in — the word from the
/// folder's profile turned into a theme here, where the app is built.
void main() {
  scenario('Menu', (s) async {
    var brand = s.axis('brand');
    var seed = switch (brand) {
      'tea' => Colors.green,
      _ => Colors.brown,
    };
    await s.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: seed),
        home: Scaffold(
          appBar: AppBar(title: Text('Brand: $brand')),
          body: Center(
            child: FilledButton(onPressed: () {}, child: const Text('Order')),
          ),
        ),
      ),
      shot: Shot('Menu'),
    );
    await s.tap('Order', shot: Shot('Ordered'));
  });
}
