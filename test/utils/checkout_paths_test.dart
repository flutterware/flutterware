import 'dart:io';

import 'package:flutterware/src/utils/checkout_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String repo;

  setUp(() {
    var base = Directory.systemTemp.createTempSync('fw_checkout_paths');
    addTearDown(() => base.deleteSync(recursive: true));
    repo = p.join(base.resolveSymbolicLinksSync(), 'repo');
    Directory(p.join(repo, '.git')).createSync(recursive: true);
    Directory(p.join(repo, 'server_pkg')).createSync();
    var linked = Directory(p.join(repo, '.worktrees', 'feature'))
      ..createSync(recursive: true);
    File(p.join(linked.path, '.git')).writeAsStringSync('gitdir: elsewhere');
    Directory(p.join(linked.path, 'server_pkg')).createSync();
  });

  test('the checkout itself and a package inside it are in it', () {
    expect(isInCheckout(repo, repo), isTrue);
    expect(isInCheckout(repo, p.join(repo, 'server_pkg')), isTrue);
  });

  test('a worktree nested inside the checkout is not in it', () {
    var linked = p.join(repo, '.worktrees', 'feature');
    expect(isInCheckout(repo, linked), isFalse);
    expect(isInCheckout(repo, p.join(linked, 'server_pkg')), isFalse);
  });

  test('the nested worktree is in itself', () {
    var linked = p.join(repo, '.worktrees', 'feature');
    expect(isInCheckout(linked, p.join(linked, 'server_pkg')), isTrue);
  });

  test('a path outside the checkout is not in it', () {
    expect(isInCheckout(repo, p.dirname(repo)), isFalse);
  });

  test('a path that is gone counts by containment alone', () {
    expect(isInCheckout(repo, p.join(repo, 'deleted', 'pkg')), isTrue);
  });
}
