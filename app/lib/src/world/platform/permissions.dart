import '../guest_platform.dart';

/// `permission_handler` — what the person has allowed — answered as a fresh
/// install whose person allows whatever the app asks for: nothing is granted
/// until the app asks, and then everything asked for is. Kept per person,
/// since a permission is a fact about one device.
///
/// A person who refuses is the device as an input, which a world will say
/// through its script; until then this is the path a flow is written for.
void answerPermissions(GuestPlatform platform) {
  var granted = <int>{};
  platform.methods('flutter.baseflow.com/permissions/methods', {
    'checkPermissionStatus': (permission) =>
        granted.contains(permission) ? _granted : _denied,
    'checkServiceStatus': (_) => _enabled,
    'requestPermissions': (permissions) {
      var asked = (permissions! as List).cast<int>();
      granted.addAll(asked);
      return {for (var permission in asked) permission: _granted};
    },
    'shouldShowRequestPermissionRationale': (_) => false,
    'openAppSettings': (_) => true,
  });
}

// `PermissionStatus` and `ServiceStatus` by index, as the plugin sends them.
const _denied = 0;
const _granted = 1;
const _enabled = 1;
