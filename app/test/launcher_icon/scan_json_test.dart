import 'dart:convert';

import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/launcher_icon/model/role.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:flutterware_app/src/launcher_icon/model/wiring.dart';
import 'package:test/test.dart';

/// A scan survives a trip through JSON, which is what lets a real scan be
/// recorded once and drawn from anywhere — a catalog demo, a studio scenario,
/// the web demo.
void main() {
  final scan = IconScan(
    packagePath: 'fixtures/probe_app',
    flavor: 'kiosk',
    flavors: const [
      IconFlavor('kiosk', {
        IconFlavorSource.androidSourceSet,
        IconFlavorSource.config,
      }),
      IconFlavor('beta', {IconFlavorSource.config}),
    ],
    roles: [
      IconRoleScan(
        role: IconRole.androidAdaptiveForeground,
        referenced: true,
        files: [
          IconFile(
            path: 'android/app/src/main/res/mipmap-xxxhdpi/ic_fg.png',
            absolutePath:
                '/abs/android/app/src/main/res/mipmap-xxxhdpi/ic_fg.png',
            modified: DateTime.utc(2026, 9, 10, 12, 30),
            width: 432,
            height: 432,
            hasAlpha: true,
            density: 'xxxhdpi',
            resourceType: 'mipmap',
            inherited: true,
          ),
        ],
      ),
      const IconRoleScan(
        role: IconRole.androidAdaptiveBackground,
        files: [],
        color: '#FF3366',
        referenced: true,
      ),
      IconRoleScan(
        role: IconRole.iosApp,
        files: [
          IconFile(
            path: 'ios/Runner/Assets.xcassets/AppIcon.appiconset/1024.png',
            absolutePath: '/abs/ios/1024.png',
            modified: DateTime.utc(2026, 9, 10),
            width: 512,
            height: 512,
            declaredSize: 1024,
          ),
        ],
      ),
      IconRoleScan(
        role: IconRole.windowsIco,
        files: [
          IconFile(
            path: 'windows/runner/resources/app_icon.ico',
            absolutePath: '/abs/app_icon.ico',
            modified: DateTime.utc(2026, 9, 10),
            icoFrames: const [16, 32, 256],
          ),
        ],
      ),
    ],
    findings: [
      const IconFinding(
        Tone.warn,
        'Declared 1024, file is 512',
        role: IconRole.iosApp,
      ),
      const IconFinding(Tone.info, 'Nothing references the round icon'),
    ],
    android: const AndroidWiring(
      manifestIcon: '@mipmap/ic_launcher',
      launcher: AdaptiveXml(
        path: 'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
        background: '@color/ic_launcher_background',
        foreground: '@mipmap/ic_fg',
      ),
      backgroundColor: '#FF3366',
    ),
    ios: IosCatalog.both,
    iconBundles: const ['ios/Runner/Assets.xcassets/AppIcon.icon'],
  );

  test('round-trips', () {
    var wire = jsonEncode(scan.toJson());
    var back = IconScan.fromJson(jsonDecode(wire) as Map<String, Object?>);

    expect(back.toJson(), equals(scan.toJson()));
    expect(back.packagePath, 'fixtures/probe_app');
    expect(back.flavor, 'kiosk');
    expect(back.flavors.first.sources, {
      IconFlavorSource.androidSourceSet,
      IconFlavorSource.config,
    });
    expect(back.flavors.last.isUnbuilt, isTrue);

    var foreground = back.forRole(IconRole.androidAdaptiveForeground)!;
    expect(foreground.referenced, isTrue);
    expect(foreground.largest!.inherited, isTrue);
    expect(foreground.largest!.absolutePath, endsWith('ic_fg.png'));
    expect(foreground.largest!.modified, DateTime.utc(2026, 9, 10, 12, 30));

    expect(back.forRole(IconRole.androidAdaptiveBackground)!.color, '#FF3366');
    expect(back.forRole(IconRole.iosApp)!.largest!.sizeMismatch, isTrue);
    expect(back.forRole(IconRole.windowsIco)!.largest!.icoFrames, [
      16,
      32,
      256,
    ]);

    expect(back.findings.first.tone, Tone.warn);
    expect(back.findings.first.role, IconRole.iosApp);
    expect(back.findings.last.role, isNull);

    expect(back.android!.launcher!.foreground, '@mipmap/ic_fg');
    expect(back.android!.launcher!.hasMonochrome, isFalse);
    expect(back.ios, IosCatalog.both);
    expect(back.iconBundles, ['ios/Runner/Assets.xcassets/AppIcon.icon']);
  });

  test('a role is spelled by its id on the wire, like an address', () {
    var json = scan.toJson();
    var roles = json['roles']! as List;
    expect((roles.first as Map)['role'], IconRole.androidAdaptiveForeground.id);
    var findings = json['findings']! as List;
    expect((findings.first as Map)['role'], IconRole.iosApp.id);
  });

  test('an unknown role refuses rather than defaulting', () {
    var json = scan.toJson();
    (((json['roles']! as List).first) as Map)['role'] = 'android.no-such';
    expect(() => IconScan.fromJson(json), throwsFormatException);
  });
}
