import 'package:material_ui/material_ui.dart';

import '../../../app_events/events.dart';
import '../../../utils/value_stream.dart';
import '../../devbar.dart';
import 'ui.dart';

/// A plugin for the Devbar which adds a tab listing the statements the app
/// itself issued.
///
/// The other half of `DatabasePlugin`. That one is a *browser*: it runs
/// the SQL you type and watches the tables you name, through the four
/// functions of a `DatabaseAdapter`. It never sees a statement the app ran on
/// its own. This one is the log, and it is fed the same way every other
/// reported channel is — the app calls [recordAppEvent] once and a scenario's
/// Events pane gets it too:
///
/// ```dart
/// recordAppEvent(AppEvent.query(sql: sql, args: args, rows: rows.length));
/// ```
///
/// So the wrapper a project writes around its database is written against one
/// call, and both surfaces fill.
class LogQueriesPlugin implements DevbarPlugin {
  static const _maxQueries = 200;

  final queries = ValueStream<List<LoggedQuery>>([]);
  final DevbarState devbar;

  LogQueriesPlugin(this.devbar) {
    devbar.ui.addTab(
      Tab(text: 'Queries'),
      QueryList(this),
      hierarchy: ['Logs'],
    );
  }

  static LogQueriesPlugin Function(DevbarState) init() {
    return (devbar) => LogQueriesPlugin(devbar);
  }

  void clear() {
    queries.add([]);
  }

  /// Records one statement, as [AppEvent.query] composed it.
  void reported(AppEvent event) {
    var queryList = queries.value
      ..add(
        LoggedQuery(
          summary: event.title,
          sql: event.body ?? event.title,
          rows: event.detail,
          args: switch (event.data['args']) {
            List args => args,
            null => const [],
            var single => [single],
          },
          failed: event.error,
        ),
      );

    if (queryList.length > _maxQueries) {
      queryList.removeAt(0);
    }

    queries.add(queryList);
  }

  @override
  void dispose() {
    queries.dispose();
  }
}

class LoggedQuery {
  /// The statement's first line — what the list shows.
  final String summary;

  /// The whole statement, however many lines it runs to.
  final String sql;

  /// The row count as the report phrased it (`3 rows`), or null when the
  /// reporter did not count.
  final String? rows;

  final List<Object?> args;
  final bool failed;
  final time = DateTime.now();

  LoggedQuery({
    required this.summary,
    required this.sql,
    required this.rows,
    required this.args,
    required this.failed,
  });
}

/// Extension to add `devbar.queries` shortcut.
extension LogQueriesPluginDevbarExtension on DevbarState {
  LogQueriesPlugin get queries => plugin<LogQueriesPlugin>();
}
