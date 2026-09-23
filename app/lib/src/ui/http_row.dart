import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'theme.dart';

/// The verb of an HTTP request, fixed-width and coloured.
///
/// Fixed-width because a column whose left edge moves per row is one the eye
/// cannot run down, and `GET`/`DELETE` differ by three characters. Both
/// request lists in the app used to glue the method to the path in one string,
/// so no two paths started at the same x.
///
/// Shared by the server panel's Requests tab and the run cockpit's Network
/// tab, which are the same wire seen from opposite ends and are meant to read
/// as siblings — the run tab's own doc comment says so, and saying so is not
/// enough to keep two copies in step.
class HttpMethodToken extends StatelessWidget {
  const HttpMethodToken(this.method, {super.key});

  final String method;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = switch (method.toUpperCase()) {
      'GET' || 'HEAD' => colors.info,
      'POST' => colors.grn,
      'PUT' || 'PATCH' => colors.amber,
      'DELETE' => colors.red,
      _ => colors.mut,
    };
    return SizedBox(
      width: 46,
      child: Text(
        method.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: context.type.mono.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A response status, coloured by class — green under 400, amber for 4xx, red
/// for 5xx.
///
/// [status] is whatever the source had: an `int` code, a word like `ERR`, or
/// null for a request still in flight.
class HttpStatusCode extends StatelessWidget {
  const HttpStatusCode(this.status, {super.key});

  final Object? status;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (label, color) = switch (status) {
      int code when code >= 500 => ('$code', colors.red),
      int code when code >= 400 => ('$code', colors.amber),
      int code => ('$code', colors.grn),
      String word => (word, colors.red),
      // In flight, and saying so beats an empty column that reads as zero.
      _ => ('…', colors.mut3),
    };
    return Text(
      label,
      style: context.type.mono.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
