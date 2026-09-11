import 'package:flutterware/plugins.dart';
import 'package:json_annotation/json_annotation.dart';

part 'icon_results.g.dart';

/// `inventory` — every launcher icon in a package, and what the OS does with it.
///
/// Carries [findings] beside the files rather than leaving a caller to derive
/// them, because the interesting answer is rarely "what is on disk". It is
/// "which of these does the OS never show", and only the project's own wiring
/// answers that.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class IconInventoryResult implements PluginResult {
  IconInventoryResult({
    required this.package,
    required this.address,
    required this.iosCatalog,
    this.flavor,
    this.flavors = const [],
    this.iconBundles = const [],
    this.roles = const [],
    this.findings = const [],
  });

  final String package;

  /// The address of this package, pasteable back into the shell.
  final String address;

  /// Which flavor this reports on, or null for the default.
  final String? flavor;

  /// Every flavor the package has, and what declares it.
  final List<IconFlavorEntry> flavors;

  /// `none`, `appIconSet`, `iconComposer` or `both`. Three-valued because a
  /// project can legitimately have no per-size PNGs — Xcode generates them from
  /// an Icon Composer bundle at build time — and reporting "no iOS icons" there
  /// would be wrong.
  final String iosCatalog;

  final List<String> iconBundles;

  final List<IconRoleEntry> roles;
  final List<IconFindingEntry> findings;

  @override
  Map<String, Object?> toJson() => _$IconInventoryResultToJson(this);
}

/// A flavor, and the evidence for it.
///
/// [sources] rather than a bare name because "configured but never generated"
/// and "generated for Android only" are the two states worth acting on, and a
/// list of strings can express neither.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class IconFlavorEntry {
  IconFlavorEntry({required this.name, this.sources = const []});

  final String name;

  /// Some of `config`, `androidSourceSet`, `iosCatalog`. Never empty — a flavor
  /// is here because something on disk named it.
  final List<String> sources;

  Map<String, Object?> toJson() => _$IconFlavorEntryToJson(this);
}

/// One role, and every file that plays it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class IconRoleEntry {
  IconRoleEntry({
    required this.role,
    required this.label,
    required this.platform,
    required this.treatment,
    required this.mask,
    this.since,
    this.referenced,
    this.color,
    this.files = const [],
  });

  /// The address vocabulary — `android.adaptive-foreground`.
  final String role;

  final String label;
  final String platform;

  /// What the OS does to the pixels: `asAuthored`, `whiteSilhouette` or
  /// `desaturateAndTint`.
  final String treatment;

  /// The shape the OS clips to, if any.
  final String mask;

  /// The OS version this role begins to mean anything at.
  final String? since;

  /// Whether the project's own wiring points at this. Null off Android, where
  /// there is nothing to read and presence is the whole answer.
  final bool? referenced;

  /// The adaptive background when it is a colour rather than an image.
  final String? color;

  final List<IconFileEntry> files;

  Map<String, Object?> toJson() => _$IconRoleEntryToJson(this);
}

/// One file, as its header describes it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class IconFileEntry {
  IconFileEntry({
    required this.path,
    required this.modified,
    this.width,
    this.height,
    this.hasAlpha = false,
    this.density,
    this.icoFrames = const [],
    this.declaredSize,
  });

  /// Worktree-relative rather than package-relative: an agent's tools are
  /// scoped to the repo, not to one package inside it.
  final String path;

  final String modified;

  final int? width;
  final int? height;

  final bool hasAlpha;

  /// `xxhdpi`, `3x`, or null where the platform has one size.
  final String? density;

  /// The sizes an `.ico` packs. Empty for every other format.
  final List<int> icoFrames;

  /// What an Apple asset catalog claims this file's size is, when it disagrees
  /// with [width].
  final int? declaredSize;

  Map<String, Object?> toJson() => _$IconFileEntryToJson(this);
}

/// One thing worth saying about what was found.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class IconFindingEntry {
  IconFindingEntry({required this.tone, required this.message, this.role});

  final String tone;
  final String message;
  final String? role;

  Map<String, Object?> toJson() => _$IconFindingEntryToJson(this);
}
