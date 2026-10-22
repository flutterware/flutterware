/// How the asset inspector writes itself into an address, and how it reads
/// itself back out.
///
/// Both directions in one file, for the same reason the catalog keeps them
/// together: the address is written by search, by the list, and by whoever
/// pastes one; it is read by the panel deciding what to show. Drift between the
/// two does not throw — it navigates you to a different asset.
///
/// The round trip is the contract, and [assetSegments] and [assetPlace] are
/// inverses with a test that says so.
library;

/// A place in the inspector: a package, and an asset inside it if one is named.
class AssetPlace {
  const AssetPlace(this.package, {this.assetKey});

  /// The workspace-relative package path — `.`, `fixtures/probe_app`.
  final String package;

  /// The asset key as the engine knows it — `assets/logo.png`, or
  /// `packages/flutter_scene/assets/royal_esplanade.png` for a dependency's.
  /// Null when the address names the package and stops there, which is where
  /// selecting the plugin off the rail leaves you.
  final String? assetKey;

  @override
  bool operator ==(Object other) =>
      other is AssetPlace &&
      other.package == package &&
      other.assetKey == assetKey;

  @override
  int get hashCode => Object.hash(package, assetKey);

  @override
  String toString() => 'AssetPlace($package${assetKey ?? ''})';
}

/// The address segments naming [package] and, if given, [assetKey].
///
/// The key is split on `/` rather than kept whole so the address stays
/// readable — `…/./assets/images/logo.png` instead of one percent-encoded
/// blob — while the package stays a single segment, since a package path may
/// itself contain slashes and the two must not run together.
List<String> assetSegments(String package, [String? assetKey]) => [
  package,
  if (assetKey != null && assetKey.isNotEmpty) ...assetKey.split('/'),
];

/// The inverse of [assetSegments].
///
/// Joining the tail back with `/` is exactly the undo of splitting it, so a
/// `packages/<name>/…` key survives however deep it is. Returns null for an
/// address that named no package at all.
AssetPlace? assetPlace(List<String> segments) {
  if (segments.isEmpty) return null;
  var key = segments.skip(1).join('/');
  return AssetPlace(segments.first, assetKey: key.isEmpty ? null : key);
}
