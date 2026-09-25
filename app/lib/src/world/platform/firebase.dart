import '../guest_platform.dart';

/// `firebase_core` — its Pigeon host APIs — with no Firebase behind them.
///
/// `initializeApp` answers with the options the app passed, as the native SDK
/// does once it has configured itself from them, so an app that initialises
/// with explicit options — as one with several environments does — starts.
/// There is no `GoogleService-Info.plist` in a world to configure from, so
/// `initializeCore` knows only the apps initialised since, and
/// `optionsFromResource` refuses.
///
/// Answered because the app waits on it: `initializeApp` is awaited before
/// `runApp` in most apps that use Firebase at all, and nothing draws until
/// it returns.
void answerFirebaseCore(GuestPlatform platform) {
  const api = 'dev.flutter.pigeon.firebase_core_platform_interface';
  // `CoreInitializeResponse`, tag 130: name, options, data collection,
  // each plugin's constants.
  var apps = <String, PigeonValue>{};
  platform
    ..pigeon('$api.FirebaseCoreHostApi', {
      'initializeApp': (arguments) {
        var name = arguments[0]! as String;
        return apps[name] = PigeonValue(130, [
          name,
          arguments[1],
          false,
          <Object?, Object?>{},
        ]);
      },
      'initializeCore': (_) => apps.values.toList(),
      'optionsFromResource': (_) => throw GuestPlatformError(
        'no-options',
        'A world has no GoogleService-Info.plist; pass the options.',
      ),
    })
    ..pigeon('$api.FirebaseAppHostApi', {
      'setAutomaticDataCollectionEnabled': (_) => null,
      'setAutomaticResourceManagementEnabled': (_) => null,
      'delete': (arguments) {
        apps.remove(arguments[0]);
        return null;
      },
    });
}
