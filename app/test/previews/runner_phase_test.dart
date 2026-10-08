import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/embedder/tester_phase.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';

/// The catalog's busy line while its tester host works. `onLog` carries the
/// host's narration *and* the guest's whole console, and this is what stands
/// between the two and a sidebar row.
void main() {
  Status? statusFor(String line) {
    var reading = readTesterPhase(line);
    return reading == null ? null : previewsRunnerStatus(reading);
  }

  test("the host says what it is doing in the rail's own register", () {
    expect(
      statusFor('[previews] compiling the harness'),
      const Status.info('compiling the previews…'),
    );
    expect(
      statusFor('[previews] the asset bundle changed'),
      const Status.info('rebuilding the assets…'),
    );
    expect(
      statusFor(
        '[tester] The Dart VM service is listening on http://127.0.0.1:1/',
      ),
      const Status.info('starting the previews…'),
    );
    expect(
      statusFor('[previews] the harness exited (255)'),
      const Status.info('restarting the previews…'),
    );
    expect(
      statusFor('[previews] reloading 1 edited source(s)'),
      const Status.info('reloading 1 file…'),
    );
    expect(
      statusFor('[previews] reloading 3 edited source(s)'),
      const Status.info('reloading 3 files…'),
    );
  });

  test('the harness answering ends the wait rather than describing one', () {
    // The line this whole pass is about. It used to land on the row verbatim
    // — and stay there, because the warm tester is started for thumbnails as
    // often as for an audit and only the audit clears the line afterwards.
    expect(
      readTesterPhase(
        '[tester] flutterware previews harness ready — 133 entries, '
        'fonts: MaterialIcons',
      )?.phase,
      TesterPhase.ready,
    );
    expect(
      statusFor(
        '[tester] flutterware previews harness ready — 133 entries, '
        'fonts: MaterialIcons',
      ),
      isNull,
    );
  });

  test('the guest talking to its own console reaches no row', () {
    // Not "nothing is happening" — an unread line arrives *during* whatever
    // phase is running — so the caller leaves the line where it is rather
    // than clearing it. Either way none of this becomes a status.
    expect(readTesterPhase('[tester] flutter: building the avatar tile'), null);
    expect(readTesterPhase('[tester] '), isNull);
    expect(readTesterPhase('some line nothing prefixed'), isNull);
  });
}
