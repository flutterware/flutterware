import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';

import 'content.dart';
import 'home.dart';
import 'main.server.options.dart';

/// Renders flutterware.dev. Run by `jaspr build`, once, to write the page as
/// static HTML; nothing of it runs in the browser.
void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  var content = Content.load();
  var title = 'Flutterware: a studio for your Flutter project';
  var description = '${content.text('tagline')} ${content.text('lede')}';
  runApp(
    Document(
      title: title,
      lang: 'en',
      // Every link on the page is relative, so it is the same page at the
      // root of a domain and under a path.
      base: null,
      meta: {'description': description, 'twitter:card': 'summary_large_image'},
      head: [
        link(rel: 'canonical', href: 'https://flutterware.dev/'),
        _property('og:type', 'website'),
        _property('og:url', 'https://flutterware.dev/'),
        _property('og:title', title),
        _property('og:description', description),
        _property('og:image', content.picture('hero').url),
        link(rel: 'icon', type: 'image/png', href: 'favicon.png'),
        link(rel: 'preconnect', href: 'https://raw.githubusercontent.com'),
        link(rel: 'stylesheet', href: 'style.css'),
      ],
      body: Home(content),
    ),
  );
}

Component _property(String name, String content) => Component.element(
  tag: 'meta',
  attributes: {'property': name, 'content': content},
);
