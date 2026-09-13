import 'package:flutter_test/flutter_test.dart';
import 'package:brewline/shop/shop_app.dart';

/// The card counts drinks, not orders, and wraps at the reward.
void main() {
  test('a round of three is three stamps', () {
    var loyalty = Loyalty()..stamp(3);
    expect(loyalty.stamps, 3);
  });

  test('the reward drink resets the card', () {
    var loyalty = Loyalty()..stamp(Loyalty.perReward + 2);
    expect(loyalty.stamps, 2);
  });

  test('an empty order stamps nothing', () {
    var loyalty = Loyalty()..stamp(0);
    expect(loyalty.stamps, 0);
  });
}
