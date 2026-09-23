import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';

import '../../../utils/value_stream.dart';
import '../../devbar.dart';
import 'ui.dart';

/// A plugin for the Devbar which add a tab to display logs from `package:logging`
class LoggerPlugin implements DevbarPlugin {
  static const _maxHistory = 1000;
  final DevbarState _devbar;
  final _allLogs = <LogRecord>[];
  final visibles = ValueStream<List<LogRecord>>(const []);
  late final StreamSubscription _subscription;
  Level _level = Logger.root.level;
  String? _search;

  LoggerPlugin(this._devbar) {
    _devbar.ui.addTab(
      Tab(text: 'Logger'),
      LoggerList(this),
      hierarchy: ['Logs'],
    );

    _subscription = Logger.root.onRecord.listen((e) {
      _allLogs.add(e);

      if (_allLogs.length > _maxHistory) {
        _allLogs.removeAt(0);
      }

      _applyFilter();
    });

    visibles.onListen = _applyFilter;
  }

  static LoggerPlugin Function(DevbarState) init() {
    return (devbar) => LoggerPlugin(devbar);
  }

  void clear() {
    _allLogs.clear();
    _applyFilter();
  }

  Level get level => _level;
  set level(Level level) {
    _level = level;
    _applyFilter();
  }

  String? get search => _search;
  set search(String? search) {
    _search = search;
    _applyFilter();
  }

  void _applyFilter() {
    if (!visibles.hasListener) return;

    var logs = _allLogs;

    var search = _search;
    if (search != null && search.isNotEmpty) {
      var normalizedSearch = search.toLowerCase();
      logs = logs
          .where((l) => l.message.toLowerCase().contains(normalizedSearch))
          .toList();
    }
    if (_level != Logger.root.level) {
      logs = logs.where((l) => l.level >= _level).toList();
    }

    visibles.add(logs);
  }

  @override
  void dispose() {
    visibles.dispose();
    _subscription.cancel();
  }
}
