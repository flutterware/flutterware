import 'dart:async';

import 'package:jaspr/server.dart';

import 'content.dart';
import 'docs.dart';
import 'docs_page.dart';
import 'home.dart';

/// The site: the home page at `/`, and a page for each guide under `/docs/`.
class Site extends StatelessComponent {
  const Site({required this.content, required this.docs, super.key});

  final Content content;
  final Docs docs;

  @override
  Component build(BuildContext context) {
    if (kGenerateMode) {
      // The build renders `/` and whatever a page asks for while it does.
      for (var page in docs.pages) {
        unawaited(ServerApp.requestRouteGeneration('/${page.path}'));
      }
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
