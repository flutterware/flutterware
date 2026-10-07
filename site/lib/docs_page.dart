import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'chrome.dart';
import 'content.dart' show repository;
import 'docs.dart';

/// One page of the docs: a guide, between the menu of all of them and the
/// list of its own sections.
class DocsPage extends StatelessComponent {
  const DocsPage(this.docs, this.page, {required this.image, super.key});

  final Docs docs;
  final DocPage page;

  /// The picture a link to the page is previewed with.
  final String image;

  @override
  Component build(BuildContext context) {
    var root = page.root;
    var isIndex = page == docs.index;
    return .fragment([
      pageHead(
        root: root,
        path: page.path,
        title: isIndex
            ? 'Flutterware docs'
            : '${page.title} · Flutterware docs',
        description: page.description,
        image: image,
      ),
      pageTop(root: root, docs: true),
      main_(classes: 'wrap docs', [
        // A phone has no room for the menu beside the page, so it gets the
        // same menu folded above it.
        details(classes: 'docs-menu', [
          summary([.text('All guides')]),
          _menu(),
        ]),
        aside(classes: 'docs-side', [_menu()]),
        article(classes: 'prose', [
          if (page.group case var group?)
            span(classes: 'label', [.text(group)]),
          h1([.text(page.title)]),
          RawText(page.html),
          _pager(),
          p(classes: 'edit', [
            a(href: '$repository/edit/master/${page.source}', [
              .text('Edit this page on GitHub'),
            ]),
          ]),
        ]),
        if (page.headings.length > 1)
          aside(classes: 'docs-toc', [
            span(classes: 'label', [.text('On this page')]),
            for (var heading in page.headings)
              a(href: '#${heading.id}', classes: 'level-${heading.level}', [
                .text(heading.text),
              ]),
          ]),
      ]),
      pageFooter(root: root),
      script(src: '${root}copy.js', defer: true),
    ]);
  }

  Component _menu() => nav(
    classes: 'docs-nav',
    attributes: {'aria-label': 'Guides'},
    [
      _entry('Overview', docs.index),
      for (var group in docs.groups) ...[
        span(classes: 'group', [.text(group.title)]),
        for (var entry in group.entries)
          _entry(entry.name, docs.pageOf(entry.file)),
      ],
    ],
  );

  Component _entry(String name, DocPage target) => a(
    href: '${page.root}${target.path}',
    attributes: {if (target == page) 'aria-current': 'page'},
    [.text(name)],
  );

  Component _pager() {
    var (previous, next) = docs.around(page);
    return div(classes: 'pager', [
      if (previous != null)
        a(href: '${page.root}${previous.path}', classes: 'previous', [
          small([.text('Previous')]),
          .text(previous == docs.index ? 'Overview' : previous.title),
        ]),
      if (next != null)
        a(href: '${page.root}${next.path}', classes: 'next', [
          small([.text('Next')]),
          .text(next.title),
        ]),
    ]);
  }
}
