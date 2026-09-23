import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Checkout flow', (s) async {
    await s.pumpWidget(const MyApp());

    await s.tap(Icons.shopping_cart);
    await s.enterText(TextField, '4334', shot: Shot('Coupon code entered'));
    await s.tap(translations.checkoutButton, shot: Shot.skip);
    await s.screen('Order confirmed');

    expect(find.text('Thank you!'), findsOneWidget);
  });
}

// == App code (for example purpose)
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

final translations = Translations();

class Translations {
  String get checkoutButton => '';
}
