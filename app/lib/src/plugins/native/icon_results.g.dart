// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'icon_results.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Map<String, dynamic> _$IconInventoryResultToJson(
  IconInventoryResult instance,
) => <String, dynamic>{
  'package': instance.package,
  'address': instance.address,
  'flavor': ?instance.flavor,
  'flavors': instance.flavors.map((e) => e.toJson()).toList(),
  'iosCatalog': instance.iosCatalog,
  'iconBundles': instance.iconBundles,
  'roles': instance.roles.map((e) => e.toJson()).toList(),
  'findings': instance.findings.map((e) => e.toJson()).toList(),
};

Map<String, dynamic> _$IconFlavorEntryToJson(IconFlavorEntry instance) =>
    <String, dynamic>{'name': instance.name, 'sources': instance.sources};

Map<String, dynamic> _$IconRoleEntryToJson(IconRoleEntry instance) =>
    <String, dynamic>{
      'role': instance.role,
      'label': instance.label,
      'platform': instance.platform,
      'treatment': instance.treatment,
      'mask': instance.mask,
      'since': ?instance.since,
      'referenced': ?instance.referenced,
      'color': ?instance.color,
      'files': instance.files.map((e) => e.toJson()).toList(),
    };

Map<String, dynamic> _$IconFileEntryToJson(IconFileEntry instance) =>
    <String, dynamic>{
      'path': instance.path,
      'modified': instance.modified,
      'width': ?instance.width,
      'height': ?instance.height,
      'hasAlpha': instance.hasAlpha,
      'density': ?instance.density,
      'icoFrames': instance.icoFrames,
      'declaredSize': ?instance.declaredSize,
    };

Map<String, dynamic> _$IconFindingEntryToJson(IconFindingEntry instance) =>
    <String, dynamic>{
      'tone': instance.tone,
      'message': instance.message,
      'role': ?instance.role,
    };
