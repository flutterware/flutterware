import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/guest_text_input.dart';
import 'package:flutterware/src/world/guest_input.dart';
import 'package:flutterware/src/world/step_names.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('a field is known by', () {
    FieldKind kind({
      List<String> hints = const [],
      TextInputType type = TextInputType.text,
      bool obscure = false,
    }) => fieldKindOf(
      TextInputConfiguration(
        inputType: type,
        obscureText: obscure,
        autofillConfiguration: AutofillConfiguration(
          uniqueIdentifier: 'field',
          autofillHints: hints,
          currentEditingValue: TextEditingValue.empty,
        ),
      ),
    );

    test('its autofill hints first', () {
      expect(kind(hints: [AutofillHints.email]), FieldKind.email);
      expect(kind(hints: [AutofillHints.username]), FieldKind.email);
      expect(kind(hints: [AutofillHints.newPassword]), FieldKind.password);
      expect(kind(hints: [AutofillHints.givenName]), FieldKind.name);
      expect(kind(hints: [AutofillHints.telephoneNumber]), FieldKind.phone);
      expect(kind(hints: [AutofillHints.oneTimeCode]), FieldKind.code);
      // The web's words, for an app written for both.
      expect(kind(hints: ['one-time-code']), FieldKind.code);
      expect(kind(hints: ['current-password']), FieldKind.password);
      // A hint outranks the keyboard: a code field asks for digits.
      expect(
        kind(hints: [AutofillHints.oneTimeCode], type: TextInputType.number),
        FieldKind.code,
      );
      // The first hint the world knows wins.
      expect(
        kind(hints: [AutofillHints.jobTitle, AutofillHints.email]),
        FieldKind.email,
      );
    });

    test('then its keyboard', () {
      expect(kind(type: TextInputType.emailAddress), FieldKind.email);
      expect(kind(type: TextInputType.phone), FieldKind.phone);
      expect(kind(type: TextInputType.name), FieldKind.name);
      expect(kind(type: TextInputType.visiblePassword), FieldKind.password);
      expect(
        kind(hints: [AutofillHints.jobTitle], type: TextInputType.phone),
        FieldKind.phone,
      );
    });

    test('then whether it hides what is typed', () {
      expect(kind(obscure: true), FieldKind.password);
      expect(
        kind(type: TextInputType.emailAddress, obscure: true),
        FieldKind.email,
      );
    });

    test('and is otherwise nothing the world can fill', () {
      expect(kind(), FieldKind.other);
      expect(kind(type: TextInputType.number), FieldKind.other);
      expect(kind(hints: [AutofillHints.postalCode]), FieldKind.other);
    });
  });

  group('a fill', () {
    setUp(GuestTextInput.instance.install);
    tearDown(TextInput.restorePlatformInputControl);

    var input = GuestTextInput.instance;

    Future<(TextEditingController, TextEditingController)> pumpSignIn(
      WidgetTester tester, {
      bool grouped = true,
    }) async {
      var email = TextEditingController();
      var password = TextEditingController();
      addTearDown(email.dispose);
      addTearDown(password.dispose);
      Widget fields = Column(
        children: [
          TextField(
            key: const Key('email'),
            controller: email,
            autofillHints: const [AutofillHints.email],
          ),
          TextField(
            key: const Key('password'),
            controller: password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
          ),
        ],
      );
      if (grouped) fields = AutofillGroup(child: fields);
      await tester.pumpWidget(MaterialApp(home: Material(child: fields)));
      return (email, password);
    }

    testWidgets('says what kind of field has focus, and what is with it', (
      tester,
    ) async {
      await pumpSignIn(tester);
      expect(focusedField(input), isEmpty);
      await tester.tap(find.byKey(const Key('password')));
      await tester.pump();
      expect(focusedField(input), {
        'kind': 'password',
        'group': ['email'],
      });
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(focusedField(input), isEmpty);
    });

    testWidgets('of a sign-in form fills the address and the password', (
      tester,
    ) async {
      var (email, password) = await pumpSignIn(tester);
      await tester.tap(find.byKey(const Key('email')));
      await tester.pump();
      var filled = fillFocused(input, 'nurse@example.com', {
        FieldKind.password: 'hunter2',
      });
      await tester.pump();
      expect(filled, 2);
      expect(email.text, 'nurse@example.com');
      expect(password.text, 'hunter2');
    });

    testWidgets('outside a group fills the focused field alone', (
      tester,
    ) async {
      var (email, password) = await pumpSignIn(tester, grouped: false);
      await tester.tap(find.byKey(const Key('email')));
      await tester.pump();
      expect(
        fillFocused(input, 'nurse@example.com', {
          FieldKind.password: 'hunter2',
        }),
        1,
      );
      await tester.pump();
      expect(email.text, 'nurse@example.com');
      expect(password.text, isEmpty);
      expect(focusedField(input), {'kind': 'email', 'group': <String>[]});
    });

    testWidgets('fills nothing when no field has focus', (tester) async {
      var (email, _) = await pumpSignIn(tester);
      expect(fillFocused(input, 'nurse@example.com', const {}), 0);
      await tester.pump();
      expect(email.text, isEmpty);
    });
  });

  testWidgets('a link reaches the app whole, as deep linking delivers it', (
    tester,
  ) async {
    var heard = <Uri>[];
    var observer = _Links(heard, takes: true);
    tester.binding.addObserver(observer);
    addTearDown(() => tester.binding.removeObserver(observer));

    var link = 'https://example.com/invite?token=a%2Bb';
    expect(await push(tester, link), isTrue);
    expect(heard, [Uri.parse(link)]);
  });

  testWidgets('a Router goes where the link says', (tester) async {
    var provider = PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(uri: Uri.parse('/')),
    );
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      WidgetsApp.router(
        color: const Color(0xFF000000),
        routeInformationProvider: provider,
        routeInformationParser: _Parser(),
        routerDelegate: _Delegate(),
      ),
    );
    expect(find.text('/'), findsOneWidget);

    expect(await push(tester, 'https://example.com/invite'), isTrue);
    await tester.pump();
    expect(find.text('/invite'), findsOneWidget);
  });

  testWidgets('says when nothing in the app took it', (tester) async {
    var observer = _Links([], takes: false);
    tester.binding.addObserver(observer);
    addTearDown(() => tester.binding.removeObserver(observer));

    expect(await push(tester, 'https://example.com/x'), isFalse);
  });
}

/// The channel answers on the real event loop, which a widget test's fake
/// clock does not run.
Future<bool?> push(WidgetTester tester, String link) =>
    tester.runAsync(() => pushRouteInformation(link));

class _Links with WidgetsBindingObserver {
  _Links(this.heard, {required this.takes});

  final List<Uri> heard;
  final bool takes;

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    heard.add(routeInformation.uri);
    return Future.value(takes);
  }
}

class _Parser extends RouteInformationParser<String> {
  @override
  Future<String> parseRouteInformation(RouteInformation routeInformation) =>
      Future.value(routeInformation.uri.path);
}

class _Delegate extends RouterDelegate<String> with ChangeNotifier {
  var _path = '/';

  @override
  String get currentConfiguration => _path;

  @override
  Future<void> setNewRoutePath(String configuration) async {
    _path = configuration;
    notifyListeners();
  }

  @override
  Future<bool> popRoute() => Future.value(false);

  @override
  Widget build(BuildContext context) =>
      Text(_path, textDirection: TextDirection.ltr);
}
