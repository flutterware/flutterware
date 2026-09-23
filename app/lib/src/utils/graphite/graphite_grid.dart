import 'package:material_ui/material_ui.dart';
import 'package:flutter/widgets.dart';

import 'core/matrix.dart';
import 'graphite.dart';

class GraphiteGrid extends StatefulWidget {
  final Matrix matrix;

  GraphiteGrid({required this.matrix, super.key});
  @override
  State<GraphiteGrid> createState() => _GraphiteGridState();
}

class _GraphiteGridState extends State<GraphiteGrid> {
  List<MatrixNode?> getListFromMatrix(Matrix mtx) {
    return mtx.s.asMap().entries.fold([], (result, entry) {
      var y = entry.key, row = entry.value;
      result.addAll(
        row.asMap().entries.map((cellEntry) {
          var x = cellEntry.key, cell = cellEntry.value;
          return cell == null
              ? null
              : MatrixNode.fromNodeOutput(x: x, y: y, nodeOutput: cell);
        }),
      );
      return result;
    });
  }

  @override
  Widget build(BuildContext context) {
    var config = DirectGraph.of(context);
    var width = widget.matrix.width();
    var height = widget.matrix.height();
    var data = getListFromMatrix(widget.matrix);
    return SizedBox(
      width:
          (config.cellSize.width * width).toDouble() +
          ((width - 1) * config.cellPadding),
      height:
          (config.cellSize.height * height).toDouble() +
          ((height - 1) * config.cellPadding),
      child: GridView.count(
        clipBehavior: Clip.none,
        padding: EdgeInsets.zero,
        crossAxisCount: width,
        childAspectRatio: config.cellSize.aspectRatio,
        crossAxisSpacing: config.cellPadding,
        mainAxisSpacing: config.cellPadding,
        physics: NeverScrollableScrollPhysics(),
        primary: false,
        children: data.map<Widget>((node) {
          var child = node == null
              ? IgnorePointer(child: Container())
              : GraphiteCell(
                  node: node,
                  cellPadding: config.cellPadding,
                  builder: config.builder,
                );
          return SizedBox(
            width: config.cellSize.width,
            height: config.cellSize.height,
            child: child,
          );
        }).toList(),
      ),
    );
  }
}
