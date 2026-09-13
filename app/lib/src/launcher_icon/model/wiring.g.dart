// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wiring.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AdaptiveXml _$AdaptiveXmlFromJson(Map<String, dynamic> json) => AdaptiveXml(
  path: json['path'] as String,
  background: json['background'] as String?,
  foreground: json['foreground'] as String?,
  monochrome: json['monochrome'] as String?,
);

Map<String, dynamic> _$AdaptiveXmlToJson(AdaptiveXml instance) =>
    <String, dynamic>{
      'path': instance.path,
      'background': ?instance.background,
      'foreground': ?instance.foreground,
      'monochrome': ?instance.monochrome,
    };

AndroidWiring _$AndroidWiringFromJson(Map<String, dynamic> json) =>
    AndroidWiring(
      manifestIcon: json['manifestIcon'] as String?,
      manifestRoundIcon: json['manifestRoundIcon'] as String?,
      launcher: json['launcher'] == null
          ? null
          : AdaptiveXml.fromJson(json['launcher'] as Map<String, dynamic>),
      launcherRound: json['launcherRound'] == null
          ? null
          : AdaptiveXml.fromJson(json['launcherRound'] as Map<String, dynamic>),
      backgroundColor: json['backgroundColor'] as String?,
    );

Map<String, dynamic> _$AndroidWiringToJson(AndroidWiring instance) =>
    <String, dynamic>{
      'manifestIcon': ?instance.manifestIcon,
      'manifestRoundIcon': ?instance.manifestRoundIcon,
      'launcher': ?instance.launcher?.toJson(),
      'launcherRound': ?instance.launcherRound?.toJson(),
      'backgroundColor': ?instance.backgroundColor,
    };
