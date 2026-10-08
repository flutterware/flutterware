import 'device_settings.dart';
import 'known_gaps.dart';

/// The iOS simulator's settings, over `simctl` and one AppleScript.
///
/// `xcrun simctl help` lists forty-eight subcommands. Three of them own a
/// setting outright and answer when asked with no argument — `ui appearance`,
/// `ui content_size`, `ui increase_contrast` — and those three are the whole of
/// what this platform will *tell* you. Everything else here is weaker on
/// purpose and says so: two settings can only be read back out of the
/// `defaults` store they were written to, one is read off the app's own
/// geometry because the simulator has no verb for it at all, and two are
/// refused.
///
/// Measured in S-D1, 2026-08-24: every command in this file was run against an
/// iPhone 17 Pro on iOS 26.2 and correlated with a probe app printing its own
/// `MediaQuery`.
class SimctlDeviceSettings implements DeviceSettings {
  SimctlDeviceSettings({
    required this.udid,
    RunDeviceProcess? run,
    RunDeviceProcess? runOsascript,
  }) : _run = run ?? defaultRunDeviceProcess,
       _osascript = runOsascript ?? run ?? defaultRunDeviceProcess;

  /// The booted simulator, which is also what `flutter run -d` took — so
  /// `RunHandle.device` is this string with no translation.
  final String udid;

  final RunDeviceProcess _run;
  final RunDeviceProcess _osascript;

  @override
  String get platform => 'ios-simulator';

  /// The twelve categories `simctl ui content_size` accepts, with what each one
  /// does to a Flutter `TextScaler`.
  ///
  /// Measured at 100 logical pixels, where iOS's scaling is linear — unlike
  /// Android's, which is a curve. The numbers are here so the picker can say
  /// *"a11y-large is ×1.94"* beside the name instead of leaving a designer to
  /// find out by looking.
  static const contentSizes = <String, double>{
    'extra-small': 0.824,
    'small': 0.882,
    'medium': 0.941,
    'large': 1.0,
    'extra-large': 1.118,
    'extra-extra-large': 1.235,
    'extra-extra-extra-large': 1.353,
    'accessibility-medium': 1.647,
    'accessibility-large': 1.941,
    'accessibility-extra-large': 2.353,
    'accessibility-extra-extra-large': 2.765,
    'accessibility-extra-extra-extra-large': 3.118,
  };

  @override
  Future<List<DeviceSetting>> read({AppSizeReader? appSize}) async {
    var size = await appSize?.call();
    return [
      await _brightness(),
      await _textScale(),
      _orientation(size),
      await _language(),
      _boldText(),
      await _highContrast(),
      await _invertColors(),
      _disableAnimations(),
    ];
  }

  @override
  Future<DeviceSetting> write(
    DeviceSettingId id,
    String value, {
    AppSizeReader? appSize,
  }) async {
    switch (id) {
      case DeviceSettingId.brightness:
        _require(value, const ['light', 'dark'], id);
        await _simctl(['ui', udid, 'appearance', value]);
        return _brightness();
      case DeviceSettingId.textScale:
        _require(value, contentSizes.keys, id);
        await _simctl(['ui', udid, 'content_size', value]);
        return _textScale();
      case DeviceSettingId.highContrast:
        _require(value, const ['on', 'off'], id);
        await _simctl([
          'ui',
          udid,
          'increase_contrast',
          value == 'on' ? 'enabled' : 'disabled',
        ]);
        return _highContrast();
      case DeviceSettingId.invertColors:
        _require(value, const ['on', 'off'], id);
        await _defaultsWrite([
          'com.apple.Accessibility',
          'InvertColorsEnabled',
          '-bool',
          value == 'on' ? 'true' : 'false',
        ]);
        return _invertColors();
      case DeviceSettingId.language:
        return _promote(value);
      case DeviceSettingId.orientation:
        return _rotate(value, appSize);
      case DeviceSettingId.boldText:
      case DeviceSettingId.disableAnimations:
        var refused = id == DeviceSettingId.boldText
            ? _boldText()
            : _disableAnimations();
        throw DeviceRefusal(refused.refusal!, command: refused.command);
    }
  }

  // ── the three that answer ──────────────────────────────────────────────

