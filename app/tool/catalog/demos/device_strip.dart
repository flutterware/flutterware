/// The run cockpit's device strip — the shipping widget, over a device that is
/// not there.
///
/// Every preview below wires the **real** `SimctlDeviceSettings` or
/// `AdbDeviceSettings` to a scripted `RunDeviceProcess`, the way the dev-stack
/// demos wire a real core to a scripted probe. So the wording in every picker,
/// every refusal and every provenance footnote is the backend's own rather than
/// a copy that can drift from it, and pressing `Set` runs the real write and
/// the real re-read — which is the protocol worth looking at: the reply is what
/// the device says *now*, never an echo of what was asked.
///
/// Designed in `docs/superpowers/specs/2026-08-24-run-device-strip-design.md`,
/// measured first in `2026-08-24-run-device-tab-capability-findings.md`. The
/// scripted outputs below are the real bytes those measurements captured on
/// 2026-08-24, against an iPhone 17 Pro on iOS 26.2 and an API 35 emulator.
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/run/device/device_settings.dart';
import 'package:flutterware_app/src/run/device/adb_settings.dart';
import 'package:flutterware_app/src/run/device/simctl_settings.dart';
import 'package:flutterware_app/src/run/device_strip.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

const _udid = 'A97ABCFD-A7B4-4C4F-8169-6F3403394F55';
const _serial = 'emulator-5554';
const _package = 'com.example.app';

// ── the previews ─────────────────────────────────────────────────────────────

/// The two v1 targets and the states the anatomy has to hold, stacked. Stacked
/// rather than behind a picker, per the house rule: a state nobody selects is a
/// state nobody sees.
@Preview(name: 'Device strip', group: 'Run cockpit', wrapper: wrapInAppTheme)
Widget deviceStrip() => const _Stack();

@Preview(
  name: 'Device strip · dark',
  group: 'Run cockpit',
  wrapper: wrapInDarkTheme,
)
Widget deviceStripDark() => const _Stack();

/// The same strips at 360, where the fold is what there is to judge.
///
/// The fold is measured — a `LayoutBuilder` and a `TextPainter` over the styles
/// the chips draw with — so this is the rendering that says whether the
/// measurer and the widget agree. A chip that elides, or a bar that overflows,
/// means they have drifted.
@Preview(
  name: 'Device strip · narrow',
  group: 'Run cockpit',
  wrapper: wrapInAppTheme,
)
Widget deviceStripNarrow() => const _Stack(width: 360);

/// Where the cost lives, and the whole argument for the strip not being a row
/// of switches.
///
/// The pickers, open — which a screenshot of the strip cannot show, because a
/// popover only exists while something holds it open. Measured costs the strip
/// has to be able to state: *relaunches the app* (locale on the simulator),
/// *takes your focus* (rotation there, which silently does nothing without it),
/// and *ends the run* — which is why permission revoke is not a control here at
/// all.
@Preview(
  name: 'Device strip · the cost',
  group: 'Run cockpit',
  wrapper: wrapInAppTheme,
)
Widget deviceStripCost() => const _Pickers();

@Preview(
  name: 'Device strip · the cost, dark',
  group: 'Run cockpit',
  wrapper: wrapInDarkTheme,
)
Widget deviceStripCostDark() => const _Pickers();

/// The rule the direction exists for, drawn: the controls sit **above** the
/// picture rather than on a tab that replaces it, so the result of pressing one
/// is in the frame underneath. The grey block stands in for the Screen pane's
/// live screenshot.
@Preview(
  name: 'Device strip · in situ',
  group: 'Run cockpit',
  wrapper: wrapInAppTheme,
)
Widget deviceStripInSitu() => const _InSitu();

// ── the cases ────────────────────────────────────────────────────────────────

class _Stack extends StatelessWidget {
  const _Stack({this.width});

