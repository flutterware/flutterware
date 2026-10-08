/// The devbar wrapper around [DatabasePanelSource] — the five-line recipe's
/// entry point. All the serving logic is in `database.dart`, pure and tested
/// against a fake adapter; this file only exists because [DevbarPlugin] lives
/// with the Flutter imports.
library;

import '../../channels/panels.dart';
import '../devbar.dart';
import '../panel_source.dart';
import 'database.dart';

class DatabasePlugin implements DevbarPlugin, DevbarPanelSource {
  DatabasePlugin._(this._source);

  /// One plugin per database: `db:main` and `db:cache` are two `init` calls
  /// in the devbar's plugin list, not one call with a list — a panel is the
  /// unit every surface renders.
  static DatabasePlugin Function(DevbarState) init({
    required DatabaseAdapter database,
  }) =>
      (_) => DatabasePlugin._(DatabasePanelSource(database));

  final DatabasePanelSource _source;

  @override
  String get panelId => _source.panelId;

  @override
  String get panelLabel => _source.panelLabel;

  @override
  void describePanel(Panel panel) => _source.describePanel(panel);

  @override
  void dispose() => _source.dispose();
}
