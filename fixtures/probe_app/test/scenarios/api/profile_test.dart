import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// A screen that loads its data and its picture over http, and the three
/// answers a scenario has for it.
///
/// This folder's `flutter_test_config.dart` says `network:
/// ScenarioNetwork.replay`, so the first scenario below is answered entirely
/// from the recording committed at `test/scenarios/network/` — two `.json`
/// files anybody can read in a diff, and a `.body.png` beside one of them.
/// Nothing here needs a connection, and `--network=record` is how the
/// recording is refreshed when the endpoint moves.
void main() {
  scenario('replayed — the profile, as it was recorded', (s) async {
    await s.pumpWidget(const _Profile());
    await s.screen('the profile');
    expect(s.network.requests.map((r) => r.outcome), ['replay', 'replay']);
  });

  scenario('stated — the shapes no recording can produce on demand', (s) async {
    s.network.get('/v1/profile', status: 503);
    await s.pumpWidget(const _Profile());
    await s.screen('the API is down');
  });

  scenario('the phone is on a train', (s) async {
    s.network.any(throws: const SocketException('Network is unreachable'));
    await s.pumpWidget(const _Profile());
    await s.screen('the offline state');
  });

  // What every scenario used to look like, and the reason for the whole
  // feature: nothing answers, and the step says so instead of drawing a blank
  // box and keeping quiet.
  scenario('nothing stated, nothing recorded', network: ScenarioNetwork.off, (
    s,
  ) async {
    await s.pumpWidget(const _Profile());
    await s.screen('the refusal is on the step');
    expect(s.network.requests.single.outcome, 'off');
  });
}

const _profileUrl = 'https://api.example.com/v1/profile';

class _Profile extends StatefulWidget {
  const _Profile();

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  late final Future<Map<String, Object?>> _profile = _load();

  Future<Map<String, Object?>> _load() async {
    var client = HttpClient();
    try {
      var response = await (await client.getUrl(Uri.parse(_profileUrl)))
          .close();
      if (response.statusCode != 200) {
        throw HttpException('${response.statusCode}');
      }
      return jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, Object?>;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: FutureBuilder<Map<String, Object?>>(
          future: _profile,
          builder: (context, snapshot) => switch (snapshot) {
            AsyncSnapshot(hasError: true) => const Text("Couldn't load"),
            AsyncSnapshot(data: var profile?) => _Card(profile: profile),
            _ => const CircularProgressIndicator(),
          },
        ),
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.profile});

  final Map<String, Object?> profile;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipOval(
        child: Image.network(
          '${profile['avatar']}',
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => Container(
            width: 96,
            height: 96,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.person_outlined, size: 48),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        '${profile['name']}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text('${profile['title']}'),
    ],
  );
}
