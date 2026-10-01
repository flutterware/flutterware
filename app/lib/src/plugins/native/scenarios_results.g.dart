// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'scenarios_results.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$ScenarioListResultToJson(ScenarioListResult instance) =>
    <String, dynamic>{
      'packages': instance.packages.map((e) => e.toJson()).toList(),
    };

Map<String, dynamic> _$ScenarioListPackageToJson(
  ScenarioListPackage instance,
) => <String, dynamic>{
  'path': instance.path,
  'branch': ?instance.branch?.toJson(),
  'directory': instance.directory,
  'scenarios': instance.scenarios.map((e) => e.toJson()).toList(),
  'diagnostics': instance.diagnostics,
  'error': ?instance.error,
  'authoring': ?instance.authoring,
};

Map<String, dynamic> _$ScenarioListEntryToJson(ScenarioListEntry instance) =>
    <String, dynamic>{
      'name': instance.name,
      'change': ?instance.change?.toJson(),
      'file': instance.file,
      'line': instance.line,
    };

Map<String, dynamic> _$ScenarioWebExportResultToJson(
  ScenarioWebExportResult instance,
) => <String, dynamic>{
  'output': instance.output,
  'indexHtml': instance.indexHtml,
  'scenarios': instance.scenarios,
  'steps': instance.steps,
  'artifacts': instance.artifacts,
  'durationMs': instance.durationMs,
  'failed': instance.failed,
  'serve': instance.serve,
  'ok': instance.ok,
};

Map<String, dynamic> _$ScenarioNewResultToJson(ScenarioNewResult instance) =>
    <String, dynamic>{
      'package': instance.package,
      'file': instance.file,
      'name': instance.name,
      'next': instance.next,
    };

Map<String, dynamic> _$ScenarioRestartResultToJson(
  ScenarioRestartResult instance,
) => <String, dynamic>{'restarted': instance.restarted};

Map<String, dynamic> _$ScenarioShotsResultToJson(
  ScenarioShotsResult instance,
) => <String, dynamic>{
  'packages': instance.packages.map((e) => e.toJson()).toList(),
  'count': instance.count,
  'ok': instance.ok,
};

Map<String, dynamic> _$ScenarioShotsPackageToJson(
  ScenarioShotsPackage instance,
) => <String, dynamic>{
  'path': instance.path,
  'output': instance.output,
  'sets': instance.sets.map((e) => e.toJson()).toList(),
  'error': ?instance.error,
};

Map<String, dynamic> _$ScenarioShotSetToJson(ScenarioShotSet instance) =>
    <String, dynamic>{
      'directory': instance.directory,
      'axes': instance.axes,
      'images': instance.images,
      'failed': instance.failed,
      'failures': instance.failures.map((e) => e.toJson()).toList(),
    };

Map<String, dynamic> _$ScenarioShotFailureToJson(
  ScenarioShotFailure instance,
) => <String, dynamic>{
  'file': instance.file,
  'scenario': instance.scenario,
  'error': instance.error,
  'rerun': instance.rerun,
};

Map<String, dynamic> _$ScenarioReadResultToJson(ScenarioReadResult instance) =>
    <String, dynamic>{
      'step': instance.step,
      'lens': instance.lens,
      'scenario': ?instance.scenario,
      'file': ?instance.file,
      'index': ?instance.index,
      'failure': ?instance.failure,
      'image': ?instance.image,
      'screen': ?instance.screen?.toJson(),
      'texts': ?instance.texts,
      'tree': ?instance.tree,
      'nodes': ?instance.nodes,
      'events': ?instance.events?.map((e) => e.toJson()).toList(),
      'eventCount': ?instance.eventCount,
      'eventChannels': ?instance.eventChannels,
      'find': ?instance.find,
      'at': ?instance.at,
      'styles': ?instance.styles?.map((e) => e.toJson()).toList(),
      'note': ?instance.note,
      'next': ?instance.next,
      'steps': instance.steps,
    };

Map<String, dynamic> _$ScenarioDiffResultToJson(ScenarioDiffResult instance) =>
    <String, dynamic>{
      'before': instance.before,
      'after': instance.after,
      'drift': instance.drift,
    };
