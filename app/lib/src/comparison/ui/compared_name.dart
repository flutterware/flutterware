import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// What a row is called and where it lives, out of its id and its label.
///
/// An id is `<file>#<name>`: the file a preview or a scenario is declared in,
/// then the function or the scenario's own name. The name is what a reader
/// knows it by — the label when the comparison recorded one, `Order placed`
/// for `demo/shop.dart#shopConfirmation` — and the file is where to go and
/// look. Titles used to print the whole id, which put
/// `test/scenarios/desktop/shop_window_test.dart#Order a cold brew on a laptop`
/// in the heading of the one page about that flow.
({String name, String file}) comparedName(String id, {String? label}) {
  var hash = id.indexOf('#');
  return (
    name: label ?? (hash < 0 ? id : id.substring(hash + 1)),
    file: hash < 0 ? '' : id.substring(0, hash),
  );
}

/// A pane's heading: the name, and the file under it.
class ComparedTitle extends StatelessWidget {
  const ComparedTitle(this.id, {super.key, this.label, this.detail});

  final String id;
  final String? label;

  /// Said after the file on the second line — a step's place in its flow.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (:name, :file) = comparedName(id, label: label);
    var second = [if (file.isNotEmpty) file, ?detail].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: context.type.bodyStrong,
          overflow: TextOverflow.ellipsis,
        ),
        if (second.isNotEmpty)
          SelectableText(
            second,
            maxLines: 1,
            style: context.type.micro.copyWith(color: colors.mut),
          ),
      ],
    );
  }
}
