import 'package:material_ui/material_ui.dart';

import '../../../utils/value_stream.dart';
import '../../devbar.dart';
import 'ui.dart';

/// A plugin for the Devbar which add a tab to display analytics events.
class LogAnalyticsPlugin implements DevbarPlugin {
  static const _maxEvents = 200;
  final DevbarState devbar;
  final events = ValueStream<List<AnalyticEvent>>([]);

  LogAnalyticsPlugin(this.devbar) {
    devbar.ui.addTab(
      Tab(text: 'Analytics'),
      AnalyticsList(this),
      hierarchy: ['Logs'],
    );
  }

  static LogAnalyticsPlugin Function(DevbarState) init() {
    return (devbar) => LogAnalyticsPlugin(devbar);
  }

  void log(String eventName, [Map<String, dynamic>? parameter]) {
    var eventList = events.value..add(AnalyticEvent(eventName, parameter));

    if (eventList.length > _maxEvents) {
      eventList.removeAt(0);
    }
    events.add(eventList);
  }

  void clear() {
    events.add([]);
  }

  @override
  void dispose() {
    events.dispose();
  }
}

class AnalyticEvent {
  final String name;
  final Map<String, dynamic>? parameters;
  final time = DateTime.now();

  AnalyticEvent(this.name, this.parameters);
}

/// Extension to add `context.analytics` shortcut.
extension AnalyticsPluginDevbarExtension on DevbarState {
  LogAnalyticsPlugin get analytics => plugin<LogAnalyticsPlugin>();
}
