import 'package:clock/clock.dart';

/// How long ago [at] was, in the shortest form that is still true.
///
/// One wording, because an age is part of what a reading *means* and two
/// surfaces disagreeing about how to say "a minute" would read as two
/// different facts. Null in, null out — the caller has nothing to date.
String? ageOf(DateTime? at, {DateTime? now}) {
  if (at == null) return null;
  // Through `package:clock`, so a scenario of a panel that prints an age — the
  // studio's own, over a recording — reads the same age every day it runs.
  var elapsed = (now ?? clock.now()).difference(at);
  if (elapsed.inSeconds < 10) return 'just now';
  if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}s ago';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}
