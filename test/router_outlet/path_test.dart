import 'package:flutterware/src/router_outlet/path.dart';
import 'package:test/test.dart';

void main() {
  test('PathPage class', () {
    expect(PagePath('', isAbsolute: true).toString(), '/');
    expect(PagePath('', isAbsolute: false).toString(), '');
    expect(PagePath.root.toString(), '/');
    expect(PagePath('some/url//').toString(), 'some/url');
    expect(PagePath('/some/url//').toString(), '/some/url');
    expect(PagePath('some/url', isAbsolute: true).toString(), '/some/url');
    expect(PagePath('//some/url', isAbsolute: true).toString(), '/some/url');
    expect('${PagePath(' //some//url//', isAbsolute: false)}', 'some/url');
    expect(PagePath('//some/url'), PagePath('/some/url'));
  });

  test('PathPage relative', () {
    expect(PagePath('aa/../bb').toString(), 'bb');
  });

  test('PathPattern.rootPath', () {
    var path = PagePath('/home');
    var rootMatch = path.rootMatch;
    expect(rootMatch.matched, PagePath('', isAbsolute: true));
    expect(rootMatch.full, path);
    expect(rootMatch.remaining, PagePath('home'));
    expect(rootMatch.args, {});
    expect(rootMatch.current, PagePath(''));
  });

  test('PathPattern class', () {
    expect(PathPattern('').pattern, '');
    expect(PathPattern('/home').pattern, 'home');
    expect(PathPattern('/home/:id-user').pattern, 'home/:id-user');
  });

  test('MatchedPath class 1', () {
    var path = PagePath('/users/1/profile');

    var matched = path.rootMatch.matchesRemaining(PathPattern('users/:id'))!;

    expect(matched.full.toString(), '/users/1/profile');
    expect(matched.matched.toString(), '/users/1');
    expect(matched.current.toString(), 'users/1');
    expect(matched.remaining.toString(), 'profile');
    expect(matched.args, {'id': '1'});
  });

  test('MatchedPath class 2', () {
    var path = PagePath('/users/1/profile');

    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id'))!;

    expect(matched.pattern.pattern, ':id');
    expect(matched.full.toString(), '/users/1/profile');
    expect(matched.matched.toString(), '/users/1');
    expect(matched.current.toString(), '1');
    expect(matched.remaining.toString(), 'profile');
    expect(matched.args, {'id': '1'});
  });

  test('MatchedPath equals', () {
    var path = PagePath('/users/1/profile');

    var matched1 = path.rootMatch.matchesRemaining(PathPattern('users/:id'))!;
    var matched2 = path.rootMatch.matchesRemaining(PathPattern('users/:id'))!;
    expect(matched1, matched2);
    expect(matched1.hashCode, matched2.hashCode);
    expect(
      [path.rootMatch.matchesRemaining(PathPattern('users/:id'))!]
          .contains(path.rootMatch.matchesRemaining(PathPattern('users/:id'))!),
      isTrue,
    );
  });

  test('MatchedPath class 3', () {
    var path = PagePath('/users/1-456/profile');

    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id-:mac/profile'))!;

    expect(matched.full.toString(), '/users/1-456/profile');
    expect(matched.matched.toString(), '/users/1-456/profile');
    expect(matched.current.toString(), '1-456/profile');
    expect(matched.remaining.toString(), '');
    expect(matched.args, {'id': '1', 'mac': '456'});
  });

  test('MatchedPath decode parameters', () {
    var path = PagePath('/users/${Uri.encodeComponent('àab machin')}');

    var matched = path.rootMatch.matchesRemaining(PathPattern('users/:name'))!;

    expect(matched.full.toString(), '/users/%C3%A0ab%20machin');
    expect(matched.args, {'name': 'àab machin'});
  });

  test('MatchedPath.resolve 1', () {
    var path = PagePath('/users');

    var matched = path.rootMatch.matchesRemaining(PathPattern('users'))!;

    var newPath = matched.resolve('url');
    expect(newPath.toString(), '/users/url');

    var newPath2 = matched.resolve('/url');
    expect(newPath2.toString(), '/url');
  });

  test('MatchedPath.resolve 2', () {
    var path = PagePath('/users/1/profile');
    var matched = path.rootMatch.matchesRemaining(PathPattern('users'))!;

    var newPath = matched.resolve('url');
    expect(newPath.toString(), '/users/url');

    var newPath2 = matched.resolve('/url');
    expect(newPath2.toString(), '/url');
  });

  test('MatchedPath.resolve 3', () {
    var path = PagePath('/users/1/profile');
    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id'))!;

    var newPath = matched.resolve('url');
    expect(newPath.toString(), '/users/1/url');

    var newPath2 = matched.resolve('/url');
    expect(newPath2.toString(), '/url');
  });

  test('MatchedPath.resolve up', () {
    var path = PagePath('/users/1/profile');
    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id'))!;

    expect(matched.resolve('..').toString(), '/users');
    expect(matched.resolve('../2').toString(), '/users/2');
    expect(matched.resolve('../2/profile').toString(), '/users/2/profile');
    expect(matched.resolve('../../home').toString(), '/home');
    expect(matched.resolve('../../../home').toString(), '/../home');
  });

  test('MatchedPath.isSelected 1', () {
    var path = PagePath('/home/profile');
    var matched = path.rootMatch;

    expect(matched.isSelected('home'), true);
    expect(matched.isSelected('users'), false);
  });

  test('MatchedPath.isSelected 2', () {
    var path = PagePath('/home/profile/other');
    var matched = path.rootMatch.matchesRemaining(PathPattern('home'))!;
    expect(matched.isSelected('profile'), true);
    expect(matched.isSelected('profile/other'), true);
    expect(matched.isSelected('other'), false);
    expect(matched.isSelected('/other'), false);
    expect(matched.isSelected('/home'), true);
  });

  test('MatchedPath.isSelected 2', () {
    var path = PagePath('/home/profile/other');
    var matched = path.rootMatch.matchesRemaining(PathPattern('home'))!;
    expect(matched.isSelected('profile'), true);
    expect(matched.isSelected('profile/other'), true);
    expect(matched.isSelected('other'), false);
    expect(matched.isSelected('/other'), false);
    expect(matched.isSelected('/home'), true);
  });

  test('MatchedPath.isSelected 3', () {
    var path = PagePath('/home/profile/1');
    var rootMatch = path.rootMatch;
    var profileMatch = path.rootMatch.matchesRemaining(
      PathPattern('home/profile'),
    )!;

    expect(rootMatch.isSelectedType('home'), RouteSelectedType.descendant);
    expect(rootMatch.isSelectedType('users'), null);
    expect(
      rootMatch.isSelectedType('home/profile'),
      RouteSelectedType.descendant,
    );
    expect(
      rootMatch.isSelectedType('/home/profile/'),
      RouteSelectedType.descendant,
    );
    expect(
      rootMatch.isSelectedType('/home/profile'),
      RouteSelectedType.descendant,
    );
    expect(profileMatch.isSelectedType(''), RouteSelectedType.descendant);
    expect(profileMatch.isSelectedType('1'), RouteSelectedType.self);
    expect(profileMatch.isSelectedType('1/'), RouteSelectedType.self);
    expect(profileMatch.isSelectedType('/1'), null);
  });

  test('MatchedPath.isSelected survives query parameters', () {
    // The current URL is the side that carries a query, and it used to be
    // compared with the query included — so `/settings?tab=2` selected
    // nothing and every nav highlight vanished the moment a screen put state
    // in its query.
    var path = PagePath('/settings?tab=2');
    var matched = path.rootMatch;

    expect(matched.isSelectedType('/settings'), RouteSelectedType.self);
    expect(matched.isSelectedType('settings'), RouteSelectedType.self);
    expect(matched.isSelected('/other'), false);

    var deep = PagePath('/home/profile/1?edit=true');
    var profileMatch = deep.rootMatch.matchesRemaining(
      PathPattern('home/profile'),
    )!;
    expect(profileMatch.isSelectedType('1'), RouteSelectedType.self);
    expect(deep.rootMatch.isSelectedType('home'), RouteSelectedType.descendant);

    // A query on the asked side is ignored the same way.
    expect(matched.isSelectedType('/settings?tab=9'), RouteSelectedType.self);

    expect(deep.rootMatch.selectedIndex(['', 'home', 'other']), 1);
  });

  test('MatchedPath.selectedIndex', () {
    var path = PagePath('/users/1');
    var matched = path.rootMatch;
    expect(matched.selectedIndex(['', 'users', 'other']), 1);
  });

  test('Query parameters in PagePath', () {
    expect(PagePath('some/url?query=true&param=false').queryParameters, {
      'query': 'true',
      'param': 'false',
    });
    expect(PagePath('some/url?').queryParameters, {});
    expect(PagePath('some/url').queryParameters, {});
    expect(PagePath('some/url?a').queryParameters, {'a': ''});
    expect(PagePath('some/url?a').toString(), 'some/url?a');
    expect(
      PagePath('some/url?query=true&param=false').toString(),
      'some/url?query=true&param=false',
    );
  });

  test('MatchedPath decode query parameters parameters', () {
    var path = PagePath('/users/machin?arg=1');

    var matched = path.rootMatch.matchesRemaining(PathPattern('users/:name'))!;

    expect(matched.queryParameters, {'arg': '1'});
    expect(matched.full.toString(), '/users/machin?arg=1');
    expect(matched.current.toString(), 'users/machin');
  });

  test('MatchedPath.resolve 3 with query parameters', () {
    var path = PagePath('/users/1/profile?auto');
    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id'))!;

    var newPath = matched.resolve('url');
    expect(newPath.toString(), '/users/1/url');

    var newPath2 = matched.resolve('/url');
    expect(newPath2.toString(), '/url');
  });

  test('MatchedPath.resolve keeps a relative url query', () {
    var matched = PagePath('/emails?device=phone').rootMatch
        .matchesRemaining(PathPattern('emails'))!;

    var relative = matched.resolve('reset-password/reset?language=nl');
    expect(relative.toString(), '/emails/reset-password/reset?language=nl');
    expect(relative.queryParameters, {'language': 'nl'});

    expect(
      matched.resolve('../reminders?language=nl').toString(),
      '/reminders?language=nl',
    );

    expect(matched.resolve('?language=nl').toString(), '/emails?language=nl');
  });

  test('MatchedPath.resolve gives a relative url what its absolute gives', () {
    var mounts = [
      PagePath('/?tab=2').rootMatch,
      PagePath('/users/1/profile?tab=2').rootMatch
          .matchesRemaining(PathPattern('users'))!
          .matchesRemaining(PathPattern(':id'))!,
    ];
    var urls = [
      'a',
      'a?x=1',
      'a/b?x=1&y=2',
      './a?x=1',
      'a/?x=1',
      '../a?x=1',
      '?x=1',
      '',
      'a?x=a%20b',
      'a?x',
    ];
    for (var matched in mounts) {
      for (var url in urls) {
        var absolute = '${matched.matched.toPath()}/$url'.replaceFirst(
          '//',
          '/',
        );
        var resolved = matched.resolve(url);
        expect(resolved, matched.resolve(absolute), reason: url);
        expect(
          resolved.queryParameters,
          matched.resolve(absolute).queryParameters,
          reason: url,
        );
      }
    }
  });

  test('MatchedPath.resolve 3 with extra parameters', () {
    var path = PagePath('/users/1/profile?auto');
    var matched = path.rootMatch
        .matchesRemaining(PathPattern('users'))!
        .matchesRemaining(PathPattern(':id'))!;

    var newPath = matched.resolve('url', extra: {'one': 1});
    expect(newPath.extra, {'one': 1});

    var newPath2 = matched.resolve('/url');
    expect(newPath2.extra, {});
  });

  test('Navigate with extra parameters', () {
    var matched = PagePath.root.rootMatch;

    var newPath = matched.resolve('/', extra: {'one': 1});
    expect(newPath.extra, {'one': 1});
    expect(newPath.isAbsolute, true);
    expect(newPath.toPath(), '/');

    var newPath2 = matched.resolve('/url');
    expect(newPath2.extra, {});
  });
}
