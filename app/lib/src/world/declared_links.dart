import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// The links a Flutter app says it opens: the custom URL schemes it registers
/// and the web hosts it claims as universal links (iOS, macOS) or app links
/// (Android), read off the project's own platform files.
///
/// This is what picks, among the URLs in a message, the one the app will take.
/// A mail can list two store badges before the link that matters, so the
/// first URL is not the answer.
///
/// It answers for the host, never the path. An app claims a host and then
/// narrows it — Android with `pathPrefix` and its siblings, Apple in the
/// association file the host itself serves — and only the first half is in
/// the project. A value only a build can resolve is left out rather than
/// matched literally: Xcode resolves `$(APP_SCHEME)`, Gradle `${linkHost}`
/// and the resource merger `@string/link_host`, and none of them runs here.
final class DeclaredLinks {
  const DeclaredLinks({this.schemes = const {}, this.hosts = const {}});

  /// Reads [projectRoot]'s iOS, macOS and Android project files. Never
  /// throws: a missing or unreadable file declares nothing.
  ///
  /// Every Android source set is read — `main` and each flavor or build type
  /// beside it — so the answer is the union across flavors rather than what
  /// one build merges.
  static DeclaredLinks read(String projectRoot) {
    var schemes = <String>{};
    var hosts = <String>{};

    for (var platform in ['ios', 'macos']) {
      for (var file in _files(p.join(projectRoot, platform, 'Runner'))) {
        var name = p.basename(file.path);
        if (name.startsWith('Info') && name.endsWith('.plist')) {
          schemes.addAll(_urlSchemes(file));
        } else if (name.endsWith('.entitlements')) {
          hosts.addAll(_associatedDomains(file));
        }
      }
    }

    var sourceSets = p.join(projectRoot, 'android', 'app', 'src');
    for (var sourceSet in _directories(sourceSets)) {
      var manifest = File(p.join(sourceSet.path, 'AndroidManifest.xml'));
      _readManifest(manifest, schemes: schemes, hosts: hosts);
    }

    return DeclaredLinks(
      schemes: Set.unmodifiable(schemes),
      hosts: Set.unmodifiable(hosts),
    );
  }

  /// Custom URL schemes, lowercase — never http or https.
  final Set<String> schemes;

  /// Web hosts the app claims, lowercase; a leading `*.` is a wildcard for
  /// subdomains.
  ///
  /// The wildcard does not cover the domain itself: Android matches
  /// `*.example.test` as a suffix that starts with the dot, so an app wanting
  /// both declares both.
  final Set<String> hosts;

  bool get isEmpty => schemes.isEmpty && hosts.isEmpty;

  /// Whether [link] would open in the app: its scheme is one of [schemes], or
  /// it is http(s) on one of [hosts].
  bool claims(String link) {
    var uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.hasScheme) return false;
    var scheme = uri.scheme.toLowerCase();

    if (_webSchemes.contains(scheme)) {
      var host = uri.host.toLowerCase();
      if (host.isEmpty) return false;
      return hosts.any((claimed) => _hostCovers(claimed.toLowerCase(), host));
    }
    return schemes.any((claimed) => claimed.toLowerCase() == scheme);
  }
}

const _webSchemes = {'http', 'https'};

final _schemePattern = RegExp(r'^[a-z][a-z0-9+.-]*$');

bool _hostCovers(String claimed, String host) => claimed.startsWith('*.')
    ? host.endsWith(claimed.substring(1))
    : host == claimed;

/// `CFBundleURLTypes` → each type's `CFBundleURLSchemes`.
Iterable<String> _urlSchemes(File file) sync* {
  var types = _valueOf(_plistDict(file), 'CFBundleURLTypes');
  if (types == null || types.name.local != 'array') return;
  for (var type in types.childElements) {
    if (type.name.local != 'dict') continue;
    for (var raw in _strings(_valueOf(type, 'CFBundleURLSchemes'))) {
      if (_scheme(raw) case var scheme? when !_webSchemes.contains(scheme)) {
        yield scheme;
      }
    }
  }
}

