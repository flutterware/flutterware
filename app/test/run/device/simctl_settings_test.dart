import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/run/device/device_settings.dart';
import 'package:flutterware_app/src/run/device/simctl_settings.dart';

import 'fake_process.dart';

const _udid = 'A97ABCFD-A7B4-4C4F-8169-6F3403394F55';

/// What `defaults read -g AppleLanguages` printed on the device this was built
/// against. A plist fragment rather than a value, which is the whole reason it
/// gets a parser.
const _appleLanguages = '''
(
    "en-US",
    "fr-BE"
)
''';

SimctlDeviceSettings _settings(FakeProcesses fake) =>
    SimctlDeviceSettings(udid: _udid, run: fake.run);

/// A portrait iPhone 17 Pro, and the same device turned — the numbers the probe
/// app printed.
Future<({double width, double height})?> _portrait() async =>
    (width: 402.0, height: 874.0);
Future<({double width, double height})?> _landscape() async =>
    (width: 874.0, height: 402.0);

void main() {
  group('the three commands that own a setting', () {
    test('report it, and that is evidence', () async {
      var fake = FakeProcesses({
        'ui $_udid appearance': 'dark\n',
        'ui $_udid content_size': 'accessibility-large\n',
        'ui $_udid increase_contrast': 'enabled\n',
      });
      var settings = await _settings(fake).read();

      expect(settings.of(DeviceSettingId.brightness).value, 'dark');
      expect(
        settings.of(DeviceSettingId.brightness).provenance,
        DeviceProvenance.answered,
      );
      expect(
        settings.of(DeviceSettingId.textScale).value,
        'accessibility-large',
      );
      expect(settings.of(DeviceSettingId.highContrast).value, 'on');
      expect(
        settings.of(DeviceSettingId.highContrast).provenance,
        DeviceProvenance.answered,
      );
    });

    test('a default reads as a default, so the strip can draw quiet', () async {
      var fake = FakeProcesses({
        'ui $_udid appearance': 'light\n',
        'ui $_udid content_size': 'large\n',
        'ui $_udid increase_contrast': 'disabled\n',
      });
      var settings = await _settings(fake).read();

      expect(settings.of(DeviceSettingId.brightness).atDefault, isTrue);
      expect(settings.of(DeviceSettingId.textScale).atDefault, isTrue);
      expect(settings.of(DeviceSettingId.highContrast).atDefault, isTrue);
    });

    test('the ladder carries what each step does to a TextScaler', () async {
      // Measured at 100 logical pixels, where iOS is linear. The picker says
      // it so nobody has to find out by looking.
      var fake = FakeProcesses({
        'ui $_udid content_size': 'accessibility-large\n',
      });
      var text = (await _settings(fake).read()).of(DeviceSettingId.textScale);

      expect(text.note, contains('×1.94'));
      expect(text.options, hasLength(12));
      expect(SimctlDeviceSettings.contentSizes['large'], 1.0);
      expect(SimctlDeviceSettings.contentSizes['extra-small'], 0.824);
    });

    test(
      "both of the platform's ways of not answering land on unknown",
      () async {
        // `simctl ui` has two, and neither of them is a value. An empty parse
        // is an error, not an empty answer — so neither may fall through to a
        // default.
        for (var refusal in ['unsupported\n', 'unknown\n', '\n']) {
          var fake = FakeProcesses({'ui $_udid appearance': refusal});
          var brightness = (await _settings(
            fake,
          ).read()).of(DeviceSettingId.brightness);

          expect(brightness.value, isNull, reason: refusal);
          expect(brightness.provenance, DeviceProvenance.unknown);
          expect(brightness.atDefault, isFalse, reason: 'not light — unknown');
        }
      },
    );
  });

  group('the two settings that only echo', () {
    test(
      'the language list parses, and is marked written not answered',
      () async {
        var fake = FakeProcesses({
          'defaults read -g AppleLanguages': _appleLanguages,
        });
        var language = (await _settings(
          fake,
        ).read()).of(DeviceSettingId.language);

        expect(language.value, 'en-US');
        expect(language.options, ['en-US', 'fr-BE']);
        expect(language.provenance, DeviceProvenance.written);
        expect(language.cost, DeviceCost.relaunchesApp);
        expect(
          language.scope,
          DeviceScope.device,
          reason: 'iOS changes every app on the simulator, unlike Android',
        );
      },
    );

    test('a language that was read at all reads as quiet', () async {
      // There is no default to be at — the list is whatever the machine was
      // set up with. Left false, the chip drew bold and bordered on a simulator
      // nobody had touched, beside four muted ones.
      var fake = FakeProcesses({
        'defaults read -g AppleLanguages': _appleLanguages,
      });
      var language = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.language);

      expect(language.atDefault, isTrue);

      var nothing = (await _settings(
        FakeProcesses()..failing.add('AppleLanguages'),
      ).read()).of(DeviceSettingId.language);
      expect(
        nothing.atDefault,
        isFalse,
        reason: 'nothing answered is not a quiet answer',
      );
    });

    test('a one-entry list without quotes parses too', () {
      // Some runtimes drop the quotes when there is a single language, which is
      // exactly the case a regex written against the two-entry output misses.
      expect(SimctlDeviceSettings.parseAppleLanguages('(\n    fr-FR\n)'), [
        'fr-FR',
      ]);
      expect(SimctlDeviceSettings.parseAppleLanguages('(\n    "fr-FR"\n)'), [
        'fr-FR',
      ]);
    });

    test('invert colours says out loud that its value is an echo', () async {
      var fake = FakeProcesses({'InvertColorsEnabled': '1\n'});
      var invert = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.invertColors);

      expect(invert.value, 'on');
      expect(invert.provenance, DeviceProvenance.written);
      expect(invert.note, contains('As written'));
    });

    test('an absent key is off rather than unknown', () async {
      // `defaults read` exits non-zero when the key was never written, and the
      // absence *is* the answer: the domain is the one iOS itself reads.
      var fake = FakeProcesses()..failing.add('InvertColorsEnabled');
      var invert = (await _settings(
        fake,
      ).read()).of(DeviceSettingId.invertColors);

      expect(invert.value, 'off');
      expect(invert.atDefault, isTrue);
    });
  });

  group('orientation, which the device will not answer', () {
    test("comes off the app's own geometry", () async {
      var settings = _settings(FakeProcesses());

      var portrait = (await settings.read(appSize: _portrait))
          .of(DeviceSettingId.orientation);
      expect(portrait.value, 'portrait');
      expect(portrait.provenance, DeviceProvenance.derived);
      expect(portrait.cost, DeviceCost.takesFocus);

      var landscape = (await settings.read(appSize: _landscape))
          .of(DeviceSettingId.orientation);
      expect(landscape.value, 'landscape');
    });

    test('is unknown when no app is answering', () async {
      var turn = (await _settings(
        FakeProcesses(),
      ).read()).of(DeviceSettingId.orientation);

      expect(turn.value, isNull);
      expect(turn.provenance, DeviceProvenance.unknown);
    });

    test('refuses to rotate what it cannot see', () async {
      await expectLater(
        _settings(FakeProcesses())
            .write(DeviceSettingId.orientation, 'landscape'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('needs the app running'),
          ),
        ),
      );
    });

    test('refuses when the menu click reported success and nothing turned', () async {
      // The measured trap, twice in both directions: a click against a
      // Simulator that is not the front window returns the menu item exactly as
      // it does on success. The only defence is asking the app afterwards.
      var fake = FakeProcesses();
      await expectLater(
        _settings(
          fake,
        ).write(DeviceSettingId.orientation, 'landscape', appSize: _portrait),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.message,
            'message',
            contains('not the front window'),
          ),
        ),
      );
      expect(fake.ran('Rotate Left'), isTrue, reason: 'it did try');
    });

    test('activates the Simulator before clicking, and checks after', () async {
      var turns = [_portrait, _landscape];
      var fake = FakeProcesses();
      var setting = await _settings(fake).write(
        DeviceSettingId.orientation,
        'landscape',
        appSize: () => turns.removeAt(0)(),
      );

      expect(setting.value, 'landscape');
      expect(
        fake.indexOf('to activate'),
        lessThan(fake.indexOf('Rotate Left')),
        reason: 'the click only lands on the front window',
      );
    });

    test('already there is not a rotation', () async {
      var fake = FakeProcesses();
      var setting = await _settings(fake)
          .write(DeviceSettingId.orientation, 'portrait', appSize: _portrait);

      expect(setting.value, 'portrait');
      expect(fake.ran('Rotate'), isFalse);
    });
  });

  group('writes', () {
    test('go out as the command that owns the setting, then re-read', () async {
      var fake = FakeProcesses({'ui $_udid appearance': 'dark\n'});
      var setting = await _settings(fake)
          .write(DeviceSettingId.brightness, 'dark');

      expect(fake.ran('simctl ui $_udid appearance dark'), isTrue);
      expect(
        setting.value,
        'dark',
        reason: 'the reply is the re-read, not the echo of what was asked',
      );
      expect(
        fake.indexOf('appearance dark') <
            fake.calls.lastIndexOf('xcrun simctl ui $_udid appearance'),
        isTrue,
        reason: 'the read happens after the write',
      );
    });

    test(
      'a value the platform does not take is refused before anything spawns',
      () async {
        var fake = FakeProcesses();
        await expectLater(
          _settings(fake).write(DeviceSettingId.brightness, 'sepia'),
          throwsA(isA<DeviceRefusal>()),
        );
        expect(fake.calls, isEmpty);
      },
    );

    test('a language is promoted, and the rest of the list survives', () async {
      // `defaults write -array` replaces the array. Writing the one tag
      // deleted every other preferred language on the simulator —
      // permanently, device-wide, and invisibly, because the picker's own
      // suggestions are that same list read back.
      var fake = FakeProcesses({
        'defaults read -g AppleLanguages': _appleLanguages,
      });
      var language = await _settings(fake)
          .write(DeviceSettingId.language, 'fr-BE');

      expect(
        fake.calls.firstWhere((call) => call.contains('defaults write')),
        endsWith('-g AppleLanguages -array fr-BE en-US'),
        reason: 'promoted to the front, with en-US kept behind it',
      );
      expect(language.options, [
        'en-US',
        'fr-BE',
      ], reason: 'the re-read still has both to offer');
    });

    test('promoting one already on the list does not duplicate it', () async {
      var fake = FakeProcesses({
        'defaults read -g AppleLanguages': _appleLanguages,
      });
      await _settings(fake).write(DeviceSettingId.language, 'en-US');

      expect(
        fake.calls.firstWhere((call) => call.contains('defaults write')),
        endsWith('-g AppleLanguages -array en-US fr-BE'),
      );
    });

    test('a machine that answers nothing gets the one tag', () async {
      // Only the *read* fails here — nothing to keep is not a reason to refuse
      // the write.
      var fake = FakeProcesses()
        ..failing.add('defaults read -g AppleLanguages');
      await _settings(fake).write(DeviceSettingId.language, 'ja');

      expect(
        fake.calls.firstWhere((call) => call.contains('defaults write')),
        endsWith('-g AppleLanguages -array ja'),
      );
    });

    test(
      'an empty language is refused rather than clearing the device',
      () async {
        var fake = FakeProcesses();
        await expectLater(
          _settings(fake).write(DeviceSettingId.language, '  '),
          throwsA(
            isA<DeviceRefusal>().having(
              (e) => e.message,
              'message',
              contains('BCP-47'),
            ),
          ),
        );
        expect(fake.calls, isEmpty);
      },
    );
  });

  group('the two this platform refuses', () {
    test(
      'bold text says the key it would write is one nothing reads',
      () async {
        var bold = (await _settings(
          FakeProcesses(),
        ).read()).of(DeviceSettingId.boldText);

        expect(bold.state, DeviceSettingState.unavailable);
        expect(bold.refusal, contains('creates a key nothing reads'));
        expect(bold.command, contains('Settings'));
      },
    );

    test('reduce motion says why it is unavailable', () async {
      var reduce = (await _settings(
        FakeProcesses(),
      ).read()).of(DeviceSettingId.disableAnimations);

      expect(reduce.state, DeviceSettingState.unavailable);
      expect(reduce.refusal, contains('even after a relaunch'));
    });

    test('writing one throws its own reason, and spawns nothing', () async {
      var fake = FakeProcesses();
      await expectLater(
        _settings(fake).write(DeviceSettingId.boldText, 'on'),
        throwsA(
          isA<DeviceRefusal>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains('bold text'), contains('Settings')),
          ),
        ),
      );
      expect(fake.calls, isEmpty);
    });
  });

  test('every setting is reported, refusals included', () async {
    // A refusal is a row and not an absence: a missing control reads as an
    // oversight, and the reason is the useful half.
    var settings = await _settings(FakeProcesses()).read();
    expect(
      settings.map((setting) => setting.id).toSet(),
      DeviceSettingId.values.toSet(),
    );
  });
}
