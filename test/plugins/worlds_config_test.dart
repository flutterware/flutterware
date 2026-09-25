import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

/// Worlds are declared, one `WorldScript` each, the way Run's entry points
/// are — nothing is scanned for.
void main() {
  const server = Pkg('server');
  const shop = Pkg('shop_server');

  test('a world rides the manifest with its path, name and description', () {
    var config = Worlds(
      packages: [
        .new(
          server,
          worlds: [
            WorldScript(
              'tool/worlds/pickup_order.dart',
              name: 'Pickup order',
              description: 'A barista and a regular',
            ),
            WorldScript('tool/worlds/team_invite.dart'),
          ],
        ),
      ],
    ).config;
    expect(config, {
      'packages': [
        {
          'path': 'server',
          'worlds': [
            {
              'path': 'tool/worlds/pickup_order.dart',
              'name': 'Pickup order',
              'description': 'A barista and a regular',
            },
            {'path': 'tool/worlds/team_invite.dart'},
          ],
        },
      ],
    });
  });

  test(
    'a world is opened by its file name, so two of one name are refused',
    () {
      expect(
        () => Worlds(
          packages: [
            .new(server, worlds: [WorldScript('tool/worlds/pickup.dart')]),
            .new(shop, worlds: [WorldScript('worlds/pickup.dart')]),
          ],
        ).config,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Two worlds are called "pickup"'),
          ),
        ),
      );
    },
  );

  test('its id is the file name without .dart', () {
    expect(
      const WorldScript('tool/worlds/pickup_order.dart').id,
      'pickup_order',
    );
  });
}
