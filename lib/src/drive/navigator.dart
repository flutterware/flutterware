/// The `navigate` verb's registration point: the handler a routing system
/// installs so a drive agent jumps straight to a screen, or null when the app
/// declares none and `navigate` refuses.
///
/// A file of its own, with no imports, because a routing package registers
/// here from inside the app it routes. `GuestDrive` is the public name for
/// this slot and forwards to it; the rest of the drive layer around it pulls
/// in `package:flutter_test` through the resolver, which no app should compile
/// in for the sake of one static.
void Function(String route)? driveNavigator;
