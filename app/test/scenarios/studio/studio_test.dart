import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware_app/src/demo/recorded_project.dart';
import 'package:flutterware_app/src/demo/recording.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:flutterware_app/src/splash/ui/variant_tile.dart';
import 'package:path/path.dart' as p;

/// The studio, driven by its own harness, over the recording
/// `tool/demo/record.dart` wrote.
///
/// What this buys is the thing every other project gets from scenarios and
/// the studio never had: a deterministic picture of each screen, kept run to
/// run, so a change to the rail or a panel shows up as a step that moved. The
/// project it opens is a recording rather than a checkout — no git, no
/// manifest subprocess, no scan of the disk — which is what makes the walk
/// repeatable under FakeAsync. See `lib/src/demo/recorded_project.dart`.
///
/// The file end of the recording, not the asset end: the harness runs under
/// FakeAsync, where a synchronous read lands and an asset fetch would not.
void main() {
  final recording = FileScenarioArtifacts(
    p.join(Directory.current.path, 'demo', 'fixture'),
  );

  scenario('Launcher icons of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell), shot: Shot('Home'));
    await s.tap('Launcher icon', shot: Shot('Launcher icons'));
    await s.tap('Themed icon', shot: Shot('The themed icon'));
    await s.tap('Assets', shot: Shot('Not recorded'));
  });

  /// The splash panel over the recorded files: every surface in both themes,
  /// read back from what the generator wrote, then one cell opened. The
  /// scan is the live one, run over files the recording holds in memory.
  scenario('Splash screen of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Splash screen', shot: Shot('Every surface'));
    // The picture is the tap target, not its caption: the third tile is
    // Android 12+ in the light theme.
    await s.tap(find.byType(SplashScreenBox).at(2), shot: Shot('A cell'));
  });

  /// The dependencies panel over the recorded resolution: what the demo app
  /// declares and what that pulls in, one opened to what pub.dev says, its
  /// changelog and what it weighs. Nothing runs `pub deps`, walks the pub
  /// cache or asks pub.dev — the recording is all three.
  scenario('Dependencies of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Dependencies', shot: Shot('The resolution'));
    await s.tap('flutter_native_splash', shot: Shot('A package'));
  });

  /// The Server panel over the recorded ring: the orders server's requests,
  /// one opened to its waterfall and its queries, and the listing whose
  /// queries the panel badges as an N+1. Nothing attaches to anything — the
  /// recording is the attachment.
  scenario('Server of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Server', shot: Shot('The requests'));
    await s.tap(
      const Target.containing('/orders/BL-1042'),
      shot: Shot('A request'),
    );
    // The second `SQL`: the dock has one for the whole server, the open
    // request another for its own queries.
    await s.tap(const Target.nth('SQL', 1), shot: Shot('Its queries'));
    // The list stays beside the open request, so the next one is a tap away.
    await s.tap(
      const Target.containing('/orders?today=1'),
      shot: Shot('The listing that asks once per row'),
    );
  });

  /// The translations panel over the recorded catalogs and export: every key
  /// with its English and its picture in place, one opened to its frame, the
  /// switch to French, and the filter to what French still lacks. The
  /// pictures are the export's own shots, read from the recording.
  scenario('Translations of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Translations', shot: Shot('The keys'));
    await s.tap('placeOrder', shot: Shot('A key in place'));
    // The first `fr`: the language switch in the filter row, before the open
    // key's own French row.
    await s.tap(const Target.nth('fr', 0), shot: Shot('In French'));
    await s.tap('Missing in fr', shot: Shot('What French still lacks'));
  });

  /// The store panel over the recorded export: a card per display class with
  /// its shots, the first of one class opened at the store's size, then the
  /// listing previewed as a store would show it, then the French set. The
  /// pictures are the export's own, read from the recording.
  scenario('Store screenshots of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Store', shot: Shot('The listing'));
    await s.tap(
      const Target.nth('Preview listing', 0),
      shot: Shot('Previewed'),
    );
    await s.tap(const Target.tooltip('Close'), shot: Shot('Back'));
  });

  /// The dev stack panel over the recorded script: the stack up, its logs,
  /// then torn down and brought back — each control answered by what the
  /// script printed for it, and the probe reporting the state that follows.
  scenario('Dev stack of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Orders server', shot: Shot('The stack, up'));
    // The first `Run` is the logs command; the console below fills with
    // what the script printed.
    await s.tap(const Target.nth('Run', 0), shot: Shot('Its logs'));
    await s.tap('Tear down', shot: Shot('Torn down'));
    // The button says `Done` for a second and a half after it succeeded;
    // waiting it out is what a person does before pressing it again.
    await s.wait(const Duration(seconds: 2));
    await s.tap('Bring up', shot: Shot('Back up'));
  });

  /// A scenario of the scenarios panel: the recorded run of the demo app's
  /// coffee shop, drawn by the studio, photographed by the harness. Opening a
  /// scenario runs it, and over a recording that run is a read — which is
  /// what lets this walk settle under FakeAsync.
  scenario('Scenarios of a recorded project', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Scenarios', shot: Shot('The suite'));
    await s.tap('Order a cappuccino', shot: Shot('A recorded run'));
    await s.tap(const Target.containing('1 · Welcome'), shot: Shot('A step'));
  });

  /// Around the run: the flow zoomed out to the whole walk and back in, and
  /// the device picker — a pick re-runs, and over a recording the run comes
  /// back as what was recorded, which the chip says.
  scenario('Looking around a recorded run', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Scenarios');
    await s.tap('Order a cappuccino', shot: Shot('The run'));
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out, shot: Shot('Zoomed out to the whole walk'));
    await s.tap(Icons.zoom_in, shot: Shot('Zoomed back in'));
    await s.tap('iPhone 16 (default)', shot: Shot('The device picker'));
    await s.tap(
      const Target.nth('iPhone SE', 0),
      shot: Shot('Picked another phone'),
    );
  });

  /// A step's page: the inspector over the recorded tree, every tab, the
  /// next step and the way back.
  scenario('Inspecting a recorded step', (s) async {
    var shell = recordedShell(recording: recording);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Scenarios');
    await s.tap('Order a cappuccino');
    await s.tap(const Target.containing('1 · Welcome'), shot: Shot('The step'));
    await s.tap(
      const Target.containing('Text("Brewline")'),
      shot: Shot('A widget picked in the tree'),
    );
    await s.tap('Semantics', shot: Shot('Semantics'));
    await s.tap('Texts', shot: Shot('Texts'));
    await s.tap('Events', shot: Shot('Events'));
    await s.tap(
      const Target.containing('2 · Menu'),
      shot: Shot('The next step'),
    );
    await s.tap(Icons.arrow_back, shot: Shot('Back to the flow'));
  });
}
