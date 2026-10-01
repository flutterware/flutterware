/// What a project says about which of its packages *is* the project, and which
/// picture stands for it.
///
/// Declared in `tool/flutterware.dart` like everything else:
///
/// ```dart
/// const webApp = Pkg('packages/web_app');
///
/// void main() => Flutterware.configure((fw) {
///   fw.identity(const ProjectIdentity(package: webApp, icon: 'logo.png'));
///   fw.use(Previews());
/// });
/// ```
///
/// Why a repository has to be asked. A user runs one flutterware window per
/// repository and several at once, and every window looks the same: the same
/// name, the same icon. What tells them apart has to come from the project, and
/// a monorepo has no obvious answer to give — one real repository holds a web
/// app, an admin app, a macOS utility and two plugin examples, all of them real.
/// Which one *is* the repository is a claim only the person who works there can
/// make.
///
/// So this is a declaration and not an inference. `fw init` may scaffold a
/// guess, because a first launch has to show something, but the guess lands in
/// this file where it can be read and corrected rather than staying a rule
/// nobody can see.
///
/// Deliberately not part of the launcher-icon plugin, which reads no config
/// and runs no generator on purpose — see `LauncherIconCore`. That plugin
/// reports what an operating system shows; this says what a window is. Hanging
/// one off the other would couple two things that answer different questions.
library;

import 'package.dart';

/// The package that stands for the whole repository, and its picture.
///
/// Both are required, and neither does anything without the other: [icon] is
/// what a window shows, and [package] is where that file is.
class ProjectIdentity {
  const ProjectIdentity({required this.package, required this.icon});

  /// The package [icon] is found in: the file is resolved against its root,
  /// and the tooltip over the window's picture names it.
  ///
  /// That is all it drives. Nothing reads the package's name or its launcher
  /// icon, so naming a package alone would declare nothing a window can show —
  /// which is why [icon] is required beside it.
  ///
  /// A [Pkg] rather than a path string, so it is the same value the plugins
  /// below it are configured with and a rename moves one constant.
  final Pkg package;

  /// The picture the window and the Dock show for this repository, relative
  /// to [package]'s root — `'logo.png'`, `'assets/brand/mark.png'`,
  /// `'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png'`.
  ///
  /// Named rather than found, which is what this field is for. The
  /// first version of this searched the declared package's platform directories
  /// for its best launcher icon, skipping any file whose bytes matched a
  /// `flutter create` default. It picked the Flutter logo for a real mobile app
  /// — one whose generator writes iOS and Android icons and leaves `macos/`
  /// alone — because the macOS icon there *was* the template's, written by an
  /// older Flutter than the one the hashes were taken from. A byte-exact list
  /// of upstream template files goes stale on upstream's schedule, and it goes
  /// stale silently — a window wearing the wrong face with nothing on screen to
  /// explain it.
  ///
  /// Naming the file cannot expire. It also lets a project point at the art it
  /// actually thinks of as its logo — the source image its icon generator reads
  /// — rather than at whichever generated platform variant happened to rank
  /// highest.
  ///
  /// Anything Flutter can decode works; a `.ico` does not, and neither does a
  /// path that is not there. Both are reported against the worktree rather than
  /// passed over: a declaration that went nowhere is a mistake, and naming the
  /// file is what makes it possible to point at.
  final String icon;

  Map<String, Object?> toJson() => {'package': package.path, 'icon': icon};

  /// Tolerant of everything except a wrong shape, like every other decoder
  /// that reads a manifest a previous version of flutterware wrote.
  ///
  /// A missing or non-string field is *no identity* rather than a throw: the
  /// worst this costs is a window that looks like every other window, which is
  /// exactly where the project started. Refusing to open it would be worse.
  ///
  /// Note this arm is mostly unreachable in practice — `tool/flutterware.dart`
  /// is Dart, so a config that omits a required argument fails to compile and is
  /// reported as the compile error it is, long before anything decodes.
  static ProjectIdentity? fromJson(Map<String, Object?> json) =>
      switch ((json['package'], json['icon'])) {
        (String path, String icon) when path.isNotEmpty && icon.isNotEmpty =>
          ProjectIdentity(package: Pkg(path), icon: icon),
        _ => null,
      };
}
