/// The run guest: what a generated run entrypoint wraps around an app's
/// `main` so the app can be inspected *and driven* over the VM service —
/// tree, logs, errors, images, and the `ext.flutterware.act` transaction.
///
/// For generated code, not for projects to import directly. The one API an
/// app or routing package touches is [GuestDrive.navigator], the `navigate`
/// verb's registration point.
library;

export 'src/drive/guest_drive.dart' show GuestDrive;
export 'src/drive/run_guest.dart' show RunGuestBinding, runGuest;