  Future<DeviceSetting> _brightness() async {
    var answer = await _uiRead('appearance');
    return DeviceSetting(
      id: DeviceSettingId.brightness,
      noun: 'Theme',
      value: answer,
      provenance: answer == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: const ['light', 'dark'],
      atDefault: answer == 'light',
      command: 'xcrun simctl ui $udid appearance',
    );
  }

  Future<DeviceSetting> _textScale() async {
    var answer = await _uiRead('content_size');
    var scale = contentSizes[answer];
    return DeviceSetting(
      id: DeviceSettingId.textScale,
      noun: 'Text',
      value: answer,
      provenance: answer == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: contentSizes.keys.toList(),
      atDefault: answer == 'large',
      command: 'xcrun simctl ui $udid content_size',
      note: scale == null
          ? null
          : '$answer is ×${scale.toStringAsFixed(2)} at any size; iOS scales '
                'text linearly',
    );
  }

  Future<DeviceSetting> _highContrast() async {
    var answer = await _uiRead('increase_contrast');
    var value = switch (answer) {
      'enabled' => 'on',
      'disabled' => 'off',
      _ => null,
    };
    return DeviceSetting(
      id: DeviceSettingId.highContrast,
      noun: 'A11y',
      value: value,
      provenance: value == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.answered,
      options: const ['on', 'off'],
      atDefault: value == 'off',
      command: 'xcrun simctl ui $udid increase_contrast',
    );
  }

  /// `simctl ui <option>` with no argument, which is how these three report.
  ///
  /// Null for `unsupported` and `unknown` alike — the platform's own two ways
  /// of saying it will not answer, and both of them have to land on
  /// [DeviceProvenance.unknown] rather than on a default. An empty parse is an
  /// error, not an empty answer.
  Future<String?> _uiRead(String option) async {
    var result = await _run('xcrun', ['simctl', 'ui', udid, option]);
    if (result.exitCode != 0) return null;
    var answer = '${result.stdout}'.trim();
    if (answer.isEmpty || answer == 'unknown' || answer == 'unsupported') {
      return null;
    }
    return answer;
  }

  // ── the two that only echo ─────────────────────────────────────────────

  Future<DeviceSetting> _invertColors() async {
    var raw = await _defaultsRead([
      'com.apple.Accessibility',
      'InvertColorsEnabled',
    ]);
    // An absent key is not an unknown: the domain is the one iOS itself reads,
    // and nothing written means the platform default. It is still only an echo
    // of a file, which is what `written` says.
    var value = switch (raw) {
      null || '0' => 'off',
      _ => 'on',
    };
    return DeviceSetting(
      id: DeviceSettingId.invertColors,
      noun: 'A11y',
      value: value,
      provenance: DeviceProvenance.written,
      options: const ['on', 'off'],
      atDefault: value == 'off',
      command:
          'xcrun simctl spawn $udid defaults read com.apple.Accessibility '
          'InvertColorsEnabled',
      note:
          'As written: the simulator has no command that reports this one, so '
          'this is the value flutterware last wrote.',
    );
  }

  Future<DeviceSetting> _language() async {
    var raw = await _defaultsRead(['-g', 'AppleLanguages']);
    var languages = raw == null ? const <String>[] : parseAppleLanguages(raw);
    return DeviceSetting(
      id: DeviceSettingId.language,
      noun: 'Lang',
      value: languages.isEmpty ? null : languages.first,
      provenance: languages.isEmpty
          ? DeviceProvenance.unknown
          : DeviceProvenance.written,
      cost: DeviceCost.relaunchesApp,
      // There is no default language to be *at*, so anything read counts as
      // quiet. Caught by looking at the strip: with `atDefault` left false this
      // chip drew bold and bordered on a simulator nobody had touched, next to
      // four muted ones — a permanent false alarm, every session. Android can
      // say this properly, because there the default is *no per-app override*
      // and an empty list is exactly that; here the list is whatever the
      // machine was set up with, and flutterware remembers nothing that would
      // let it tell a value it set from one it found.
      atDefault: languages.isNotEmpty,
      // Every app on the simulator, not just this one — the opposite of
      // Android, where the same setting is per package.
      scope: DeviceScope.device,
      // The device's own preferred-language list, and **suggestions rather
      // than the whole set**: any BCP-47 tag can be written, and these are
      // only the ones already on the machine. No `clearLabel` — emptying
      // `AppleLanguages` is not "use the default", it hands the simulator a
      // language list with nothing in it.
      options: languages,
      openOptions: true,
      command: 'xcrun simctl spawn $udid defaults read -g AppleLanguages',
      // What the cost does not already say. The picker draws the relaunch
      // sentence from [DeviceCost.relaunchesApp] on every platform that has
      // it, so repeating it here put the same words twice in one card.
      note: 'Takes any BCP-47 tag, not only the ones the device already lists.',
    );
  }

