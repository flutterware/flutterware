import 'device_settings.dart';
import 'known_gaps.dart';

/// Android's settings, over plain `adb`.
///
/// The better of the two v1 targets by some distance, and worth saying why: six
/// of the eight settings here have a command that **owns** them and reports
/// them when asked, the locale is scoped to one package rather than the whole
/// device, and rotation costs nothing and steals no focus. Where the iOS
/// simulator has three commands that answer and two stores that echo, this has
/// one mechanism that answers throughout.
///
/// Works unchanged against a physical Android device — `adb` does not care, and
/// neither does anything below. It is not offered there in v1 only because
/// nothing has measured it.
///
/// Measured in S-D2, 2026-08-24, against API 35 / Android 15.
class AdbDeviceSettings implements DeviceSettings {
  AdbDeviceSettings({
    required this.serial,
    required this.adb,
    String? package,
    RunDeviceProcess? run,
  }) : _package = package,
       _lookedForPackage = package != null,
       _run = run ?? defaultRunDeviceProcess;

  /// The device as `adb -s` takes it, which is the same string `flutter run -d`
  /// took.
  final String serial;

  /// Absolute path to `adb` — located from the SDK by
  /// `AdbNativeDriver.findAdb`, not from `PATH`, where a working toolchain
  /// routinely does not have it.
  final String adb;

  final RunDeviceProcess _run;

  /// The application id, needed by the one app-scoped setting.
  ///
  /// Not on `RunHandle`: what a run knows is the *Dart* package path, and the
  /// application id is an Android build product. So it is learned, the way the
  /// native driver learns its own — but from `dumpsys`, which costs
  /// milliseconds, rather than from a `uiautomator dump`, which costs seconds
  /// and would make reading a strip as expensive as observing a screen.
  ///
  /// **A success is cached and a failure is not**, and the asymmetry is the
  /// whole of it: an application id does not change for the life of a run, so
  /// once the app has been seen there is nothing to look up again. Not finding
  /// it is a fact about *this moment* — the strip reads on mount, and on mount
  /// the build may still be running with no app on screen at all — so latching
  /// that answer left the locale row dead for the rest of the session with
  /// refresh unable to fix it.
  String? _package;

  /// Set only by the constructor: a package handed in is not a guess and is
  /// never re-derived.
  final bool _lookedForPackage;

  @override
  String get platform => 'android';

  /// The ladder Android's own display settings offer.
  ///
  /// A ladder rather than a slider because the effect is **not** a multiplier:
  /// Android 14+ scales non-linearly, so 2.0 is ×1.86 at 14sp and ×1.00 at
  /// 100sp (measured). A control that showed one number would be telling an
  /// iOS truth on an Android device.
  static const fontScales = <String>[
    '0.85',
    '1.0',
    '1.15',
    '1.3',
    '1.5',
    '1.8',
    '2.0',
  ];

  @override
  Future<List<DeviceSetting>> read({AppSizeReader? appSize}) async => [
    await _brightness(),
    await _textScale(),
    await _orientation(),
    await _language(),
    _boldText(),
    _highContrast(),
    await _invertColors(),
    await _disableAnimations(),
  ];

