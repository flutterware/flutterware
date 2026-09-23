import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import 'clipboard_watcher.dart';
import 'downloader_io.dart';
import 'link.dart';
import 'links_source_io.dart';
import 'links_source_web.dart';
import 'personal_settings_storage_io.dart';

class FigmaUserConfig {
  final String? apiToken;
  final String? linksPath;

  FigmaUserConfig({required this.apiToken, required this.linksPath});
}

class FigmaService {
  final FigmaUserConfig userConfig;
  late FigmaDownloader downloader;
  final FigmaLinks _links;
  final _linksFromCode = <Object, List<String>>{};
  final _allLinksFromCode = <String>{};
  final _listenedPaths = <String, ValueStream>{};
  final _images = <String, Future<ImageProvider>>{};
  final FigmaLinksSource source;
  final PersonalSettingsStorage? personalSettingsStorage;
  final PersonalSettings personalSettings;
  final clipboardWatcher = ClipboardWatcher();

  FigmaService._({
    required this.userConfig,
    required FigmaLinks initialLinks,
    required this.source,
    required this.downloader,
    required this.personalSettingsStorage,
    required this.personalSettings,
  }) : _links = initialLinks;

  static Future<FigmaService> load(FigmaUserConfig config) async {
    FigmaDownloader client;
    PersonalSettingsStorage? personalSettingsStorage;
    PersonalSettings? initialSettings;
    FigmaLinksSource linksSource;
    if (!kIsWeb) {
      client = FigmaDownloaderIO(FigmaCache(Directory('.figma/cache')));
      personalSettingsStorage = PersonalSettingsStorageIO(
        File('.figma/personal_settings.json'),
      );
      linksSource = FigmaLinksSourceIO(
        File(config.linksPath ?? 'figma_links.json'),
      );

      initialSettings = await personalSettingsStorage.read();
    } else {
      client = FigmaDownloaderWeb();
      linksSource = FigmaLinksSourceWeb();
    }

    var initialLinks = await linksSource.read();

    return FigmaService._(
      userConfig: config,
      source: linksSource,
      downloader: client,
      initialLinks: initialLinks,
      personalSettingsStorage: personalSettingsStorage,
      personalSettings: initialSettings ?? PersonalSettings(),
    );
  }

  List<FigmaLink> _findLinksForPath(String path) {
    var links = _links.links[path];
    return [
      ...?links,
      ..._allLinksFromCode.map((l) => FigmaLink(l, isFromCode: true)),
    ];
  }

  ValueStream<List<FigmaLink>> linksForPath(String path) {
    var stream = ValueStream(_findLinksForPath(path));

    stream.onListen = () {
      _listenedPaths[path] = stream;
    };

    stream.onCancel = () {
      stream.dispose();
      _listenedPaths.remove(path);
    };

    return stream;
  }

  bool get canAddLink => source.canSave;

  void addLink(String path, String uri) {
    var list = _links.links[path] ??= [];
    var link = FigmaLink(uri);
    if (!list.contains(link)) {
      list.add(link);
    }

    var listener = _listenedPaths[path];
    if (listener != null) {
      listener.add(_findLinksForPath(path));
    }

    if (source.canSave) {
      source.save(_links);
    }
  }

  Future<ImageProvider> imageProviderFor(FigmaLink link) {
    return _images[link.uri] ??= downloader.readFigmaScreenshot(
      link,
      credentials: personalSettings.credentials ?? _userConfigCredentials,
    );
  }

  FigmaCredentials? get _userConfigCredentials {
    if (userConfig.apiToken case var token? when token.isNotEmpty) {
      return FigmaCredentials(token);
    }
    return null;
  }

  bool get canSaveFigmaToken => personalSettingsStorage != null;

  void setFigmaToken(FigmaCredentials? credentials) {
    personalSettings.credentials = credentials;
    personalSettingsStorage?.save(personalSettings);

    _images.clear();
    _notifyAllLinkListeners();
  }

  void _notifyAllLinkListeners() {
    for (var e in _listenedPaths.entries) {
      var listener = e.value;
      var path = e.key;
      listener.add(_findLinksForPath(path));
    }
  }

  // TODO: in web we cannot
  bool get canRefreshFromSource => source.canSave;

  void forceRefreshLink(FigmaLink link) {
    downloader.clearCacheForLink(link);
    _images.remove(link.uri);
    _notifyAllLinkListeners();
  }

  void forceRefreshAllLinks() {
    downloader.clearCache();
    _images.clear();
    _notifyAllLinkListeners();
  }

  bool canDeleteLink(FigmaLink link) => source.canSave && !link.isFromCode;

  void deleteLink(String path, FigmaLink link) {
    var list = _links.links[path];
    if (list == null) return;
    list.remove(link);

    if (list.isEmpty) {
      _links.links.remove(path);
    }

    var listener = _listenedPaths[path];
    if (listener != null) {
      listener.add(_findLinksForPath(path));
    }

    if (source.canSave) {
      source.save(_links);
    }
  }

  void addLinksFromCode(Object ref, List<String> urls) {
    _linksFromCode[ref] = urls;
    _refreshLinksFromCode();
  }

  void removeLinksFromCode(Object ref) {
    _linksFromCode.remove(ref);
    _refreshLinksFromCode();
  }

  void _refreshLinksFromCode() {
    //TODO(xha): refactor: remove the _allLinksFromCode and compute it later
    // And keep a reference to the Figma widget to determine whether it's "path/TreeEntry"
    var allLinksFromCode = _linksFromCode.values.expand((e) => e).toSet();
    if (!const SetEquality().equals(allLinksFromCode, _allLinksFromCode)) {
      _allLinksFromCode
        ..clear()
        ..addAll(allLinksFromCode);
      _notifyAllLinkListeners();
    }
  }

  void dispose() {
    clipboardWatcher.dispose();
  }
}

abstract class FigmaDownloader {
  Future<ImageProvider> readFigmaScreenshot(
    FigmaLink url, {
    FigmaCredentials? credentials,
  });
  void clearCacheForLink(FigmaLink link);
  void clearCache() {}
}

abstract class FigmaLinksSource {
  bool get canSave;
  void save(FigmaLinks data);
  Future<FigmaLinks> read();
}

class FigmaLinks {
  final Map<String, List<FigmaLink>> links;

  FigmaLinks(this.links);

  factory FigmaLinks.fromJson(Map<String, Object?> json) {
    return FigmaLinks(
      json.cast<String, List>().map(
        (k, v) => MapEntry(k, v.map((e) => FigmaLink.fromJson(e)).toList()),
      ),
    );
  }

  Map<String, Object?> toJson() => links;
}

class FigmaCredentials {
  final String token;

  FigmaCredentials(this.token) : assert(token.isNotEmpty);

  factory FigmaCredentials.fromJson(Map<String, dynamic> json) {
    return FigmaCredentials(json['token']! as String);
  }

  Map<String, dynamic> toJson() => {'token': token};
}

class PersonalSettings {
  FigmaCredentials? credentials;

  PersonalSettings({this.credentials});

  factory PersonalSettings.fromJson(Map<String, dynamic> json) {
    var credentials = json['credentials'];
    return PersonalSettings(
      credentials: credentials != null
          ? FigmaCredentials.fromJson(credentials as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {'credentials': credentials};
}

abstract class PersonalSettingsStorage {
  Future<PersonalSettings?> read();
  void save(PersonalSettings settings);
}
