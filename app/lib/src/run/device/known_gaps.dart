import 'device_settings.dart';

/// Settings a platform accepts, reads straight back, and never delivers to a
/// Flutter app.
///
/// These are **measurements, not predictions**, which is the only reason a
/// constant is allowed to stand in for the app's own answer. Each was written
/// on a real device, read back clean from the store or the owning command, and
/// then not seen in the running app's `MediaQuery` — before *and* after a
/// relaunch. Every entry names the session that found it.
///
/// A setting in here is **refused** on that platform rather than offered with a
/// warning, because half a control is worse than none: the platform where a
/// designer is checking reduce motion is the platform where the control would
/// have to work.
///
/// This is the stand-in, and it is meant to be replaced. When the guest grows
/// an extension that reports its own `MediaQuery`, the app answers for itself
/// and these become `DeviceSettingState.notObserved` rows drawn live —
/// including the case a constant can never catch, which is *your app ignores
/// it* as distinct from *the platform drops it*.
const knownNotDelivered = <(String, DeviceSettingId)>{
  // `defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`
  // reads back as `1` and `MediaQuery.disableAnimations` stays false, across a
  // relaunch. No other key for it exists anywhere on the device — a grep of
  // every domain found only the one this write created. S-D1, 2026-08-24.
  ('ios-simulator', DeviceSettingId.disableAnimations),

  // `settings put secure high_text_contrast_enabled 1` reads back as `1` and
  // `MediaQuery.highContrast` stays false. Android publishes no high-contrast
  // flag the engine forwards. S-D2, 2026-08-24.
  ('android', DeviceSettingId.highContrast),
};

bool isKnownNotDelivered(String platform, DeviceSettingId id) =>
    knownNotDelivered.contains((platform, id));

/// The sentence a [knownNotDelivered] row draws, in the voice the rest of the
/// refusals use: what was tried, what came back, and when it was measured — so
/// a reader can tell a decision from a guess and knows what to re-run if they
/// think it has changed.
String notDeliveredReason(String platform, DeviceSettingId id) =>
    switch ((platform, id)) {
      ('ios-simulator', DeviceSettingId.disableAnimations) =>
        'The simulator accepts Reduce Motion and reads it back, but no Flutter '
            'app sees it, even after a relaunch. Nothing on the iOS simulator '
            'sets it in a way the engine passes on.',
      ('android', DeviceSettingId.highContrast) =>
        'Android accepts high_text_contrast_enabled and reads it back, but no '
            'Flutter app sees it: Android publishes no high-contrast flag the '
            'engine passes on.',
      _ => 'This platform accepts ${id.name}, but no Flutter app sees it.',
    };