  @override
  Future<DeviceSetting> write(
    DeviceSettingId id,
    String value, {
    AppSizeReader? appSize,
  }) async {
    switch (id) {
      case DeviceSettingId.brightness:
        _require(value, const ['light', 'dark'], id);
        await _shell([
          'cmd',
          'uimode',
          'night',
          value == 'dark' ? 'yes' : 'no',
        ]);
        return _brightness();
      case DeviceSettingId.textScale:
        if (double.tryParse(value) == null) {
          throw DeviceRefusal(
            'Android takes a font scale as a number, and "$value" is not one. '
            'Its own settings offer ${fontScales.join(', ')}.',
          );
        }
        await _shell(['settings', 'put', 'system', 'font_scale', value]);
        return _textScale();
      case DeviceSettingId.orientation:
        _require(value, const ['portrait', 'landscape'], id);
        // Auto-rotate first, or the device turns itself back.
        await _shell([
          'settings',
          'put',
          'system',
          'accelerometer_rotation',
          '0',
        ]);
        await _shell([
          'settings',
          'put',
          'system',
          'user_rotation',
          value == 'landscape' ? '1' : '0',
        ]);
        return _turned(value);
      case DeviceSettingId.language:
        var package = await _packageId();
        if (package == null) throw _noPackage();
        await _shell([
          'cmd',
          'locale',
          'set-app-locales',
          package,
          '--locales',
          value.trim(),
        ]);
        return _language();
      case DeviceSettingId.invertColors:
        _require(value, const ['on', 'off'], id);
        await _shell([
          'settings',
          'put',
          'secure',
          'accessibility_display_inversion_enabled',
          value == 'on' ? '1' : '0',
        ]);
        return _invertColors();
      case DeviceSettingId.disableAnimations:
        _require(value, const ['on', 'off'], id);
        // All three, so the device is actually calm. Flutter follows the
        // transition scale alone (measured), but a phone with two of the three
        // still animating is not the phone anybody asked for.
        for (var key in const [
          'transition_animation_scale',
          'window_animation_scale',
          'animator_duration_scale',
        ]) {
          await _shell([
            'settings',
            'put',
            'global',
            key,
            value == 'on' ? '0' : '1',
          ]);
        }
        return _disableAnimations();
      case DeviceSettingId.boldText:
      case DeviceSettingId.highContrast:
        var refused = id == DeviceSettingId.boldText
            ? _boldText()
            : _highContrast();
        throw DeviceRefusal(refused.refusal!, command: refused.command);
    }
  }

  // ── the six that answer ────────────────────────────────────────────────

  Future<DeviceSetting> _brightness() async {
    // `Night mode: yes` — a sentence, not a value, so it is parsed rather than
    // trimmed.
    var answer = await _shellRead(['cmd', 'uimode', 'night']);
    var mode = answer == null
        ? null
        : RegExp(r'Night mode:\s*(\w+)').firstMatch(answer)?.group(1);
    var value = switch (mode) {
      'yes' => 'dark',
      'no' => 'light',
      _ => null,
    };
    return DeviceSetting(
      id: DeviceSettingId.brightness,
      noun: 'Theme',
      value: value,
      provenance: value == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: const ['light', 'dark'],
      atDefault: value == 'light',
      command: 'adb shell cmd uimode night',
      note: mode == null || mode == 'yes' || mode == 'no'
          ? null
          : 'The device is on "$mode", which is neither light nor dark until '
                'the system picks one.',
    );
  }

  Future<DeviceSetting> _textScale() async {
    var raw = await _settingsGet('system', 'font_scale');
    return DeviceSetting(
      id: DeviceSettingId.textScale,
      noun: 'Text',
      value: raw,
      display: raw == null ? null : 'font_scale $raw',
      provenance: raw == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: fontScales,
      atDefault: raw != null && double.tryParse(raw) == 1.0,
      command: 'adb shell settings get system font_scale',
      note:
          'Android scales text non-linearly, so this is not a multiplier: 2.0 '
          'is ×1.86 at 14sp and ×1.00 at 100sp.',
    );
  }

  /// Read from what the device **is**, not from what it was asked to be.
  ///
  /// `settings get system user_rotation` is the obvious read and it is wrong
  /// whenever auto-rotate is on: it is a request the sensor overrides, and it
  /// keeps whatever it was last set to forever afterwards. Caught by running
  /// this against a real emulator — `user_rotation` said `1` while the display
  /// was 1080×2400, which is portrait. `am get-config` prints the
  /// configuration the device is currently resolved to, carrying `-port-` or
  /// `-land-`, and that is the answer. The two settings below stay, because
  /// they are how the *write* works.
  Future<DeviceSetting> _orientation() async {
    var config = await _shellRead(['am', 'get-config']);
    var value = config == null ? null : parseConfigOrientation(config);
    var auto = await _settingsGet('system', 'accelerometer_rotation');
    return DeviceSetting(
      id: DeviceSettingId.orientation,
      noun: 'Turn',
      value: value,
      provenance: value == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: const ['portrait', 'landscape'],
      atDefault: value == 'portrait',
      command: 'adb shell am get-config',
      note: auto == '1'
          ? 'Auto-rotate is on, so the device is deciding this. Setting it '
                'here turns auto-rotate off first.'
          : null,
    );
  }

