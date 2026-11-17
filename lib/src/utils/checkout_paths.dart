import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether [path] is [root] or under it, and not inside another checkout
/// nested below [root].
///
/// A linked git worktree can live inside the main checkout's directory, and
/// some clients make every worktree there. Containment alone would then give
/// the main checkout everything its worktrees hold. A directory between the
/// two that has a `.git` of its own, a worktree's file or a nested
/// repository's folder, is another checkout.
///
/// Reads nothing but whether those `.git` entries [exist], the disk's answer
/// unless a caller reads its files from somewhere else, so it suits the scans
/// that must not open sockets or start processes.
bool isInCheckout(
  String root,
  String path, {
  bool Function(String path) exists = _onDisk,
}) {
  if (!p.equals(root, path) && !p.isWithin(root, path)) return false;
  for (var dir = path; p.isWithin(root, dir); dir = p.dirname(dir)) {
    if (exists(p.join(dir, '.git'))) return false;
  }
  return true;
}

bool _onDisk(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;
