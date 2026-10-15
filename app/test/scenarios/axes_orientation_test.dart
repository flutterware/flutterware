import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';

/// The orientation axis where the address, the wire and the artifact tree meet.
///
/// The rule under all of it: **portrait is the absence of the axis**. It writes
/// nothing to an address, nothing to a slug and nothing to the wire, so every
/// link and every output directory that existed before orientation did still
/// names the same picture.
void main() {
  test('landscape reaches the guest as rotated geometry', () {
    var args = const ScenarioAxes(
      device: 'ipad',
      orientation: 'landscape',
    ).harnessArgs();

    // 810×1080 stood on its side. The harness applies numbers and never learns
    // what `landscape` means.
    expect(args['width'], '1080');
    expect(args['height'], '810');
    expect(args['device'], 'ipad');
  });

  test('and as an axis in its own right, for the device nobody has picked yet', () {
    var args = const ScenarioAxes(orientation: 'landscape')
        .harnessArgs(unspecifiedDevice: 'iphone-13');

    // The geometry is only the host's fallback — a scenario folder's profile
    // may name something else, and the harness is the one that asks it. So the
    // word travels too, or a folder-chosen device would never turn.
    expect(args['deviceUnspecified'], 'true');
    expect(args['orientation'], 'landscape');
  });

  test('a notched phone sends its declared landscape insets', () {
    var args = const ScenarioAxes(
      device: 'iphone-13',
      orientation: 'landscape',
    ).harnessArgs();

    expect(args['insetTop'], '0');
    expect(args['insetLeft'], '47');
    expect(args['insetRight'], '47');
    expect(args['insetBottom'], '20');
  });

  test('a device that cannot turn ignores the axis, everywhere', () {
    const axes = ScenarioAxes(device: 'window-wide', orientation: 'landscape');

    expect(axes.isLandscape, isFalse);
    expect(axes.toParams().containsKey('orientation'), isFalse);
    expect(axes.harnessArgs().containsKey('orientation'), isFalse);
    expect(axisSlug(axes), 'window-wide');
    expect(axes.harnessArgs()['width'], '1600');
  });

  test('portrait writes nothing an address or a path would carry', () {
    const portrait = ScenarioAxes(device: 'ipad', orientation: 'portrait');

    expect(portrait.toParams(), {'device': 'ipad'});
    expect(axisSlug(portrait), 'ipad');
    expect(portrait.harnessArgs().containsKey('orientation'), isFalse);
    // Byte-identical to what an address said before the axis existed.
    expect(portrait.toParams(), const ScenarioAxes(device: 'ipad').toParams());
  });

  test('landscape does, and in the same order both lanes write', () {
    const landscape = ScenarioAxes(
      device: 'ipad',
      orientation: 'landscape',
      language: 'fr',
    );

    expect(landscape.toParams(), {
      'device': 'ipad',
      'orientation': 'landscape',
      'language': 'fr',
    });
    expect(axisSlug(landscape), 'ipad-landscape-fr');
  });

  test('two ways up are two assignments, not one cache entry', () {
    const portrait = ScenarioAxes(device: 'ipad');
    const landscape = ScenarioAxes(device: 'ipad', orientation: 'landscape');

    expect(portrait == landscape, isFalse);
    expect(portrait.hashCode == landscape.hashCode, isFalse);
    expect(landscape.isEmpty, isFalse);
  });

  test('copyWith carries the axis rather than dropping it', () {
    const landscape = ScenarioAxes(device: 'ipad', orientation: 'landscape');

    expect(landscape.copyWith(language: 'fr').orientation, 'landscape');
    expect(landscape.copyWith(device: 'iphone-13').isLandscape, isTrue);
  });
}
