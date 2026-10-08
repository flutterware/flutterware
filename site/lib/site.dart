import 'package:jaspr/server.dart';

import 'content.dart';
import 'docs.dart';
import 'docs_page.dart';
import 'home.dart';

/// The site: the home page at `/`, and a page for each guide under `/docs/`.
///
/// Async for the build's sake: see [build].
class Site extends AsyncStatelessComponent {
  const Site({required this.content, required this.docs, super.key});

  final Content content;
  final Docs docs;

  @override
  Future<Component> build(BuildContext context) async {
    if (kGenerateMode) {
      // The build renders `/` and whatever a page asks for while it does.
      // Each ask is a message to the build tool, and the tool stops as soon
      // as it has no page left to write — so an ask still in flight when `/`
      // is answered reaches a tool that has already gone, and the page is
      // never written. Fast enough on a laptop to pass unnoticed; on CI every
      // deploy wrote the home page alone, with no word about the rest. So
      // the home page waits for its asks to land before it answers.
      await Future.wait([
        for (var page in docs.pages)
          ServerApp.requestRouteGeneration('/${page.path}'),
      ]);
    }
    var path = Uri.parse(context.url).path;
    if (!path.endsWith('/')) path = '$path/';
    for (var page in docs.pages) {
      if (path == '/${page.path}') {
        return DocsPage(docs, page, image: content.picture('hero').url);
      }
    }
    return Home(content, docs);
  }
}