  final double? width;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(FwSpacing.xl),
    children: [
      _Case(
        'iOS simulator · the ordinary day',
        'Nothing has been touched. Every value is the platform default, so '
            'every chip is muted and the bar reads as quiet — which is what '
            'makes one that has been touched read as loud without adding a '
            'colour. Live: change one and it stops being quiet.',
        width: width,
        device: _Simulator(),
      ),
      _Case(
        'iOS simulator · four axes moved',
        'Values the device answered with, read back from the command that owns '
            'each setting — never from the last thing asked. '
            '`accessibility-large` is iOS’s own word rather than a multiplier: '
            'the ladder is named on iOS and a curve on Android, so each '
            'platform keeps its own vocabulary.',
        width: width,
        device: _Simulator(
          appearance: 'dark',
          contentSize: 'accessibility-large',
          landscape: true,
          languages: ['fr-FR', 'en-US'],
        ),
      ),
      _Case(
        'Android emulator · a locale that belongs to the app',
        '`cmd locale set-app-locales` is scoped to the package, live, and reads '
            'back — so the chip says whose it is. Text size shows the raw '
            'device setting rather than a multiplier, because Android’s is a '
            'curve: 2.0 is ×1.86 at 14sp and ×1.00 at 100sp.',
        width: width,
        device: _Emulator(
          night: true,
          fontScale: '1.5',
          landscape: true,
          animationScale: '0.0',
          locales: ['fr-FR'],
        ),
      ),
      _Case(
        'Android emulator · the ordinary day',
        'Six of the eight settings here have a command that owns them and '
            'reports them when asked, and rotation costs nothing and steals no '
            'focus. High contrast is the one refusal, and it is a row rather '
            'than an absence: Android accepts the flag, reads it straight back, '
            'and no Flutter app sees it.',
        width: width,
        device: _Emulator(),
      ),
      _Case(
        'The disagreement',
        'Nothing in v1 produces this. Every disagreement measured so far is '
            'refused on the platform that has it, because half a control is '
            'worse than none — this is what the anatomy holds for the guest '
            'extension that reads the app’s own MediaQuery, so that landing it '
            'moves no furniture. Amber and a sentence, because the state is '
            'permanent rather than pending.',
        width: width,
        device: _Simulator(
          appearance: 'dark',
          invertColors: '1',
          languages: ['fr-FR', 'en-US'],
        ),
        recolour: _notObserved,
      ),
      _Case(
        'Asked, and not yet answered',
        'The window between a write returning and the next read completing. On '
            'both v1 targets every shipped write is live, so it is milliseconds '
            'and usually invisible. A dot, not a spinner: a spinner that never '
            'stops is how a permanent disagreement gets read as a slow one.',
        width: width,
        device: _Simulator(appearance: 'dark'),
        recolour: _asked,
      ),
      _Case(
        'A target with no backend',
        'macOS, web and both physical kinds. There are no rows to draw, so the '
            'strip is one sentence — and it is drawn rather than hidden, '
            'because a control that vanishes reads as an oversight and the '
            'reason is the useful half.',
        width: width,
        device: null,
        notice:
            'A physical iPhone answers to devicectl, which sets orientation '
            'and nothing else here. The rest are Settings on the device.',
      ),
    ],
  );
}

/// One case: the argument above it, the strip below, live.
class _Case extends StatefulWidget {
  const _Case(
    this.title,
    this.body, {
    required this.device,
    this.width,
    this.notice,
    this.recolour,
  });

  final String title;
  final String body;

  /// Null for a target with no backend at all.
  final _Device? device;
  final double? width;
  final String? notice;

  /// Bends the backend's own answer into a state no v1 backend produces. Named
  /// for what it is, and used exactly twice — every other case is what the real
  /// code returns for the scripted device.
  final List<DeviceSetting> Function(List<DeviceSetting>)? recolour;

  @override
  State<_Case> createState() => _CaseState();
}

class _CaseState extends State<_Case> {
  List<DeviceSetting>? _settings;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    var device = widget.device;
    var settings = await device?.settings.read(appSize: device.appSize);
    if (!mounted) return;
    setState(
      () => _settings = widget.recolour?.call(settings ?? []) ?? settings,
    );
  }

  Future<void> _set(DeviceSettingId id, String value) async {
    var device = widget.device;
    if (device == null) return;
    try {
      await device.settings.write(id, value, appSize: device.appSize);
    } on DeviceRefusal {
      // Swallowed here; the cockpit shows it in the error pane. What is worth
      // looking at in a preview is the re-read below either way, which is what
      // a refused write leaves the chip on.
    }
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var strip = DeviceStrip(
      settings: _settings ?? const [],
      notice: widget.notice,
      onSet: widget.device == null ? null : _set,
    );
    // Unlabelled, for the in-situ preview: there the strip is the thing being
    // shown in place and an argument above it would be a caption inside a
    // window.
    if (widget.title.isEmpty) return strip;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: context.type.sectionLabel),
          const Gap(FwSpacing.xxs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(
              widget.body,
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
          ),
          const Gap(FwSpacing.md),
          DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: colors.line)),
            child: widget.width == null
                ? strip
                : SizedBox(width: widget.width, child: strip),
          ),
        ],
      ),
    );
  }
}

/// The one state the backends cannot report and the anatomy has to hold.
List<DeviceSetting> _notObserved(List<DeviceSetting> settings) => [
  for (var setting in settings)
    if (setting.id == DeviceSettingId.invertColors)
      // The device really does have it on — the script holds the key and the
      // backend read it back. Only the *state* is bent, which is the one fact
      // no v1 backend can supply.
      setting.copyWith(state: DeviceSettingState.notObserved)
    else
      setting,
];

