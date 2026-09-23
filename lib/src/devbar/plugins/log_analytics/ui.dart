import 'package:material_ui/material_ui.dart';

import '../../devbar.dart';
import '../../utils/auto_scroll_to_bottom.dart';
import '../../utils/json_viewer.dart';
import '../../utils/timeago/timeago.dart';
import 'plugin.dart';

class AnalyticsList extends StatelessWidget {
  final LogAnalyticsPlugin service;
  const AnalyticsList(this.service, {super.key});

  @override
  Widget build(BuildContext context) {
    return AutoScroller<List<AnalyticEvent>>(
      stream: service.events,
      builder: (context, controller, logs) => ListView.separated(
        padding: const EdgeInsets.only(bottom: 50),
        controller: controller,
        separatorBuilder: (context, index) =>
            Container(height: 1, color: Colors.white.withValues(alpha: 0.2)),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          return EventTile(logs[index]);
        },
      ),
    );
  }
}

class EventTile extends StatelessWidget {
  final AnalyticEvent event;

  const EventTile(this.event, {super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);

    return ListTile(
      dense: true,
      leading: Icon(Icons.info),
      title: Text(event.name),
      subtitle: event.parameters != null
          ? Text(event.parameters.toString())
          : null,
      trailing: Text(timeAgo(event.time)),
      onTap: () {
        devbar.ui.showOverlayDialog(builder: (context) => _DetailDialog(event));
      },
    );
  }
}

class _DetailDialog extends StatelessWidget {
  final AnalyticEvent event;

  const _DetailDialog(this.event);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(event.name),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Parameters'),
              subtitle: JsonViewer(event.parameters),
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
