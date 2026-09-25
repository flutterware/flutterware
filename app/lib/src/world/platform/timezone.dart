import 'dart:io';

import '../guest_platform.dart';

/// `flutter_timezone` — the device's time zone — answered with the Mac's, as
/// a simulator does. What a world could change per person later.
void answerTimezone(GuestPlatform platform) {
  platform.methods('flutter_timezone', {
    'getLocalTimezone': (_) => _local(),
    'getAvailableTimezones': (_) => [_local()],
  });
}

/// `/etc/localtime` points into the zone database; the zone is the path
/// below it.
String _local() {
  try {
    var target = File('/etc/localtime').resolveSymbolicLinksSync();
    var at = target.indexOf('zoneinfo/');
    if (at >= 0) return target.substring(at + 'zoneinfo/'.length);
  } on FileSystemException {
    // No link to follow: fall through.
  }
  return 'UTC';
}
