import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../../devbar.dart';
import '../../utils/auto_scroll_to_bottom.dart';
import '../../utils/timeago/timeago.dart';
import 'plugin.dart';

class LoggerList extends StatefulWidget {
  final LoggerPlugin service;

  const LoggerList(this.service, {super.key});

  @override
  State<LoggerList> createState() => _LoggerListState();
}

class _LoggerListState extends State<LoggerList> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () {
                  widget.service.clear();
                },
                child: Text('Clear'),
              ),
              Text('Level: '),
              DropdownButton<Level>(
                onChanged: (newValue) {
                  setState(() {
                    widget.service.level = newValue!;
                  });
                },
                value: widget.service.level,
                items: Level.LEVELS
                    .map(
                      (l) => DropdownMenuItem<Level>(
                        value: l,
                        child: Text(l.name),
                      ),
                    )
                    .toList(),
              ),
              Text('Search: '),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 150),
                  child: TextField(
                    maxLines: 1,
                    onChanged: (newValue) {
                      widget.service.search = newValue;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AutoScroller<List<LogRecord>>(
            stream: widget.service.visibles,
            builder: (context, controller, logs) => ListView.separated(
              separatorBuilder: (context, index) => Container(
                height: 1,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              controller: controller,
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return LogTile(logs[index]);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class LogTile extends StatelessWidget {
  final LogRecord record;

  const LogTile(this.record, {super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);

    return ListTile(
      dense: true,
      leading: _icon,
      title: Text('[${record.loggerName}] ${record.message}'),
      subtitle: Text('${record.error ?? ''}'),
      trailing: Text(timeAgo(record.time)),
      onTap: () {
        devbar.ui.showOverlayDialog(
          builder: (context) => _DetailDialog(record),
        );
      },
    );
  }

  Icon get _icon {
    if (record.level == Level.WARNING) {
      return Icon(Icons.warning, color: Colors.orange);
    } else if (record.level == Level.SEVERE) {
      return Icon(Icons.warning, color: Colors.red);
    } else if (record.level == Level.SHOUT) {
      return Icon(Icons.pan_tool, color: Colors.redAccent);
    }
    return Icon(Icons.info_outline);
  }
}

class _DetailDialog extends StatelessWidget {
  final LogRecord record;

  const _DetailDialog(this.record);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(record.level.name),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: SelectableText(record.message),
              subtitle: Text(record.time.toString()),
            ),
            ListTile(title: Text('Logger:'), subtitle: Text(record.loggerName)),
            if (record.error != null)
              ListTile(
                title: Text('Error:'),
                subtitle: Text(record.error.toString()),
              ),
            if (record.stackTrace != null)
              ListTile(
                title: Text('StackTrace:'),
                subtitle: Text(record.stackTrace.toString()),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: Icon(Icons.copy),
          label: Text('Copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: record.message));
          },
        ),
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