  /// Waits for the screen to actually turn, then reports it.
  ///
  /// The write lands instantly and the configuration does not: measured, a
  /// re-read 170ms after `settings put user_rotation 0` still said landscape,
  /// and two seconds later the device was portrait. Answering from that first
  /// read is how a control comes to report the opposite of what it did.
  ///
  /// Running out of the budget is a refusal rather than a shrug, because the
  /// case it catches is a real one and worth naming: an app that pins its own
  /// orientation with `SystemChrome.setPreferredOrientations` will take the
  /// device setting and never turn.
  Future<DeviceSetting> _turned(String wanted) async {
    var deadline = DateTime.now().add(const Duration(seconds: 2));
    var setting = await _orientation();
    while (setting.value != wanted && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      setting = await _orientation();
    }
    if (setting.value != wanted) {
      throw DeviceRefusal(
        'The device is set to $wanted and the screen is still '
        '${setting.value ?? 'not saying'} two seconds later. An app that pins '
        'its own orientation with SystemChrome.setPreferredOrientations '
        'accepts the device setting but does not rotate.',
        command: 'adb -s $serial shell am get-config',
      );
    }
    return setting;
  }

  /// `port` or `land` out of the configuration qualifier string.
  ///
  /// The dashes are load-bearing: the same string holds `-long-` and
  /// `-notround-`, so a bare `contains('land')` finds nothing today and
  /// something wrong eventually.
  static String? parseConfigOrientation(String config) {
    if (config.contains('-port-')) return 'portrait';
    if (config.contains('-land-')) return 'landscape';
    return null;
  }

  Future<DeviceSetting> _language() async {
    var package = await _packageId();
    if (package == null) {
      return DeviceSetting.unavailable(
        id: DeviceSettingId.language,
        noun: 'Lang',
        reason: _noPackage().message,
        command: 'adb shell dumpsys activity activities',
      );
    }
    var raw = await _shellRead(['cmd', 'locale', 'get-app-locales', package]);
    var locales = raw == null ? const <String>[] : parseAppLocales(raw);
    return DeviceSetting(
      id: DeviceSettingId.language,
      noun: 'Lang',
      value: locales.isEmpty ? null : locales.first,
      provenance: raw == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      // The one app-scoped setting on this target, and the reason Android beats
      // the simulator here: nothing else on the device changes.
      scope: DeviceScope.app,
      atDefault: locales.isEmpty,
      // Whatever is set, as a suggestion. Nothing host-side can enumerate the
      // locales an app actually ships, so a closed list here would offer
      // exactly one choice: the one already in force.
      options: locales,
      openOptions: true,
      // The one setting on either target with a real off position, and it is
      // reachable: `--locales ""` hands the app back to the device.
      clearLabel: 'Device language',
      command: 'adb shell cmd locale get-app-locales $package',
      note:
          'Applies to $package only, right away, with no restart. Takes any '
          'BCP-47 tag; an empty value returns the app to the device language.',
    );
  }

  Future<DeviceSetting> _invertColors() async {
    var raw = await _settingsGet(
      'secure',
      'accessibility_display_inversion_enabled',
    );
    // An unset key comes back as the *string* `null`, which `_settingsGet`
    // has already turned into a Dart null — and that is off rather than
    // unknown here, because the key not existing is how Android spells "never
    // turned on".
    var value = raw == '1' ? 'on' : 'off';
    return DeviceSetting(
      id: DeviceSettingId.invertColors,
      noun: 'A11y',
      value: value,
      provenance: DeviceProvenance.answered,
      options: const ['on', 'off'],
      atDefault: value == 'off',
      command:
          'adb shell settings get secure '
          'accessibility_display_inversion_enabled',
    );
  }

  Future<DeviceSetting> _disableAnimations() async {
    var raw = await _settingsGet('global', 'transition_animation_scale');
    var scale = raw == null ? 1.0 : double.tryParse(raw) ?? 1.0;
    var value = scale == 0 ? 'on' : 'off';
    return DeviceSetting(
      id: DeviceSettingId.disableAnimations,
      noun: 'A11y',
      value: value,
      provenance: DeviceProvenance.answered,
      options: const ['on', 'off'],
      atDefault: value == 'off',
      command: 'adb shell settings get global transition_animation_scale',
      note:
          'The engine reads the transition scale. Setting this also writes '
          'the window and animator scales, so animations stop on the whole '
          'device.',
    );
  }

