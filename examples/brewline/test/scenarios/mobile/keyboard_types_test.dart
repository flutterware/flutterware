import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// One flow through a form whose fields want four different keyboards.
///
/// **What the shots are of.** Not four pictures of a keyboard — four pictures
/// of a *screen*, each with the keyboard the field under the caret actually
/// asked for, and each laid out against the screen that keyboard left. On a
/// phone the digits one is 45 points shorter than the letters one, so the form
/// above it sits 45 points lower: two of these steps are the same layout meeting
/// two different screens, which is exactly the thing no full-height screenshot
/// can show.
///
/// Nothing here asks for a keyboard. Every raise below is the framework telling
/// the platform a field took focus, which is the only signal the feature reads.
void main() {
  scenario('Signing up on a phone', (s) async {
    await s.pumpWidget(const _SignUp());

    // The letters keyboard, and the baseline every other step is read against.
    await s.enterText(const Key('name'), 'Ada', shot: Shot('Name'));
    expect(s.keyboard.variant, KeyboardVariant.letters);
    var letters = s.keyboard.height;

    // An `@` and a dot come out of the space bar. Same height, different
    // keyboard — which is why the picture needs a signal the height cannot
    // give it.
    await s.enterText(
      const Key('email'),
      'ada@example.com',
      shot: Shot('Email'),
    );
    expect(s.keyboard.variant, KeyboardVariant.email);
    expect(s.keyboard.height, letters);

    // A slash and a `.com`, and no space bar at all — a URL has no spaces in
    // it, and its keyboard says so.
    await s.enterText(const Key('site'), 'example.com', shot: Shot('Website'));
    expect(s.keyboard.variant, KeyboardVariant.url);

    // And the one that moves the layout: a digit pad, with no strip to predict
    // with, and measurably shorter on every iPhone in the table.
    await s.enterText(const Key('phone'), '5551234', shot: Shot('Phone'));
    expect(s.keyboard.variant, KeyboardVariant.keypad);
    expect(
      s.keyboard.height,
      lessThan(letters),
      reason: 'an iPhone gives a keypad fewer points than a QWERTY',
    );

    // The button was under the keyboard the whole way down. Dismissing is what
    // a user does to reach it, and it makes the app let go of the field rather
    // than hiding artwork over a form that is still focused.
    await s.keyboard.dismiss(shot: Shot('Ready to sign up'));
    expect(s.keyboard.isRequested, isFalse);
    await s.tap(const Key('submit'), shot: Shot('Signed up'));
  });
}

class _SignUp extends StatefulWidget {
  const _SignUp();

  @override
  State<_SignUp> createState() => _SignUpState();
}

class _SignUpState extends State<_SignUp> {
  var _done = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('Sign up')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          spacing: 14,
          children: [
            const TextField(
              key: Key('name'),
              decoration: InputDecoration(labelText: 'Name'),
            ),
            const TextField(
              key: Key('email'),
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: 'Email'),
            ),
            const TextField(
              key: Key('site'),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: 'Website'),
            ),
            const TextField(
              key: Key('phone'),
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: 'Phone'),
            ),
            const Spacer(),
            if (_done) const Text('Welcome aboard'),
            FilledButton(
              key: const Key('submit'),
              onPressed: () => setState(() => _done = true),
              child: const Text('Sign up'),
            ),
          ],
        ),
      ),
    ),
  );
}