List<DeviceSetting> _asked(List<DeviceSetting> settings) => [
  for (var setting in settings)
    if (setting.id == DeviceSettingId.language)
      setting.copyWith(
        value: 'fr-FR',
        atDefault: false,
        state: DeviceSettingState.asked,
      )
    else
      setting,
];

/// Every picker, open, side by side.
class _Pickers extends StatefulWidget {
  const _Pickers();

  @override
  State<_Pickers> createState() => _PickersState();
}

class _PickersState extends State<_Pickers> {
  List<DeviceChip> _ios = const [];
  List<DeviceChip> _android = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    var simulator = _Simulator(contentSize: 'accessibility-large');
    var emulator = _Emulator(
      fontScale: '1.5',
      invertColors: true,
      locales: ['fr-FR'],
    );
    var ios = await simulator.settings.read(appSize: simulator.appSize);
    var android = await emulator.settings.read(appSize: emulator.appSize);
    if (!mounted) return;
    setState(() {
      _ios = deviceChips(ios);
      _android = deviceChips(android);
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(FwSpacing.xl),
    child: Wrap(
      spacing: FwSpacing.xl,
      runSpacing: FwSpacing.xl,
      children: [
        _Picker('iOS · locale, costs the app', _ios, 'Lang'),
        _Picker('iOS · rotation, costs your focus', _ios, 'Turn'),
        _Picker('iOS · text size, a named ladder', _ios, 'Text'),
        _Picker('Android · locale, free and per-app', _android, 'Lang'),
        _Picker('Android · the flags, and a refusal', _android, 'A11y'),
        _Picker('iOS · the flags, and two refusals', _ios, 'A11y'),
      ],
    ),
  );
}

class _Picker extends StatelessWidget {
  const _Picker(this.title, this.chips, this.noun);

  final String title;
  final List<DeviceChip> chips;
  final String noun;

  @override
  Widget build(BuildContext context) {
    var chip = chips.where((c) => c.noun == noun).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: context.type.sectionLabel),
        const Gap(FwSpacing.sm),
        if (chip == null)
          const SizedBox(width: 288, height: 60)
        else
          DeviceSheet(
            children: [
              DevicePicker(chip: chip, onSet: (_, _) {}, onDone: () {}),
            ],
          ),
      ],
    );
  }
}