/// The `applinks:` entries of `com.apple.developer.associated-domains`,
/// without the service prefix or a `?mode=developer` suffix.
Iterable<String> _associatedDomains(File file) sync* {
  var dict = _plistDict(file);
  var domains = _valueOf(dict, 'com.apple.developer.associated-domains');
  for (var entry in _strings(domains)) {
    var value = entry.trim();
    if (!value.toLowerCase().startsWith('applinks:')) continue;
    var domain = value.substring('applinks:'.length).split('?').first;
    if (_host(domain) case var host?) yield host;
  }
}

/// The `VIEW` intent filters of one manifest.
///
/// Android combines every `<data>` of a filter, so a scheme on one element
/// pairs with a host on another: `exampleapp`, `https` and `go.example.test`
/// on three elements of one filter claim `go.example.test` on the web and
/// `exampleapp` as a scheme.
void _readManifest(
  File file, {
  required Set<String> schemes,
  required Set<String> hosts,
}) {
  var document = _parseXml(file);
  if (document == null) return;

  for (var filter in document.findAllElements('intent-filter')) {
    var views = filter
        .findElements('action')
        .any(
          (action) =>
              action.getAttribute('android:name') ==
              'android.intent.action.VIEW',
        );
    if (!views) continue;

    var filterSchemes = <String>{};
    var filterHosts = <String>{};
    for (var data in filter.findElements('data')) {
      if (_scheme(data.getAttribute('android:scheme')) case var scheme?) {
        filterSchemes.add(scheme);
      }
      if (_host(data.getAttribute('android:host')) case var host?) {
        filterHosts.add(host);
      }
    }

    for (var scheme in filterSchemes) {
      if (_webSchemes.contains(scheme)) {
        hosts.addAll(filterHosts);
      } else {
        schemes.add(scheme);
      }
    }
  }
}

/// [raw] trimmed and lowercased, or null when it is empty or only a build
/// could say what it is.
String? _literal(String? raw) {
  var value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (value.contains(r'$(') || value.contains(r'${')) return null;
  if (value.startsWith('@')) return null;
  return value.toLowerCase();
}

String? _scheme(String? raw) {
  var scheme = _literal(raw);
  if (scheme == null || !_schemePattern.hasMatch(scheme)) return null;
  return scheme;
}

/// A host, or `*.` and a host. Any other `*` is a pattern
/// [DeclaredLinks.claims] cannot match, so it is dropped rather than kept as
/// a host nothing reaches.
String? _host(String? raw) {
  var host = _literal(raw);
  if (host == null) return null;
  var rest = host.startsWith('*.') ? host.substring(2) : host;
  if (rest.isEmpty || rest.contains('*')) return null;
  return host;
}

Iterable<String> _strings(XmlElement? array) sync* {
  if (array == null || array.name.local != 'array') return;
  for (var element in array.childElements) {
    if (element.name.local == 'string') yield element.innerText;
  }
}

/// The top-level `<dict>` of an XML property list, or null when [file] is
/// absent, binary, unreadable or not a property list.
XmlElement? _plistDict(File file) {
  var document = _parseXml(file);
  if (document == null) return null;
  var root = document.rootElement;
  if (root.name.local != 'plist') return null;
  return root.getElement('dict');
}

/// Parses [file], or null when it is absent, unreadable, a binary plist, or
/// not XML — a file being edited is briefly malformed, and that is not a
/// reason to lose what the other files declare.
XmlDocument? _parseXml(File file) {
  try {
    var bytes = file.readAsBytesSync();
    if (_isBinaryPlist(bytes)) return null;
    return XmlDocument.parse(utf8.decode(bytes));
  } on Exception {
    return null;
  }
}

bool _isBinaryPlist(List<int> bytes) {
  const magic = 'bplist';
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

List<File> _files(String directory) =>
    _entries(directory).whereType<File>().toList();

List<Directory> _directories(String directory) =>
    _entries(directory).whereType<Directory>().toList();

List<FileSystemEntity> _entries(String directory) {
  try {
    return Directory(directory).listSync();
  } on FileSystemException {
    return const [];
  }
}

/// The element after `<key>[key]</key>` in a plist `<dict>`.
XmlElement? _valueOf(XmlElement? dict, String key) {
  if (dict == null) return null;
  var children = dict.childElements.toList();
  for (var i = 0; i < children.length - 1; i++) {
    var child = children[i];
    if (child.name.local == 'key' && child.innerText.trim() == key) {
      return children[i + 1];
    }
  }
  return null;
}
