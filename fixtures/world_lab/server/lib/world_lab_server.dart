/// The worlds lab's server: a coffee shop's pickup orders, in memory.
///
/// A library rather than only `bin/server.dart` so that a world script, which
/// lives in this package, can start it in-process with its edges swapped.
library;

export 'src/edges.dart' show PushService, ReportedPush, ReportedSms, SmsService;
export 'src/server.dart' show LabServer, menu, orderStatuses, startServer;
