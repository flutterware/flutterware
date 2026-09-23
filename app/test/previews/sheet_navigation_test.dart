import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/previews_address.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_tree.dart';
import 'package:flutterware_app/src/previews/catalog_view.dart';
import 'package:flutterware_app/src/previews/preview_sheet.dart';

/// The tree selects, the sheet shows what was selected.
///
/// Two shapes were tried before this one and both were felt to be a mess. The
/// first had a heading on the sheet narrow the page to itself, invisibly, and
/// announce it with a filter icon — so it read as a filter having been applied
/// rather than as somewhere you had gone. The second dropped narrowing and made
/// a folder a *place on one long page*: the tree scrolled the sheet, the sheet
/// scrolled the tree's mark back, and a folder row folded and navigated from
/// one click. Nobody could tell what any gesture would do.
///
/// What is left is a sidebar and a content pane. A row picks what the pane
/// shows — one folder, or all of them — the chevron folds and does nothing
/// else, and nothing scrolls itself. The lost-your-place problem is solved by
/// the place being small: a folder is one screen.
void main() {
  CatalogEntry entry(String path, String symbol, {String? group}) =>
      CatalogEntry(
        path: path,
        symbol: symbol,
        annotation: "Preview(name: '$symbol')",
        name: symbol,
        group: group,
      );

  group('what a folder covers', () {
    test('a group branch covers the file its variants are declared in', () {
      var tree = buildCatalogTree([
        entry('demo/avatar.dart', 'members', group: 'Avatar'),
        entry('demo/avatar.dart', 'empty', group: 'Avatar'),
        entry('demo/other.dart', 'other'),
      ]);
      var avatar = tree.whereType<CatalogBranch>().single;

      expect(avatar.scopePath, 'demo/avatar.dart');
      expect(scopeCovers(avatar.scopePath, 'demo/avatar.dart'), isTrue);
      expect(scopeCovers(avatar.scopePath, 'demo/other.dart'), isFalse);
    });

    test('a directory branch covers everything below it', () {
      // The tree drops the directories every entry shares, so `team` is a
      // branch only because `loose.dart` sits outside it.
      var tree = buildCatalogTree([
        entry('demo/team/avatar.dart', 'a'),
        entry('demo/team/roster.dart', 'b'),
        entry('demo/loose.dart', 'c'),
      ]);
      var team = tree.whereType<CatalogBranch>().single;

      expect(team.scopePath, 'demo/team');
      expect(scopeCovers(team.scopePath, 'demo/team/avatar.dart'), isTrue);
      expect(scopeCovers(team.scopePath, 'demo/loose.dart'), isFalse);
    });

    test('and a name that merely starts the same is not inside it', () {
      expect(scopeCovers('demo/team', 'demo/teamwork/x.dart'), isFalse);
    });

    test('while no folder covers everything, which is All demos', () {
      expect(scopeCovers(null, 'anything/at/all.dart'), isTrue);
    });
  });

  group('a narrowed sheet', () {
    List<CatalogEntry> catalog() => [
      for (var g = 0; g < 6; g++)
        for (var i = 0; i < 3; i++)
          entry('demo/file$g.dart', 'e${g}_$i', group: 'Group $g'),
    ];

    List<PreviewSheetSection> sectionsFor(
      String? scope, {
      List<CatalogEntry>? of,
    }) => previewSheetSections(
      buildCatalogTree([
        for (var e in of ?? catalog())
          if (scopeCovers(scope, e.path)) e,
      ]),
      screenOf: (_) => const Size(400, 300),
      rootLabel: scopeHeading(scope),
    );

    test('holds one folder and nothing beside it', () {
      var sections = sectionsFor('demo/file2.dart');

      expect(sections.length, 1);
      expect(sections.single.label, 'Group 2');
      expect(sections.single.entries.length, 3);
    });

    test('and All demos holds every one of them', () {
      expect(sectionsFor(null).length, 6);
    });

    test('says which folder it is, even when the tree has dropped it', () {
      // [buildCatalogTree] drops the directories every entry shares, and for a
      // narrowed sheet that is the folder you are standing in — so a directory
      // of plain files came out as a row of tiles under no heading, hard
      // against the top of the pane. The folder next to it, whose entries had a
      // group, kept its branch and was named. One folder titled, the next not.
      var entries = [
        entry('demo/team/avatar.dart', 'a'),
        entry('demo/team/roster.dart', 'b'),
        entry('demo/loose.dart', 'c'),
      ];
      var sections = sectionsFor('demo/team', of: entries);

      expect(sections.single.label, 'team');
      expect(sections.single.entries.map((e) => e.name), ['a', 'b']);
    });

    test('and its subfolders come first, as they do in the tree', () {
      var entries = [
        entry('demo/team/avatar.dart', 'a'),
        entry('demo/team/roles/lead.dart', 'b'),
      ];

      expect(sectionsFor('demo/team', of: entries).map((s) => s.label), [
        'roles',
        'team',
      ]);
    });

    test('while All demos leaves its loose entries unnamed', () {
      // There is no folder to name them after — a rule stands in for the
      // heading, and inventing one would be inventing a group the catalog does
      // not have.
      var entries = [
        entry('demo/file0.dart', 'a', group: 'Group 0'),
        entry('demo/file0.dart', 'b', group: 'Group 0'),
        entry('demo/loose.dart', 'c'),
      ];

      expect(sectionsFor(null, of: entries).last.label, isNull);
    });
  });

  group('coming back from a demo', () {
    test('lands wherever you clicked, because there is no back', () {
      // There used to be a chevron over the stage that undid opening a demo,
      // and a memory of which tile it had been so the page could be put back
      // where it was. Both are gone: every way off a demo is a row in the tree
      // naming where you are going — its folder, or All demos — so there is
      // nothing to restore and nothing to remember.
      //
      // What made that affordable is narrowing. A folder is one screen, and the
      // folder a demo sits in is selected and open in the tree while it is on
      // the stage, so the way back is already in front of you and lands on a
      // page with the demo's own tile on it.
      var entries = [
        for (var i = 0; i < 4; i++)
          entry('demo/file0.dart', 'e$i', group: 'Group 0'),
      ];
      var sections = previewSheetSections(
        buildCatalogTree(entries),
        screenOf: (_) => const Size(400, 300),
      );

      expect(sections.single.entries.length, 4);
    });
  });

  group('the stage waits for the guest', () {
    // The guest paints one texture and switches which demo is in it, so for the
    // ~35–70ms a warm switch takes it still holds the previous demo. Whether
    // that is a glitch or the right thing to hold depends only on where the
    // click came from.
    test('holds the catalog rather than a demo nobody asked for', () {
      expect(
        stageHoldsGuest(
          guestEntryId: 'demo/a.dart#alpha',
          selectedEntryId: 'demo/b.dart#beta',
          alreadyHolding: false,
        ),
        isFalse,
      );
    });

    test('and lets go of it the moment the guest catches up', () {
      expect(
        stageHoldsGuest(
          guestEntryId: 'demo/b.dart#beta',
          selectedEntryId: 'demo/b.dart#beta',
          alreadyHolding: false,
        ),
        isTrue,
      );
    });

    test('but keeps the demo you were already looking at', () {
      // Hiding it here would be a blink on every entry-to-entry click, which is
      // the whole reason this is not a timer.
      expect(
        stageHoldsGuest(
          guestEntryId: 'demo/a.dart#alpha',
          selectedEntryId: 'demo/b.dart#beta',
          alreadyHolding: true,
        ),
        isTrue,
      );
    });

    test('and gives it up when the stage does', () {
      // The trip this exists to catch: leaving a demo has to clear the hold, or
      // the next click shows the stale texture again.
      expect(
        stageHoldsGuest(
          guestEntryId: 'demo/a.dart#alpha',
          selectedEntryId: null,
          alreadyHolding: true,
        ),
        isFalse,
      );
    });
  });
}
