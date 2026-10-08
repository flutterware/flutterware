/// What every page has around its content. Each part takes `root`, the way
/// from the page back to the site's root (`''` on the home page, `../../` on
/// a guide), because every link on the site is relative: it is the same site
/// at the root of a domain and under a path.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';

import 'content.dart' show repository;

/// Where the site is served, which a page's canonical link has to say in full.
const site = 'https://flutterware.dev/';

const pub = 'https://pub.dev/packages/flutterware';

/// Where to write. The README's contact region links it too; this one is for
/// the footer of every page.
const mail = 'hello@flutterware.dev';

/// The head of the page at [path]: what it is called, and where it finds the
/// stylesheet and the fonts from where it is.
Component pageHead({
  required String root,
  required String path,
  required String title,
  required String description,
  required String image,
}) => Document.head(
  title: title,
  meta: {'description': description, 'twitter:card': 'summary_large_image'},
  children: [
    link(rel: 'canonical', href: '$site$path'),
    _property('og:type', 'website'),
    _property('og:url', '$site$path'),
    _property('og:title', title),
    _property('og:description', description),
    _property('og:image', image),
    link(rel: 'icon', type: 'image/png', href: '${root}favicon.png'),
    link(rel: 'preconnect', href: 'https://raw.githubusercontent.com'),
    // The stylesheet asks for both; asking here too spares the page a moment
    // in the fallback font.
    for (var font in ['geist', 'geist-mono'])
      link(
        rel: 'preload',
        href: '${root}fonts/$font.woff2',
        as: 'font',
        type: 'font/woff2',
        attributes: {'crossorigin': ''},
      ),
    link(rel: 'stylesheet', href: '${root}style.css'),
  ],
);

/// The header. On the home page it lies over the hero; on a page of the docs,
/// which has no hero, it is a bar of its own.
Component pageTop({required String root, bool docs = false}) =>
    header(classes: docs ? 'top bar' : 'top', [
      div(classes: 'wrap', [
        a(href: root.isEmpty ? './' : root, classes: 'brand', [
          img(src: '${root}icon.svg', alt: '', width: 26, height: 26),
          .text('flutterware'),
        ]),
        nav(
          attributes: {'aria-label': 'Main'},
          [
            a(href: '$root#tools', classes: 'in-page', [.text('Tools')]),
            a(href: '$root#agents', classes: 'in-page', [.text('Agents')]),
            a(
              href: '${root}docs/',
              attributes: {if (docs) 'aria-current': 'true'},
              [.text('Docs')],
            ),
            a(href: repository, [.text('GitHub')]),
            a(href: pub, [.text('pub.dev')]),
          ],
        ),
      ]),
    ]);

Component pageFooter({required String root}) => footer([
  div(classes: 'wrap', [
    span([
      img(src: '${root}icon.svg', alt: '', width: 20, height: 20),
      .text('MIT license'),
    ]),
    nav(
      attributes: {'aria-label': 'Footer'},
      [
        a(href: '${root}docs/', [.text('Docs')]),
        a(href: repository, [.text('GitHub')]),
        a(href: pub, [.text('pub.dev')]),
        a(href: '$pub/changelog', [.text('Changelog')]),
        a(href: '$repository/blob/master/CONTRIBUTING.md', [
          .text('Contributing'),
        ]),
        a(href: 'mailto:$mail', [.text(mail)]),
      ],
    ),
  ]),
]);

Component _property(String name, String content) => Component.element(
  tag: 'meta',
  attributes: {'property': name, 'content': content},
);
