import 'package:jaspr/server.dart';

import 'content.dart';
import 'docs.dart';
import 'main.server.options.dart';
import 'site.dart';

/// Renders flutterware.dev. Run by `jaspr build`, once, to write every page as
/// static HTML; nothing of it runs in the browser.
void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  var docs = Docs.load();
  var content = Content.load(
    // A link from the README to a guide goes to the guide's page.
    link: (href) => docs.link(href, from: 'README.md'),
  );
  runApp(
    Document(
      lang: 'en',
      // Every link on the site is relative, so it is the same site at the
      // root of a domain and under a path. Each page says what it is called
      // and where its stylesheet is from where it is: see `pageHead`.
      base: null,
      body: Site(content: content, docs: docs),
    ),
  );
}