  /// Moves a language to the front of the list, **keeping the rest of it**.
  ///
  /// `defaults write -array` replaces the array rather than adding to it, so
  /// the first draft's one-tag write deleted every other preferred language on
  /// the simulator — permanently, device-wide, and invisibly, because
  /// [_language] reads that same list back as the picker's suggestions. Set
  /// `fr-BE` on a machine listing `en-US, fr-BE` and `en-US` was gone from both
  /// the device and the only place that remembered it existed.
  ///
  /// Promoting rather than replacing is also what iOS's own Settings does when
  /// you drag a language up, so the list the app falls back through is the one
  /// the machine was set up with.
  Future<DeviceSetting> _promote(String value) async {
    var tag = value.trim();
    if (tag.isEmpty) {
      throw DeviceRefusal(
        'A language needs a BCP-47 tag, like `fr`, `fr-FR` or `ja`.',
      );
    }
    var raw = await _defaultsRead(['-g', 'AppleLanguages']);
    var current = raw == null ? const <String>[] : parseAppleLanguages(raw);
    var list = [tag, ...current.where((language) => language != tag)];
    await _defaultsWrite(['-g', 'AppleLanguages', '-array', ...list]);
    return _language();
  }

  /// The `defaults read -g AppleLanguages` list, in order.
  ///
  /// Its own function because the output is a plist fragment rather than a
  /// value — `(\n    "fr-FR"\n)` — and a single-entry list drops the quotes on
  /// some runtimes, so both spellings are parsed rather than one being assumed.
  static List<String> parseAppleLanguages(String raw) {
    var quoted = RegExp(r'"([^"]+)"').allMatches(raw);
    if (quoted.isNotEmpty) {
      return [for (var match in quoted) match.group(1)!];
    }
    return [
      for (var line in raw.split('\n'))
        if (line.trim().replaceAll(',', '') case var entry
            when entry.isNotEmpty && entry != '(' && entry != ')')
          entry,
    ];
  }

  Future<String?> _defaultsRead(List<String> args) async {
    var result = await _run('xcrun', [
      'simctl',
      'spawn',
      udid,
      'defaults',
      'read',
      ...args,
    ]);
    if (result.exitCode != 0) return null;
    var answer = '${result.stdout}'.trim();
    return answer.isEmpty ? null : answer;
  }

  Future<void> _defaultsWrite(List<String> args) async {
    var result = await _run('xcrun', [
      'simctl',
      'spawn',
      udid,
      'defaults',
      'write',
      ...args,
    ]);
    if (result.exitCode != 0) {
      throw DeviceRefusal(
        'The simulator refused the write: ${'${result.stderr}'.trim()}',
        command: 'xcrun simctl spawn $udid defaults write ${args.join(' ')}',
      );
    }
  }

  // ── the one the app answers ────────────────────────────────────────────

  DeviceSetting _orientation(({double width, double height})? size) {
    var value = size == null
        ? null
        : size.width > size.height
        ? 'landscape'
        : 'portrait';
    return DeviceSetting(
      id: DeviceSettingId.orientation,
      noun: 'Turn',
      value: value,
      provenance: value == null
          ? DeviceProvenance.unknown
          : DeviceProvenance.derived,
      cost: DeviceCost.takesFocus,
      options: const ['portrait', 'landscape'],
      atDefault: value == 'portrait',
      command: 'Simulator ▸ Device ▸ Rotate Left / Rotate Right',
      // Again, what the cost does not say: the picker draws the focus sentence
      // from [DeviceCost.takesFocus].
      note:
          'simctl cannot rotate a simulator or report its orientation. The '
          'value comes from the running app’s geometry, and rotating goes '
          'through the Simulator’s Device menu.',
    );
  }