  // ── the two refusals ───────────────────────────────────────────────────

  DeviceSetting _highContrast() => DeviceSetting.unavailable(
    id: DeviceSettingId.highContrast,
    noun: 'A11y',
    reason: notDeliveredReason(platform, DeviceSettingId.highContrast),
    command: 'adb shell settings put secure high_text_contrast_enabled 1',
  );

  DeviceSetting _boldText() => const DeviceSetting.unavailable(
    id: DeviceSettingId.boldText,
    noun: 'A11y',
    reason:
        'Android delivers bold text, but applying it recreates the activity: '
        'the app loses its state and main() runs again. The other controls '
        'here apply live, so this one is left out.',
    command: 'adb shell settings put secure font_weight_adjustment 300',
  );

  // ── plumbing ───────────────────────────────────────────────────────────

  /// `[fr-FR]` out of `Locales for com.example.x for user 0 are [fr-FR]`, and
  /// an empty list out of `[]`.
  static List<String> parseAppLocales(String raw) {
    var inside = RegExp(r'\[([^\]]*)\]').firstMatch(raw)?.group(1) ?? '';
    return [
      for (var tag in inside.split(','))
        if (tag.trim().isNotEmpty) tag.trim(),
    ];
  }

  /// `settings get`, with its three not-a-value answers folded into one null.
  ///
  /// An unset key prints the **string** `null`; a failed call prints nothing.
  /// Both have to stop being mistaken for `0`, which is a real value and means
  /// the opposite of "nobody has set this". The S-P5 rule: an empty parse is an
  /// error, not an empty answer.
  Future<String?> _settingsGet(String namespace, String key) async {
    var answer = await _shellRead(['settings', 'get', namespace, key]);
    if (answer == null || answer.isEmpty || answer == 'null') return null;
    return answer;
  }

  Future<String?> _packageId() async {
    if (_lookedForPackage || _package != null) return _package;
    var dump = await _shellRead(['dumpsys', 'activity', 'activities']);
    return _package = dump == null ? null : parseResumedPackage(dump);
  }

  /// The package of whatever is resumed on screen, **when that is an app**.
  ///
  /// Which is the app under test in the ordinary case. In the two cases it is
  /// not — the launcher while a build is still installing, Settings after
  /// somebody has walked off into it — this answers null rather than the
  /// platform's own package, and the locale row becomes the refusal that says
  /// to bring the app forward. Handing back `com.google.android.apps.…` would
  /// have meant a `Set` writing the *launcher's* locale, on a row whose only
  /// warning was the package name in six-point grey.
  ///
  /// The filter is `AdbNativeDriver`'s, which learns its own package the same
  /// way and for the same reason.
  static String? parseResumedPackage(String dump) {
    var match = RegExp(
      r'(?:mResumedActivity|topResumedActivity)[^\n]*?\s([\w.]+)/[\w.$]+',
    ).firstMatch(dump);
    var package = match?.group(1);
    if (package == null || _isPlatform(package)) return null;
    return package;
  }

  static bool _isPlatform(String package) =>
      package == 'android' ||
      package.startsWith('com.android.') ||
      package.startsWith('com.google.android.');

  DeviceRefusal _noPackage() => DeviceRefusal(
    'Nothing on screen says which app this is, so there is no package to set a '
    'locale for. Android sets the language per package; bring the app to the '
    'front and try again.',
  );

  Future<String?> _shellRead(List<String> args) async {
    var result = await _run(adb, ['-s', serial, 'shell', ...args]);
    if (result.exitCode != 0) return null;
    return '${result.stdout}'.trim();
  }

  Future<void> _shell(List<String> args) async {
    var result = await _run(adb, ['-s', serial, 'shell', ...args]);
    if (result.exitCode != 0) {
      throw DeviceRefusal(
        'adb refused: ${'${result.stderr}'.trim()}',
        command: 'adb -s $serial shell ${args.join(' ')}',
      );
    }
  }

  void _require(String value, Iterable<String> options, DeviceSettingId id) {
    if (options.contains(value)) return;
    throw DeviceRefusal(
      '${id.name} on Android takes ${options.join(', ')}, and "$value" is '
      'not one of them.',
    );
  }
}
