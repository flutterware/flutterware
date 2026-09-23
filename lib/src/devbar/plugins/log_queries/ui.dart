import 'package:material_ui/material_ui.dart';

import '../../devbar.dart';
import '../../utils/auto_scroll_to_bottom.dart';
import '../../utils/json_viewer.dart';
import '../../utils/timeago/timeago.dart';
import 'plugin.dart';

class QueryList extends StatelessWidget {
  final LogQueriesPlugin service;
  const QueryList(this.service, {super.key});

  @override
  Widget build(BuildContext context) {
    return AutoScroller<List<LoggedQuery>>(
      stream: service.queries,
      builder: (context, controller, queries) => ListView.separated(
        padding: const EdgeInsets.only(bottom: 50),
        controller: controller,
        separatorBuilder: (context, index) =>
            Container(height: 1, color: Colors.white.withValues(alpha: 0.2)),
        itemCount: queries.length,
        itemBuilder: (context, index) => QueryTile(queries[index]),
      ),
    );
  }
}

class QueryTile extends StatelessWidget {
  final LoggedQuery query;

  const QueryTile(this.query, {super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);

    return ListTile(
      dense: true,
      leading: Text(query.failed ? 'FAIL' : 'OK'),
      title: Text(query.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: query.args.isNotEmpty ? Text(query.args.toString()) : null,
      trailing: Text([?query.rows, timeAgo(query.time)].join(' · ')),
      onTap: () {
        devbar.ui.showOverlayDialog(builder: (context) => _DetailDialog(query));
      },
    );
  }
}

class _DetailDialog extends StatelessWidget {
  final LoggedQuery query;

  const _DetailDialog(this.query);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(['Query', ?query.rows].join(' · ')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text('SQL'), subtitle: SelectableText(query.sql)),
            if (query.args.isNotEmpty)
              ListTile(
                title: Text('Arguments'),
                subtitle: JsonViewer(query.args),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text('OK'),
        ),
      ],
    );
  }
}
