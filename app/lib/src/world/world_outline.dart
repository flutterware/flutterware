import 'package:material_ui/material_ui.dart';

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'world_canvas.dart';
import 'world_trace.dart';

/// Everything in the world, as one list: its people, each server with every
/// part of it — its routes, its tables, what it sent outside — the sync
/// engine, and the messages sent. The canvas shows what is happening; this
/// is what there is, with the room to grow down that a busy world needs.
///
/// Choosing an entry opens it in the sheet, as choosing it on the canvas
/// does. What the step on the stage touched carries its number here too.
class WorldOutline extends StatelessWidget {
  const WorldOutline({
    super.key,
    required this.people,
    required this.servers,
    required this.sync,
    required this.messages,
    required this.colorOf,
    required this.numbers,
    required this.litColor,
    required this.selected,
    required this.onPerson,
    required this.onPart,
    required this.onMessage,
  });

  /// Each person, with what says who they are.
  final List<({String name, String said})> people;
  final List<SystemServer> servers;

  /// Whether the apps sync, and the engine's name when they do.
  final String? sync;

  /// The newest messages, newest first.
  final List<OutboxMessage> messages;
  final Color Function(String? person) colorOf;

  /// The parts the step on the stage touched, numbered as it did.
  final Map<String, int> numbers;
  final Color litColor;

  /// What the sheet shows: a person's name, a node, or a message's id.
  final String? selected;
  final void Function(String person) onPerson;
  final void Function(String node) onPart;
  final void Function(OutboxMessage message) onMessage;

  @override
  Widget build(BuildContext context) {
    var mono = context.type.mono;
    Widget entry({
      required String id,
      required Widget label,
      required VoidCallback onTap,
      Color? dot,
      IconData? icon,
      String? count,
      double indent = 0,
    }) {
      var chosen = selected == id;
      var number = numbers[id];
      return Tappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            FwSpacing.sm + indent,
            5,
            FwSpacing.sm,
            5,
          ),
          decoration: BoxDecoration(
            color: chosen ? context.colors.accentSoft : null,
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          child: Row(
            children: [
              if (dot != null) ...[
                PersonDot(dot),
                const SizedBox(width: FwSpacing.sm),
              ] else if (icon != null) ...[
                Icon(icon, size: FwIconSize.sm, color: context.colors.mut),
                const SizedBox(width: FwSpacing.sm),
              ],
              Expanded(child: label),
              if (number != null)
                NodeNumber(number, color: litColor)
              else if (count != null)
                Text(count, style: context.type.caption),
            ],
          ),
        ),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.sm,
        FwSpacing.md,
        FwSpacing.sm,
        FwSpacing.xs,
      ),
      child: Text(text, style: context.type.fieldLabel),
    );
    Text plain(String text, {TextStyle? style}) => Text(
      text,
      style: style ?? context.type.body,
      overflow: TextOverflow.ellipsis,
    );

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: FwSpacing.xs,
      ),
      children: [
        heading('PEOPLE'),
        for (var person in people)
          entry(
            id: person.name,
            dot: colorOf(person.name),
            label: plain(person.name),
            count: person.said,
            onTap: () => onPerson(person.name),
          ),
        if (servers.isNotEmpty || sync != null) heading('SYSTEM'),
        for (var server in servers) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.sm,
              FwSpacing.xs,
              FwSpacing.sm,
              2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.dns_outlined,
                  size: FwIconSize.sm,
                  color: context.colors.ink2,
                ),
                const SizedBox(width: FwSpacing.sm),
                Expanded(
                  child: plain(server.name, style: context.type.bodyStrong),
                ),
                Text(_requests(server), style: context.type.caption),
              ],
            ),
          ),
          for (var MapEntry(key: part, value: n) in server.parts.entries)
            entry(
              id: server.partNode(part),
              indent: FwSpacing.lg,
              label: plain(part, style: mono),
              count: '×$n',
              onTap: () => onPart(server.partNode(part)),
            ),
          for (var MapEntry(key: table, value: keys) in server.tables.entries)
            entry(
              id: server.tableNode(table),
              indent: FwSpacing.lg,
              icon: server.layers.containsKey(table)
                  ? Icons.layers_outlined
                  : Icons.table_rows_outlined,
              label: plain(table, style: mono),
              count: '${keys.length}',
              onTap: () => onPart(server.tableNode(table)),
            ),
          for (var MapEntry(key: channel, value: n) in server.sent.entries)
            entry(
              id: server.sentNode(channel),
              indent: FwSpacing.lg,
              icon: messageIcon(channel),
              label: plain(messageKind(channel)),
              count: '$n sent',
              onTap: () => onPart(server.sentNode(channel)),
            ),
        ],
        if (sync case var engine?)
          entry(
            id: syncNode,
            icon: Icons.sync,
            label: plain(engine),
            onTap: () => onPart(syncNode),
          ),
        if (messages.isNotEmpty) heading('MESSAGES'),
        for (var message in messages)
          entry(
            id: message.id,
            dot: colorOf(message.person),
            label: plain(
              '${message.person ?? message.to} · ${message.text}',
              style: context.type.bodySmall,
            ),
            count: messageKind(message.kind),
            onTap: () => onMessage(message),
          ),
        const SizedBox(height: FwSpacing.lg),
      ],
    );
  }

  static String _requests(SystemServer server) {
    var n = server.parts.values.fold(0, (sum, count) => sum + count);
    return n == 0 ? '' : '$n req';
  }
}
