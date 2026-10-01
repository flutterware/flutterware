// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'protocol.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SelectRequest _$SelectRequestFromJson(Map<String, dynamic> json) =>
    SelectRequest(
      (json['requestId'] as num).toInt(),
      json['id'] as String,
      full: json['full'] as bool? ?? false,
      ifChanged: json['ifChanged'] as bool? ?? false,
    );

Map<String, dynamic> _$SelectRequestToJson(SelectRequest instance) =>
    <String, dynamic>{
      'requestId': instance.requestId,
      'id': instance.id,
      'full': instance.full,
      'ifChanged': instance.ifChanged,
    };

ShownRequest _$ShownRequestFromJson(Map<String, dynamic> json) =>
    ShownRequest(json['id'] as String);

Map<String, dynamic> _$ShownRequestToJson(ShownRequest instance) =>
    <String, dynamic>{'id': instance.id};

HostRequest _$HostRequestFromJson(Map<String, dynamic> json) =>
    HostRequest((json['requestId'] as num).toInt());

Map<String, dynamic> _$HostRequestToJson(HostRequest instance) =>
    <String, dynamic>{'requestId': instance.requestId};

DaemonReady _$DaemonReadyFromJson(Map<String, dynamic> json) => DaemonReady(
  sessionId: json['sessionId'] as String,
  assetsDir: json['assetsDir'] as String,
  icuData: json['icuData'] as String,
  coldCompile: _millis.fromJson((json['coldCompile'] as num).toInt()),
  entries: (json['entries'] as List<dynamic>)
      .map((e) => CatalogEntry.fromJson(e as Map<String, dynamic>))
      .toList(),
  quarantined:
      (json['quarantined'] as List<dynamic>?)
          ?.map((e) => QuarantinedEntry.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  reused: json['reused'] as bool? ?? false,
  timings:
      (json['timings'] as Map<String, dynamic>?)?.map(
        (k, e) => MapEntry(k, (e as num).toInt()),
      ) ??
      const {},
  diagnostics:
      (json['diagnostics'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  seed: json['seed'] == null
      ? null
      : SeedReport.fromJson(json['seed'] as Map<String, dynamic>),
  warmStart: json['warmStart'] as bool? ?? false,
);

Map<String, dynamic> _$DaemonReadyToJson(DaemonReady instance) =>
    <String, dynamic>{
      'sessionId': instance.sessionId,
      'assetsDir': instance.assetsDir,
      'icuData': instance.icuData,
      'coldCompile': _millis.toJson(instance.coldCompile),
      'reused': instance.reused,
      'timings': instance.timings,
      'entries': instance.entries.map((e) => e.toJson()).toList(),
      'quarantined': instance.quarantined.map((e) => e.toJson()).toList(),
      'diagnostics': instance.diagnostics,
      'seed': instance.seed?.toJson(),
      'warmStart': instance.warmStart,
    };

SeedReport _$SeedReportFromJson(Map<String, dynamic> json) => SeedReport(
  packages: (json['packages'] as num).toInt(),
  path: json['path'] as String,
);

Map<String, dynamic> _$SeedReportToJson(SeedReport instance) =>
    <String, dynamic>{'packages': instance.packages, 'path': instance.path};

DaemonProgress _$DaemonProgressFromJson(Map<String, dynamic> json) =>
    DaemonProgress(
      phase: json['phase'] as String,
      done: json['done'] as bool,
      elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
    );

Map<String, dynamic> _$DaemonProgressToJson(DaemonProgress instance) =>
    <String, dynamic>{
      'phase': instance.phase,
      'done': instance.done,
      'elapsedMs': instance.elapsedMs,
    };

QuarantinedEntry _$QuarantinedEntryFromJson(Map<String, dynamic> json) =>
    QuarantinedEntry(
      entry: CatalogEntry.fromJson(json['entry'] as Map<String, dynamic>),
      error: json['error'] as String,
    );

Map<String, dynamic> _$QuarantinedEntryToJson(QuarantinedEntry instance) =>
    <String, dynamic>{
      'entry': instance.entry.toJson(),
      'error': instance.error,
    };

CatalogChanged _$CatalogChangedFromJson(Map<String, dynamic> json) =>
    CatalogChanged(
      entries: (json['entries'] as List<dynamic>)
          .map((e) => CatalogEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      quarantined:
          (json['quarantined'] as List<dynamic>?)
              ?.map((e) => QuarantinedEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$CatalogChangedToJson(CatalogChanged instance) =>
    <String, dynamic>{
      'entries': instance.entries.map((e) => e.toJson()).toList(),
      'quarantined': instance.quarantined.map((e) => e.toJson()).toList(),
    };

AssetsChanged _$AssetsChangedFromJson(Map<String, dynamic> json) =>
    AssetsChanged(
      fontsChanged: json['fontsChanged'] as bool,
      shaders: json['shaders'] == null ? const [] : _assetKeys(json['shaders']),
    );

Map<String, dynamic> _$AssetsChangedToJson(AssetsChanged instance) =>
    <String, dynamic>{
      'fontsChanged': instance.fontsChanged,
      'shaders': instance.shaders,
    };

DaemonCompiled _$DaemonCompiledFromJson(Map<String, dynamic> json) =>
    DaemonCompiled(
      requestId: (json['requestId'] as num).toInt(),
      id: json['id'] as String,
      compile: _millis.fromJson((json['compile'] as num).toInt()),
      newSourceCount: (json['newSourceCount'] as num).toInt(),
      editedCount: (json['editedCount'] as num?)?.toInt() ?? 0,
      unchanged: json['unchanged'] as bool? ?? false,
      dill: json['dill'] as String?,
      error: json['error'] as String?,
    );

Map<String, dynamic> _$DaemonCompiledToJson(DaemonCompiled instance) =>
    <String, dynamic>{
      'requestId': instance.requestId,
      'id': instance.id,
      'dill': instance.dill,
      'compile': _millis.toJson(instance.compile),
      'newSourceCount': instance.newSourceCount,
      'editedCount': instance.editedCount,
      'error': instance.error,
      'unchanged': instance.unchanged,
    };

HostReady _$HostReadyFromJson(Map<String, dynamic> json) => HostReady(
  requestId: (json['requestId'] as num).toInt(),
  hostPath: json['hostPath'] as String?,
  error: json['error'] as String?,
);

Map<String, dynamic> _$HostReadyToJson(HostReady instance) => <String, dynamic>{
  'requestId': instance.requestId,
  'hostPath': instance.hostPath,
  'error': instance.error,
};

DaemonFailed _$DaemonFailedFromJson(Map<String, dynamic> json) => DaemonFailed(
  message: json['message'] as String,
  stackTrace: json['stackTrace'] as String?,
);

Map<String, dynamic> _$DaemonFailedToJson(DaemonFailed instance) =>
    <String, dynamic>{
      'message': instance.message,
      'stackTrace': instance.stackTrace,
    };

DaemonConfig _$DaemonConfigFromJson(Map<String, dynamic> json) => DaemonConfig(
  appPackageRoot: json['appPackageRoot'] as String,
  projectRoot: json['projectRoot'] as String,
  packageConfig: json['packageConfig'] as String,
  flutterSdkRoot: json['flutterSdkRoot'] as String,
  roots:
      (json['roots'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [''],
  previewAnnotations:
      (json['previewAnnotations'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const ['Preview'],
  emitProbe: json['emitProbe'] as bool? ?? false,
  trackWidgetCreation: json['trackWidgetCreation'] as bool? ?? true,
  clock: json['clock'] == null ? null : DateTime.parse(json['clock'] as String),
  setup: json['setup'] as String?,
  daemonRevision: json['daemonRevision'] as String? ?? '',
);

Map<String, dynamic> _$DaemonConfigToJson(DaemonConfig instance) =>
    <String, dynamic>{
      'appPackageRoot': instance.appPackageRoot,
      'projectRoot': instance.projectRoot,
      'packageConfig': instance.packageConfig,
      'flutterSdkRoot': instance.flutterSdkRoot,
      'roots': instance.roots,
      'previewAnnotations': instance.previewAnnotations,
      'emitProbe': instance.emitProbe,
      'trackWidgetCreation': instance.trackWidgetCreation,
      'clock': instance.clock?.toIso8601String(),
      'setup': ?instance.setup,
      'daemonRevision': instance.daemonRevision,
    };
