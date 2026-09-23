import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The scrolling example — a list long enough that the target is not built
/// yet, which is what `s.scrollTo` is for.
///
/// The shop next door never scrolls: five drinks fit on every phone in the
/// profile, and a scenario that walks a list it can already see proves
/// nothing. So this is its own screen, the way `counter_test.dart` is — small
/// enough to read in one sitting, and long enough to need a thumb.
///
/// It is also what a **film** of a scroll is checked against: rendered with
/// `fw run scenarios video`, the list moves under a finger that swipes it,
/// where every other verb's cursor only ever taps.
void main() {
  scenario('Find a bean in the list', (s) async {
    await s.pumpWidget(const _BeansApp(), shot: Shot('The catalogue'));

    // Seventeen rows down, so the walk takes several swipes and the last one
    // stops the moment the row is built rather than at a fixed distance.
    await s.scrollTo('Yirgacheffe');
    await s.tap('Yirgacheffe', shot: Shot('In the basket'));

    expect(find.text('Yirgacheffe · in the basket'), findsOneWidget);
  });
}

class _BeansApp extends StatefulWidget {
  const _BeansApp();

  @override
  State<_BeansApp> createState() => _BeansAppState();
}

class _BeansAppState extends State<_BeansApp> {
  String? _picked;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF8A4B2A),
      useMaterial3: true,
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('Single origins')),
      body: Column(
        children: [
          if (_picked case var picked?)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.all(16),
              child: Text('$picked · in the basket'),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _beans.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                var (origin, note, price) = _beans[index];
                return ListTile(
                  leading: const Text('🫘', style: TextStyle(fontSize: 22)),
                  title: Text(origin),
                  subtitle: Text(note),
                  trailing: Text('$price €'),
                  onTap: () => setState(() => _picked = origin),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

const _beans = <(String, String, String)>[
  ('Huila', 'Red apple, cane sugar', '8.50'),
  ('Antigua', 'Cocoa, toasted almond', '9.00'),
  ('Sidamo', 'Jasmine, lemon peel', '9.50'),
  ('Nariño', 'Peach, brown sugar', '8.90'),
  ('Chiapas', 'Hazelnut, milk chocolate', '7.90'),
  ('Kayanza', 'Blackcurrant, cola', '10.50'),
  ('Kirinyaga', 'Tomato, blackberry', '11.00'),
  ('Yunnan', 'Walnut, dried fig', '8.20'),
  ('Tarrazú', 'Honey, orange', '9.20'),
  ('Boquete', 'Bergamot, cane', '12.00'),
  ('Kochere', 'Peach, earl grey', '10.20'),
  ('Nyeri', 'Grapefruit, cassis', '11.50'),
  ('Cerrado', 'Peanut, caramel', '7.50'),
  ('Toraja', 'Cedar, dark chocolate', '9.80'),
  ('Bourbon', 'Butter, plum', '8.80'),
  ('Gayo', 'Pine, molasses', '9.10'),
  ('Yirgacheffe', 'Bergamot, honeysuckle', '10.80'),
  ('Ngozi', 'Redcurrant, lime', '10.00'),
  ('Nyamasheke', 'Apricot, black tea', '10.40'),
  ('Marcala', 'Vanilla, red grape', '8.60'),
  ('Chelbesa', 'Lychee, jasmine', '12.50'),
  ('Kamwangi', 'Rhubarb, cane sugar', '11.20'),
  ('Guji', 'Strawberry, cocoa', '11.80'),
  ('Santa Bárbara', 'Fig, praline', '9.60'),
];
