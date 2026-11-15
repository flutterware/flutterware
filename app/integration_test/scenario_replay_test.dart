@Tags(['browser'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/scenario_replay_protocol.dart';
import 'package:flutterware_app/src/scenarios/replay_build.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:test/test.dart';

/// The scenario replay page, built from the probe app's replay probes and
/// asked for steps in a real browser, the way an embedding page asks.
///
/// `FW_REPLAY_BUILD` names a build to check instead of building one. Chrome
/// is puppeteer's own, as in `web_demo_test.dart`.
void main() {
  late String output;
  late ScenarioReplayBuild? built;
  late HttpServer server;
  late Browser browser;
  late Page page;
  const file = 'replay_probes/replay_probes.dart';

  setUpAll(() async {
    var appRoot = Directory.current.path;
    var probeApp = p.normalize(p.join(appRoot, '..', 'fixtures', 'probe_app'));
    var given = Platform.environment['FW_REPLAY_BUILD'];
    if (given != null) {
      output = p.normalize(p.absolute(given));
      built = null;
    } else {
      output = p.join(probeApp, 'build', 'scenario_replay');
      // `<flutter>/bin/cache/dart-sdk/bin/dart`: the SDK running this test.
      var flutterRoot = p.dirname(
        p.dirname(p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable)))),
      );
      var flutter = p.join(
        flutterRoot,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      );
      built = await ScenarioReplayBuilder(
        flutterExecutable: flutter,
        packageRoot: probeApp,
      ).build(files: [file], output: output, onOutput: print);
    }
    server = await shelf_io.serve(
      _serve(output),
      InternetAddress.loopbackIPv4,
      0,
    );
    var chrome = await downloadChrome();
    browser = await puppeteer.launch(
      executablePath: chrome.executablePath,
      noSandboxFlag: Platform.isLinux,
    );
    page = await browser.newPage();
    await page.setViewport(DeviceViewport(width: 900, height: 700));
    await page.goto(
      'http://${server.address.host}:${server.port}/embed.html',
      wait: Until.load,
    );
    await page.evaluate<Object?>('() => window.ready');
  });

  tearDownAll(() async {
    await browser.close();
    await server.close(force: true);
  });

  /// Asks the page in the iframe for a step, as an embedding page does.
  Future<Map<String, Object?>> ask(ReplayRequest request) async {
    var answer = await page.evaluate<String>(
      '(request) => window.ask(request)',
      args: [request.toJson()],
    );
    return jsonDecode(answer) as Map<String, Object?>;
  }

  test('the index names the steps and the keys they show', () {
    var index =
        built?.index ??
        ReplayIndex.fromJson(
          jsonDecode(File(p.join(output, replayIndexFile)).readAsStringSync())
              as Map<String, Object?>,
        );
    expect([for (var scenario in index.scenarios) scenario.scenario]..sort(), [
      'Breaks a build, then goes on',
      'Fails after it ends',
      'Greets',
      'Reads the disk',
    ]);
    expect(index.keys.keys, ['probe/greeting']);
    // Two probes fail under `flutter test` too, and the index is written
    // all the same.
    if (built case var built?) expect(built.testsPassed, isFalse);
  });

  test('the page says what it can replay once it is ready', () async {
    var scenarios = await page.evaluate<List<Object?>>(
      '() => window.scenarios',
    );
    expect(scenarios, hasLength(4));
  });

  test(
    'a step is shown with the draft in place, fitted to the frame',
    () async {
      var result = await ask(
        const ReplayRequest(
          file: file,
          scenario: 'Greets',
          position: '#2',
          drafts: {'probe/greeting': 'Bonjour à tous'},
          locate: ['probe/greeting'],
        ),
      );
      expect(result['reached'], isTrue);
      expect(result['ok'], isTrue, reason: '${result['failures']}');
      expect(result['steps'], 2);
      // The app's semantics reach the page's own, so the words on screen can
      // be read back.
      var words = await page.evaluate<String>(
        '() => window.frame().document.querySelector("flt-semantics-host")'
        '?.textContent ?? ""',
      );
      expect(words, contains('Bonjour à tous'));
      // The page keeps the frame's size: the device's never leaks into it.
      var view = await page.evaluate<List<Object?>>(
        '() => { const v = window.frame().document.querySelector('
        '"flutter-view"); return [v.clientWidth, v.clientHeight]; }',
      );
      expect(view, [320, 420]);
      // Where the draft is drawn, inside the device.
      var box = (result['boxes']! as List).single as Map;
      expect(box['key'], 'probe/greeting');
      expect(box['width'] as num, greaterThan(0));
      expect(
        (box['left'] as num) + (box['width'] as num),
        lessThanOrEqualTo(result['width']! as num),
      );
    },
  );

  test('the step is drawn on the page, not only reached', () async {
    var result = await ask(
      const ReplayRequest(file: file, scenario: 'Greets', position: '#2'),
    );
    expect(result['reached'], isTrue);
    // What the browser shows in the frame: the app's scaffold and its words,
    // over the page's grey. A page that reaches the step and draws nothing
    // is all grey. The frame is drawn on the browser's next frame, so this
    // waits for it.
    var frame = await page.$('#replay');
    var counted = (drawn: 0.0, dark: 0);
    for (var tries = 0; tries < 20; tries++) {
      var shot = img.decodePng(Uint8List.fromList(await frame.screenshot()))!;
      var drawn = 0;
      var dark = 0;
      for (var pixel in shot) {
        if (pixel.r != 0xec || pixel.g != 0xec || pixel.b != 0xec) drawn++;
        if (pixel.luminance < 100) dark++;
      }
      counted = (drawn: drawn / (shot.width * shot.height), dark: dark);
      if (counted.drawn > 0.3 && counted.dark > 20) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(counted.drawn, greaterThan(0.3), reason: 'the scaffold');
    expect(counted.dark, greaterThan(20), reason: 'the greeting');
  });

  test('the page leaves focus where the embedding page has it', () async {
    var focused = await page.evaluate<String>('''async () => {
      const input = document.getElementById("draft");
      input.focus();
      await window.ask({file: "$file", scenario: "Greets", position: "#2"});
      await new Promise((r) => setTimeout(r, 500));
      return document.activeElement.id;
    }''');
    expect(focused, 'draft');
  });

  test('a fixture that reads the disk fails, and says why', () async {
    var result = await ask(
      const ReplayRequest(
        file: file,
        scenario: 'Reads the disk',
        position: '#1',
      ),
    );
    expect(result['reached'], isFalse);
    expect(result['ok'], isFalse);
    expect('${result['failures']}', contains('dart:io'));
  });

  test('a failure after the scenario ends is a failure', () async {
    var result = await ask(
      const ReplayRequest(
        file: file,
        scenario: 'Fails after it ends',
        position: '#9',
      ),
    );
    expect(result['reached'], isFalse);
    expect(result['ok'], isFalse);
    expect('${result['failures']}', contains('The tear-down failed'));
  });

  test('an error before the step is reported with the step', () async {
    var result = await ask(
      const ReplayRequest(
        file: file,
        scenario: 'Breaks a build, then goes on',
        position: '#2',
      ),
    );
    expect(result['reached'], isTrue);
    expect(result['ok'], isFalse);
    expect('${result['failures']}', contains('The build failed'));
  });

  test('the page still answers after all that', () async {
    var result = await ask(
      const ReplayRequest(file: file, scenario: 'Greets', position: '#1'),
    );
    expect(result['ok'], isTrue, reason: '${result['failures']}');
  });
}

