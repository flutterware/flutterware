import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/run/device/adb_settings.dart';
import 'package:flutterware_app/src/run/device/device_settings.dart';

import 'fake_process.dart';

const _serial = 'emulator-5554';
const _adb = '/Users/dev/Library/Android/sdk/platform-tools/adb';
const _package = 'com.example.device_probe';

/// The line `dumpsys activity activities` prints for whatever is on screen,
/// trimmed to the one entry that matters.
const _dumpsys =
    '''
  mResumedActivity: ActivityRecord{9f3b2c1 u0 $_package/.MainActivity t42}
  mLastPausedActivity: ActivityRecord{1a2b3c4 u0 com.android.launcher3/.Launcher t9}
''';

AdbDeviceSettings _settings(FakeProcesses fake, {String? package = _package}) =>
    AdbDeviceSettings(
      serial: _serial,
      adb: _adb,
      package: package,
      run: fake.run,
    );

void main() {
  group('the six that answer', () {
    test(
      'night mode is a sentence, and is parsed rather than trimmed',
      () async {
        var fake = FakeProcesses({'cmd uimode night': 'Night mode: yes\n'});
        var theme = (await _settings(
          fake,
        ).read()).of(DeviceSettingId.brightness);

        expect(theme.value, 'dark');
        expect(theme.provenance, DeviceProvenance.answered);
        expect(theme.atDefault, isFalse);
      },
    );

    test('an auto night mode is neither light nor dark, and says so', () async {
      var fake = FakeProcesses({'cmd uimode night': 'Night mode: auto\n'});
      var theme = (await _settings(fake).read()).of(DeviceSettingId.brightness);

      expect(theme.value, isNull);
      expect(theme.provenance, DeviceProvenance.unknown);
      expect(theme.note, contains('auto'));
    });

    test(
      'the font scale is shown as a device setting, never as a multiplier',
      () async {
        var fake = FakeProcesses({'settings get system font_scale': '1.5\n'});
        var text = (await _settings(fake).read()).of(DeviceSettingId.textScale);

        expect(text.value, '1.5');
        expect(text.display, 'font_scale 1.5');
        // The measured reason it cannot be a multiplier, on the row itself.
        expect(text.note, contains('×1.86 at 14sp'));
        expect(text.note, contains('×1.00 at 100sp'));
        expect(text.atDefault, isFalse);
      },
    );

    test('rotation is read from the config the device resolved to', () async {
      // Not from `user_rotation`, which is a request the sensor overrides —
      // caught against a real emulator, where it said landscape while the
      // display was 1080x2400.
      for (var entry in {'port': 'portrait', 'land': 'landscape'}.entries) {
        var fake = FakeProcesses({
          'am get-config':
              'config: mcc310-mnc260-en-rUS-ldltr-sw411dp-w411dp-h914dp-'
              'normal-long-notround-nowidecg-lowdr-${entry.key}-night-420dpi\n',
          // Deliberately disagreeing, and deliberately ignored.
          'settings get system user_rotation': '1\n',
        });
        var turn = (await _settings(
          fake,
        ).read()).of(DeviceSettingId.orientation);

        expect(turn.value, entry.value, reason: entry.key);
        expect(turn.provenance, DeviceProvenance.answered);
        expect(
          turn.cost,
          DeviceCost.free,
          reason: 'unlike the simulator, this steals no focus',
        );
      }
    });

    test('the qualifier is matched with its dashes', () {
      // `-long-` and `-notround-` both live in the same string.
      var portrait =
          'config: mcc310-ldltr-sw411dp-normal-long-notround-port-night-420dpi';
      expect(AdbDeviceSettings.parseConfigOrientation(portrait), 'portrait');
      expect(
        AdbDeviceSettings.parseConfigOrientation('config: nothing-useful'),
        isNull,
      );
    });

    test("the locale is the app's own, and the row says whose", () async {
      var fake = FakeProcesses({
        'cmd locale get-app-locales':
            'Locales for $_package for user 0 are [fr-FR]\n',
      });
      var language = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.language);

      expect(language.value, 'fr-FR');
      expect(language.provenance, DeviceProvenance.answered);
      expect(
        language.scope,
        DeviceScope.app,
        reason: 'the one app-scoped setting on this target',
      );
      expect(language.cost, DeviceCost.free, reason: 'live, no restart');
      expect(language.command, contains(_package));
      expect(language.atDefault, isFalse);
    });

    test('no override is the default, not an unknown', () async {
      var fake = FakeProcesses({
        'cmd locale get-app-locales':
            'Locales for $_package for user 0 are []\n',
      });
      var language = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.language);

      expect(language.value, isNull);
      expect(language.atDefault, isTrue);
    });

    test(
      'reduce motion follows the transition scale, and says which',
      () async {
        var fake = FakeProcesses({
          'settings get global transition_animation_scale': '0\n',
        });
        var reduce = (await _settings(
          fake,
        ).read()).of(DeviceSettingId.disableAnimations);

        expect(reduce.value, 'on');
        expect(reduce.note, contains('transition scale'));
      },
    );
  });

  group('settings get has three ways of not answering', () {
    test('the string null is not zero', () async {
      // The S-P5 trap, on a different command: an unset key prints `null` as
      // text, and `0` is a real value meaning the opposite of "never set".
      var fake = FakeProcesses({'settings get system font_scale': 'null\n'});
      var text = (await _settings(fake).read()).of(DeviceSettingId.textScale);

      expect(text.value, isNull);
      expect(text.provenance, DeviceProvenance.unknown);
      expect(text.atDefault, isFalse, reason: 'unknown is not 1.0');
    });

    test('a failed call is unknown too', () async {
      var fake = FakeProcesses()..failing.add('settings get system font_scale');
      var text = (await _settings(fake).read()).of(DeviceSettingId.textScale);

      expect(text.provenance, DeviceProvenance.unknown);
    });

    test('an unset accessibility flag is off, because that is how Android spells it', () async {
      var fake = FakeProcesses({
        'accessibility_display_inversion_enabled': 'null\n',
      });
      var invert = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.invertColors);

      expect(invert.value, 'off');
      expect(invert.provenance, DeviceProvenance.answered);
      expect(invert.atDefault, isTrue);
    });
  });

  group('the package the locale belongs to', () {
    test('is read off whatever is resumed on screen', () {
      expect(AdbDeviceSettings.parseResumedPackage(_dumpsys), _package);
    });

    test('is null when nothing is resumed', () {
      expect(AdbDeviceSettings.parseResumedPackage('nothing here'), isNull);
    });

    test('is looked up once, not per setting', () async {
      var fake = FakeProcesses({'dumpsys activity activities': _dumpsys});
      var settings = _settings(fake, package: null);
      await settings.read();
      await settings.read();

      expect(
        fake.calls.where((call) => call.contains('dumpsys')).length,
        1,
        reason: 'a strip mount should not pay for this twice',
      );
    });

    test('the platform is not an app, so it is not the answer', () {
      // The two moments the strip reads and the app is *not* what is resumed:
      // the launcher, while a build is still installing, and Settings, after
      // somebody walked off into it. Answering with either meant `Set` writing
      // the launcher's locale, on a row whose only warning was a package name
      // in six-point grey.
      for (var package in const [
        'com.google.android.apps.nexuslauncher',
        'com.android.launcher3',
        'com.android.settings',
        'android',
      ]) {
        expect(
          AdbDeviceSettings.parseResumedPackage(
            '  mResumedActivity: ActivityRecord{9f3 u0 $package/.Main t42}',
          ),
          isNull,
          reason: package,
        );
      }
    });

    test('not finding it is not an answer worth keeping', () async {
      // The failure that latched: the strip reads on mount, and on mount the
      // build may still be running with nothing of ours on screen. Cached,
      // that left the locale row dead for the rest of the session with refresh
      // unable to fix it — so a miss is retried and a hit is not.
      var fake = FakeProcesses();
      var settings = _settings(fake, package: null);
      expect(
        (await settings.read()).of(DeviceSettingId.language).state,
        DeviceSettingState.unavailable,
      );

      fake.reply('dumpsys activity activities', _dumpsys);
      fake.reply('get-app-locales', 'Locales for $_package are [fr-FR]');
      var language = (await settings.read()).of(DeviceSettingId.language);

      expect(language.state, DeviceSettingState.set);
      expect(language.value, 'fr-FR');

      // And once it is known it stays known: the app id cannot change under a
      // run, so a later read while the user is off in Settings still writes to
      // the app under test.
      await settings.read();
      expect(
        fake.calls.where((call) => call.contains('dumpsys')).length,
        2,
        reason: 'one miss, one hit, and nothing after the hit',
      );
    });

    test('a write refuses rather than setting the launcher’s locale', () async {
      // Not merely a dead row: without the package this used to resolve to
      // whatever was resumed and hand it to `set-app-locales`.
      var fake = FakeProcesses();
      await expectLater(
        _settings(fake, package: null).write(DeviceSettingId.language, 'fr-FR'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('bring the app to the front'),
          ),
        ),
      );
      expect(fake.ran('set-app-locales'), isFalse);
    });

    test(
      'without one, the locale row is a refusal that says what to do',
      () async {
        var fake = FakeProcesses();
        var language = (await _settings(
          fake,
          package: null,
        ).read()).of(DeviceSettingId.language);

        expect(language.state, DeviceSettingState.unavailable);
        expect(language.refusal, contains('bring the app to the front'));
      },
    );
  });

  group('writes', () {
    test('turn auto-rotate off before turning the device', () async {
      // Or the device turns itself straight back, which reads as the write
      // having failed.
      var fake = FakeProcesses({
        'am get-config': 'config: sw411dp-long-land-420dpi\n',
      });
      await _settings(fake).write(DeviceSettingId.orientation, 'landscape');

      expect(
        fake.indexOf('accelerometer_rotation 0'),
        lessThan(fake.indexOf('user_rotation 1')),
      );
    });

    test('a rotation waits for the screen to catch up', () async {
      // Measured: a re-read 170ms after the write still said landscape, and
      // the device was portrait two seconds later. Answering from that first
      // read is how a control reports the opposite of what it did.
      var fake = FakeProcesses({
        'am get-config': 'config: sw411dp-long-land-420dpi\n',
      });
      var turns = 0;
      var settings = AdbDeviceSettings(
        serial: _serial,
        adb: _adb,
        package: _package,
        run: (executable, arguments) async {
          if (arguments.contains('get-config') && ++turns > 2) {
            fake.reply('am get-config', 'config: sw411dp-long-port-420dpi\n');
          }
          return fake.run(executable, arguments);
        },
      );

      var setting = await settings.write(
        DeviceSettingId.orientation,
        'portrait',
      );
      expect(setting.value, 'portrait');
      expect(turns, greaterThan(2), reason: 'it had to look more than once');
    });

    test('a screen that never turns names the likely cause', () async {
      // An app pinning its own orientation takes the device setting and does
      // not move, which is worth saying rather than reporting either value.
      var fake = FakeProcesses({
        'am get-config': 'config: sw411dp-long-land-420dpi\n',
      });
      await expectLater(
        _settings(fake).write(DeviceSettingId.orientation, 'portrait'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('setPreferredOrientations'),
          ),
        ),
      );
    });

    test(
      'reduce motion writes all three scales, so the device is actually calm',
      () async {
        var fake = FakeProcesses();
        await _settings(fake).write(DeviceSettingId.disableAnimations, 'on');

        expect(fake.ran('transition_animation_scale 0'), isTrue);
        expect(fake.ran('window_animation_scale 0'), isTrue);
        expect(fake.ran('animator_duration_scale 0'), isTrue);
      },
    );

    test('a locale goes to the package and nowhere else', () async {
      var fake = FakeProcesses();
      await _settings(fake).write(DeviceSettingId.language, 'fr-FR');

      expect(
        fake.ran('cmd locale set-app-locales $_package --locales fr-FR'),
        isTrue,
      );
    });

    test('an empty locale hands the app back to the device language', () async {
      var fake = FakeProcesses();
      await _settings(fake).write(DeviceSettingId.language, '');

      expect(fake.ran('set-app-locales $_package --locales'), isTrue);
    });

    test(
      'a font scale that is not a number is refused before anything spawns',
      () async {
        var fake = FakeProcesses();
        await expectLater(
          _settings(fake)
              .write(DeviceSettingId.textScale, 'accessibility-large'),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              contains('as a number'),
            ),
          ),
        );
        expect(fake.calls, isEmpty);
      },
    );

    test('the reply is the re-read', () async {
      var fake = FakeProcesses({'cmd uimode night': 'Night mode: yes\n'});
      var setting = await _settings(fake)
          .write(DeviceSettingId.brightness, 'dark');

      expect(setting.value, 'dark');
      expect(fake.ran('cmd uimode night yes'), isTrue);
    });
  });

  group('the two this platform refuses', () {
    test('high contrast says why it is unavailable', () async {
      var contrast = (await _settings(
        FakeProcesses(),
      ).read()).of(DeviceSettingId.highContrast);

      expect(contrast.state, DeviceSettingState.unavailable);
      expect(contrast.refusal, contains('no Flutter app sees it'));
      expect(contrast.refusal, contains('no high-contrast flag'));
    });

    test('bold text is refused on cost, not on reach', () async {
      // Android does deliver it. It also tears the activity down to apply it,
      // and every other control here is live.
      var bold = (await _settings(
        FakeProcesses(),
      ).read()).of(DeviceSettingId.boldText);

      expect(bold.state, DeviceSettingState.unavailable);
      expect(bold.refusal, contains('recreates the activity'));
    });

    test('writing either one spawns nothing', () async {
      for (var id in [DeviceSettingId.highContrast, DeviceSettingId.boldText]) {
        var fake = FakeProcesses();
        await expectLater(
          _settings(fake).write(id, 'on'),
          throwsA(isA<DeviceRefusal>()),
        );
        expect(fake.calls, isEmpty, reason: id.name);
      }
    });
  });

  test('every setting is reported, refusals included', () async {
    var settings = await _settings(FakeProcesses()).read();
    expect(
      settings.map((setting) => setting.id).toSet(),
      DeviceSettingId.values.toSet(),
    );
  });
}