  /// Rotate, then **check**.
  ///
  /// The one write in v1 that can report success and do nothing: measured
  /// twice, in both directions, a menu click against a Simulator that is not
  /// the front window returns the menu item exactly as it does on success and
  /// leaves the device where it was. So this activates the Simulator first,
  /// clicks, and then asks the app whether it turned — and refuses if it did
  /// not, rather than handing back a value nothing verified.
  Future<DeviceSetting> _rotate(String value, AppSizeReader? appSize) async {
    _require(value, const [
      'portrait',
      'landscape',
    ], DeviceSettingId.orientation);
    var before = await appSize?.call();
    if (before == null) {
      throw DeviceRefusal(
        'The simulator’s orientation is unknown: simctl cannot read it, and '
        'no running app reports its geometry. Rotation needs the app running.',
        command: 'Simulator ▸ Device ▸ Rotate Left',
      );
    }
    var current = before.width > before.height ? 'landscape' : 'portrait';
    if (current == value) return _orientation(before);

    // Left out of portrait, right out of landscape — the two turns that reach
    // the other state from where we are.
    var item = value == 'landscape' ? 'Rotate Left' : 'Rotate Right';
    var press =
        'tell application "System Events" to tell process "Simulator" to click '
        'menu item "$item" of menu 1 of menu bar item "Device" of menu bar 1';
    await _osascript('osascript', [
      '-e',
      'tell application "Simulator" to activate',
    ]);
    var click = await _osascript('osascript', ['-e', press]);
    if (click.exitCode != 0) {
      throw DeviceRefusal(
        'The Simulator refused to rotate: '
        '${'${click.stderr}'.trim()}',
        command: 'Simulator ▸ Device ▸ $item',
      );
    }

    // Poll rather than look once. The click returns before the device has
    // turned, and the same race on Android answered `landscape` 170ms after a
    // write that had in fact landed.
    var deadline = DateTime.now().add(const Duration(seconds: 2));
    var after = await appSize?.call();
    var turned = _turned(before, after);
    while (!turned && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      after = await appSize?.call();
      turned = _turned(before, after);
    }
    if (!turned) {
      throw DeviceRefusal(
        'The Simulator was asked to rotate and the app is still $current. The '
        'Simulator was probably not the front window (a menu click reports '
        'success either way). Bring it forward and try again.',
        command: 'Simulator ▸ Device ▸ $item',
      );
    }
    return _orientation(after);
  }

  static bool _turned(
    ({double width, double height}) before,
    ({double width, double height})? after,
  ) =>
      after != null &&
      (after.width > after.height) != (before.width > before.height);

  // ── the two refusals ───────────────────────────────────────────────────

  DeviceSetting _boldText() => const DeviceSetting.unavailable(
    id: DeviceSettingId.boldText,
    noun: 'A11y',
    reason:
        'No host command sets bold text on the iOS simulator. Writing '
        'BoldTextEnabled creates a key nothing reads: no Flutter app sees it, '
        'even after a relaunch.',
    command: 'Settings ▸ Accessibility ▸ Display & Text Size ▸ Bold Text',
  );

  DeviceSetting _disableAnimations() => DeviceSetting.unavailable(
    id: DeviceSettingId.disableAnimations,
    noun: 'A11y',
    reason: notDeliveredReason(platform, DeviceSettingId.disableAnimations),
    command: 'Settings ▸ Accessibility ▸ Motion ▸ Reduce Motion',
  );

  // ── plumbing ───────────────────────────────────────────────────────────

  Future<void> _simctl(List<String> args) async {
    var result = await _run('xcrun', ['simctl', ...args]);
    if (result.exitCode != 0) {
      throw DeviceRefusal(
        'simctl refused: ${'${result.stderr}'.trim()}',
        command: 'xcrun simctl ${args.join(' ')}',
      );
    }
  }

  void _require(String value, Iterable<String> options, DeviceSettingId id) {
    if (options.contains(value)) return;
    throw DeviceRefusal(
      '${id.name} on the iOS simulator takes ${options.join(', ')}, and '
      '"$value" is not one of them.',
    );
  }
}
