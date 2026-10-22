import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/plugins/native/assets_address.dart';
import 'package:test/test.dart';

/// The round trip is the contract.
///
/// Search writes an address, the panel reads it back. If the two directions
/// disagree by a slash, nothing throws — you simply land on a different asset,
/// which is the failure this pair exists to make impossible.
void main() {
  const keys = [
    'assets/logo.png',
    'assets/images/icons/star.png',
    'packages/flutter_scene/assets/royal_esplanade.png',
    'fonts/Roboto-Regular.ttf',
    'logo.png',
  ];

  group('asset keys survive the trip', () {
    for (var key in keys) {
      test(key, () {
        expect(
          assetPlace(assetSegments('.', key)),
          AssetPlace('.', assetKey: key),
        );
      });
    }

    test('and so does a package path containing slashes', () {
      var segments = assetSegments('fixtures/probe_app', 'assets/logo.png');
      // The package is one segment; only the key is spread, so the two cannot
      // run together and be read back wrong.
      expect(segments, ['fixtures/probe_app', 'assets', 'logo.png']);
      expect(
        assetPlace(segments),
        AssetPlace('fixtures/probe_app', assetKey: 'assets/logo.png'),
      );
    });
  });

  group('a package with no asset', () {
    test('is written as one segment', () {
      expect(assetSegments('.'), ['.']);
    });

    test('reads back with a null key', () {
      expect(assetPlace(['.']), AssetPlace('.'));
    });

    test('and an empty key is the same as none', () {
      expect(assetSegments('app', ''), ['app']);
    });
  });

  test('no segments names no place', () {
    expect(assetPlace([]), isNull);
  });

  test('survives a full Address, package separator included', () {
    var address = Address(
      worktree: 'main',
      plugin: 'flutterware.assets',
      segments: assetSegments('fixtures/probe_app', 'assets/images/logo.png'),
      axes: {'density': '3.0x'},
    );

    var parsed = Address.parse('$address');

    expect(
      assetPlace(parsed.segments),
      AssetPlace('fixtures/probe_app', assetKey: 'assets/images/logo.png'),
    );
    // The axes are applied state, not identity: the same asset at another
    // density is the same asset.
    expect(parsed.axes, {'density': '3.0x'});
    expect(
      assetPlace(parsed.bare.segments),
      assetPlace(parsed.segments),
      reason: 'Dropping the axes must not change which asset is named.',
    );
  });
}