/// The build, with the headers WebAssembly needs for threads, and a page
/// that embeds it the way an editor would.
shelf.Handler _serve(String output) {
  var files = createStaticHandler(output, defaultDocument: 'index.html');
  return (request) async {
    var response = request.url.path == 'embed.html'
        ? shelf.Response.ok(_embed, headers: {'content-type': 'text/html'})
        : await files(request);
    return response.change(
      headers: {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
      },
    );
  };
}

const _embed =
    '''
<!DOCTYPE html>
<html><body style="margin:0">
<iframe id="replay" src="./" style="width:320px;height:420px;border:0"></iframe>
<input id="draft">
<script>
const frame = document.getElementById('replay');
const waiting = {};
let next = 0;
window.frame = () => frame.contentWindow;
window.ready = new Promise((resolve) => {
  window.addEventListener('message', (event) => {
    const data = event.data;
    if (data.type === '${ReplayMessages.ready}') {
      window.scenarios = data.scenarios;
      resolve(true);
    }
    if (data.type === '${ReplayMessages.result}') {
      waiting[data.id](JSON.stringify(data));
    }
  });
});
window.ask = (request) => new Promise((resolve) => {
  const id = 'r' + (++next);
  waiting[id] = resolve;
  frame.contentWindow.postMessage(
    {type: '${ReplayMessages.run}', id, ...request}, '*');
});
</script>
</body></html>
''';