class _InSitu extends StatelessWidget {
  const _InSitu();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          child: Row(
            spacing: FwSpacing.lg,
            children: [
              for (var (label, current) in const [
                ('Screen', true),
                ('Steps', false),
                ('Logs', false),
                ('Network', false),
                ('App', false),
                ('Knobs', false),
              ])
                Text(
                  label,
                  style: context.type.caption.copyWith(
                    color: current ? colors.ink : colors.mut,
                    fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
            ],
          ),
        ),
        _Case(
          '',
          '',
          device: _Simulator(
            appearance: 'dark',
            contentSize: 'accessibility-large',
            languages: ['fr-FR', 'en-US'],
          ),
        ),
        Expanded(
          child: Container(
            color: colors.bg,
            alignment: Alignment.center,
            child: Container(
              width: 200,
              height: 420,
              decoration: BoxDecoration(
                color: colors.panel2,
                border: Border.all(color: colors.line),
              ),
              alignment: Alignment.center,
              child: Text(
                'the app’s own pixels',
                style: context.type.caption.copyWith(color: colors.mut3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── the devices that are not there ───────────────────────────────────────────

/// A scripted target: the state a real device holds, and the real backend
/// reading and writing it through a `RunDeviceProcess` that interprets the
/// handful of commands that backend knows.
///
/// Stateful rather than a table of canned answers, and that is the point: a
/// write here goes through the shipping code path and the re-read after it
/// reports what the script now holds — so the preview exercises the readback
/// protocol instead of illustrating it.
abstract class _Device {
  DeviceSettings get settings;

  /// What the run's own tree walk supplies in the studio. Here it answers from
  /// the scripted device's own orientation, which is the seam that makes an
  /// iOS rotation checkable at all.
  Future<({double width, double height})?> appSize();
}

/// An iPhone 17 Pro on iOS 26.2, in `simctl`'s own vocabulary.
class _Simulator implements _Device {
  _Simulator({
    String appearance = 'light',
    String contentSize = 'large',
    String increaseContrast = 'disabled',
    this.invertColors = '0',
    this.landscape = false,
    List<String> languages = const ['en-US', 'fr-BE'],
  }) : _ui = {
         'appearance': appearance,
         'content_size': contentSize,
         'increase_contrast': increaseContrast,
       },
       _languages = [...languages];

  final Map<String, String> _ui;
  String invertColors;
  List<String> _languages;
  bool landscape;

  @override
  late final DeviceSettings settings = SimctlDeviceSettings(
    udid: _udid,
    run: _run,
  );

  @override
  Future<({double width, double height})?> appSize() async =>
      landscape ? (width: 874.0, height: 402.0) : (width: 402.0, height: 874.0);

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    var line = '$executable ${arguments.join(' ')}';
    // The Simulator's Device ▸ Rotate menu, clicked through System Events. On a
    // real one this is the write that can report success and do nothing, which
    // is why the backend polls the app's geometry afterwards rather than
    // trusting the click — so the scripted device turns, and the poll finds it.
    if (line.contains('Rotate')) {
      landscape = !landscape;
      return _ok();
    }
    if (line.contains('to activate')) return _ok();

    var ui = arguments.indexOf('ui');
    if (ui >= 0 && executable == 'xcrun') {
      var option = arguments[ui + 2];
      if (arguments.length > ui + 3) {
        _ui[option] = arguments[ui + 3];
        return _ok();
      }
      // `unknown` and `unsupported` are values here, not errors — both have to
      // reach the backend as themselves.
      return _ok(_ui[option] ?? 'unknown');
    }

    if (line.contains('defaults write -g AppleLanguages')) {
      _languages = [
        arguments.last,
        ..._languages.where((l) => l != arguments.last),
      ];
      return _ok();
    }
    if (line.contains('defaults read -g AppleLanguages')) {
      // A plist fragment rather than a value, quotes and all — the shape the
      // backend's parser was written against.
      return _ok('(\n${_languages.map((l) => '    "$l"').join(',\n')}\n)');
    }
    if (line.contains('defaults write com.apple.Accessibility')) {
      invertColors = arguments.last == 'true' ? '1' : '0';
      return _ok();
    }
    if (line.contains('defaults read com.apple.Accessibility')) {
      // `defaults read` exits non-zero for a key that was never written, and
      // the absence is the answer rather than an unknown.
      return invertColors == '0' ? _fail() : _ok(invertColors);
    }
    return _ok();
  }
}

/// An API 35 emulator, in `adb`'s.
class _Emulator implements _Device {
  _Emulator({
    this.night = false,
    this.fontScale = '1.0',
    this.landscape = false,
    this.invertColors = false,
    this.animationScale = '1.0',
    List<String> locales = const [],
  }) : _locales = [...locales];

  bool night;
  String fontScale;
  bool landscape;
  bool invertColors;
  String animationScale;
  List<String> _locales;

  @override
  late final DeviceSettings settings = AdbDeviceSettings(
    serial: _serial,
    adb: '/fake/sdk/platform-tools/adb',
    package: _package,
    run: _run,
  );

  @override
  Future<({double width, double height})?> appSize() async => null;

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    var line = arguments.join(' ');

    if (line.contains('cmd uimode night')) {
      var value = arguments.last;
      if (value == 'yes' || value == 'no') {
        night = value == 'yes';
        return _ok();
      }
      // `Night mode: yes` — a sentence, not a value.
      return _ok('Night mode: ${night ? 'yes' : 'no'}');
    }
    if (line.contains('am get-config')) {
      // The dashes are load-bearing: `-long-` and `-notround-` sit in the same
      // string, so the backend matches `-port-` and `-land-` with theirs.
      return _ok(
        'config: en-rUS-ldltr-sw411dp-w411dp-h842dp-normal-long-notround'
        '-lowdr-nowidecg-${landscape ? 'land' : 'port'}-notnight-560dpi',
      );
    }
    if (line.contains('shell settings put')) {
      var key = arguments[arguments.length - 2];
      var value = arguments.last;
      switch (key) {
        case 'font_scale':
          fontScale = value;
        case 'user_rotation':
          landscape = value == '1';
        case 'accessibility_display_inversion_enabled':
          invertColors = value == '1';
        case 'transition_animation_scale':
        case 'window_animation_scale':
        case 'animator_duration_scale':
          animationScale = value;
      }
      return _ok();
    }
    if (line.contains('shell settings get')) {
      // An unset key prints the *string* `null`, which is not `0` and must not
      // be mistaken for it.
      return _ok(switch (arguments.last) {
        'font_scale' => fontScale,
        'accelerometer_rotation' => '0',
        'accessibility_display_inversion_enabled' => invertColors ? '1' : '0',
        'transition_animation_scale' => animationScale,
        _ => 'null',
      });
    }
    if (line.contains('cmd locale set-app-locales')) {
      var tag = arguments.last;
      _locales = tag.isEmpty ? [] : [tag];
      return _ok();
    }
    if (line.contains('cmd locale get-app-locales')) {
      return _ok(
        'Locales for $_package for user 0 are [${_locales.join(',')}]',
      );
    }
    return _ok();
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');
ProcessResult _fail() => ProcessResult(0, 1, '', 'does not exist');
