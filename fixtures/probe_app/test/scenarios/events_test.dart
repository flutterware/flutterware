import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/devbar_plugins/log_network.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

/// What the app did between two screens — the transition events the panel
/// shows on the arrow, and the Events tab lists in full.
///
/// Four lanes are automatic and need no code at all: `print`, every
/// `package:logging` record, every platform channel message a plugin sends,
/// and anything a `DevbarHttpClient` carried. The two scenarios here are the
/// two ways a project meets the rest:
///
/// * **Signing in** fakes at the typed-client layer, where nothing is
///   serialised and no `http.Client` is in the path. Work that never leaves
///   the isolate has to report itself — `recordAppEvent`, two lines in the
///   fake it would have anyway.
/// * **Signing in over http** fakes the transport instead, and reports
///   nothing. Wrapping the client is the wiring the devbar already asks for,
///   and it fills this pane as a side effect.
///
/// Either way the same reports reach a mounted devbar's tabs in the running
/// app, which is the point of there being one call.
void main() {
  scenario('Signing in', (s) async {
    await s.pumpWidget(const _SignInApp(_FakeApi()));

    await s.enterText(TextField, 'nobody@example.com');
    await s.tap('Sign in');

    await s.screen('Signed in');
    expect(find.text('Hello, nobody@example.com'), findsOneWidget);
  });

  scenario('Signing in over http', (s) async {
    // The same screen with **no reporting code at all**. Its client is wrapped
    // in `DevbarHttpClient` — the wiring the devbar's own docs ask for, in
    // production entry points — and that is enough: the request shows on this
    // step's Events pane here, and on the devbar's Network tab in the running
    // app, from one wrap.
    await s.pumpWidget(_SignInApp(_HttpApi(_stubbedClient())));

    await s.enterText(TextField, 'nobody@example.com');
    await s.tap('Sign in');

    await s.screen('Signed in over http');
    expect(find.text('Hello, nobody@example.com'), findsOneWidget);
  });
}

/// A client that answers without a network, standing in for the real one.
Client _stubbedClient() => DevbarHttpClient(
  MockClient(
    (request) async => Response(
      jsonEncode({'email': (jsonDecode(request.body) as Map)['email']}),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
);

/// The other ordinary shape of a fake: real serialisation, stubbed transport.
class _HttpApi implements _FakeApi {
  const _HttpApi(this.client);

  final Client client;

  @override
  Future<String> signIn(String email) async {
    var response = await client.post(
      Uri.parse('https://api.example.com/sessions'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    return (jsonDecode(response.body) as Map)['email'] as String;
  }
}

/// A fake the app is built with — the shape a real project's test doubles
/// have, with two lines added so the flow shows what it did.
///
/// `recordAppEvent` is a no-op outside a scenario run, so these calls
/// cost a bare `flutter test` nothing and can live in shared fakes for good.
class _FakeApi {
  const _FakeApi();

  Future<String> signIn(String email) async {
    recordAppEvent(
      AppEvent.request(
        method: 'POST',
        url: '/sessions',
        status: 200,
        data: {'email': email},
      ),
    );
    recordAppEvent(
      AppEvent.query(
        sql: 'INSERT INTO sessions (email) VALUES (?)',
        args: [email],
        rows: 1,
      ),
    );
    recordAppEvent(
      AppEvent.analytics('sign_in', params: {'method': 'password'}),
    );
    return email;
  }
}

final _log = Logger('sign-in');

class _SignInApp extends StatefulWidget {
  const _SignInApp(this.api);

  final _FakeApi api;

  @override
  State<_SignInApp> createState() => _SignInAppState();
}

class _SignInAppState extends State<_SignInApp> {
  final _email = TextEditingController();
  String? _user;

  Future<void> _signIn() async {
    _log.info('signing in as ${_email.text}');
    var user = await widget.api.signIn(_email.text);
    setState(() => _user = user);
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Account')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_user case var user?)
                Text('Hello, $user', style: const TextStyle(fontSize: 20))
              else ...[
                TextField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _signIn, child: const Text('Sign in')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
