import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/world/declared_links.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('declared_links_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  DeclaredLinks read() => DeclaredLinks.read(root.path);

  group('Info.plist', () {
    test("reads each URL type's schemes, lowercase", () {
      write(
        'ios/Runner/Info.plist',
        _plist(r'''
	<key>CFBundleDisplayName</key>
	<string>Example App</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>CFBundleURLName</key>
			<string>test.example.app</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>ExampleApp</string>
			</array>
		</dict>
		<dict>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>example-auth</string>
				<string>https</string>
			</array>
		</dict>
	</array>
	<key>UILaunchStoryboardName</key>
	<string>LaunchScreen</string>'''),
      );

      var links = read();

      expect(links.schemes, {'exampleapp', 'example-auth'});
      expect(links.hosts, isEmpty);
    });

    test('reads macOS and every Info*.plist beside Info.plist', () {
      write('ios/Runner/Info.plist', _urlTypes(['exampleapp']));
      write('ios/Runner/Info-Staging.plist', _urlTypes(['exampleapp-staging']));
      // Saved by an editor that leads with a byte order mark.
      write(
        'macos/Runner/Info.plist',
        String.fromCharCode(0xfeff) + _urlTypes(['exampleapp-desktop']),
      );
      // Not an Info plist, so what it says is not the app's.
      write('ios/Runner/Settings.plist', _urlTypes(['notthis']));

      expect(read().schemes, {
        'exampleapp',
        'exampleapp-staging',
        'exampleapp-desktop',
      });
    });

    test('skips a binary plist and build variables', () {
      write(
        'ios/Runner/Info.plist',
        _urlTypes([
          r'$(PRODUCT_BUNDLE_IDENTIFIER)',
          r'app-$(FLAVOR)',
          r'${SCHEME}',
          'exampleapp',
        ]),
      );
      var binary = File(p.join(root.path, 'macos/Runner/Info.plist'));
      binary.parent.createSync(recursive: true);
      binary.writeAsBytesSync([
        ...utf8.encode('bplist00'),
        0xd1,
        0x01,
        0x02,
        0x5f,
        0x10,
        0x10,
        ...utf8.encode('CFBundleURLTypes'),
        0x00,
      ]);

      expect(read().schemes, {'exampleapp'});
    });
  });

  group('entitlements', () {
    test('keeps applinks domains, without mode, wildcards intact', () {
      write(
        'ios/Runner/Runner.entitlements',
        _plist(r'''
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>applinks:example.test</string>
		<string>applinks:*.example.test</string>
		<string>applinks:Links.Example.test?mode=developer</string>
		<string>webcredentials:accounts.example.test</string>
		<string>applinks:$(LINK_HOST)</string>
	</array>'''),
      );
      write(
        'macos/Runner/Release.entitlements',
        _plist('''
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>applinks:desktop.example.test?mode=managed</string>
	</array>'''),
      );

      var links = read();

      expect(links.hosts, {
        'example.test',
        '*.example.test',
        'links.example.test',
        'desktop.example.test',
      });
      expect(links.schemes, isEmpty);
    });
  });

  group('AndroidManifest.xml', () {
    test('reads main and every flavor or build type', () {
      write(
        'android/app/src/main/AndroidManifest.xml',
        _manifest('''
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="shop.example.test"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="exampleapp"/>
            </intent-filter>'''),
      );
      write(
        'android/app/src/staging/AndroidManifest.xml',
        _manifest('''
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="exampleapp-staging"/>
                <data android:scheme="https" android:host="*.staging.example.test"/>
            </intent-filter>'''),
      );
      write('android/app/src/debug/AndroidManifest.xml', '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
''');

      var links = read();

      expect(links.schemes, {'exampleapp', 'exampleapp-staging'});
      expect(links.hosts, {'shop.example.test', '*.staging.example.test'});
    });

    test('pairs every scheme of a filter with every host in it', () {
      write(
        'android/app/src/main/AndroidManifest.xml',
        _manifest('''
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <data android:scheme="ExampleApp"/>
                <data android:scheme="https"/>
                <data android:host="Go.Example.test"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <data android:scheme="exampleapp" android:host="callback"/>
            </intent-filter>'''),
      );

      var links = read();

      expect(links.schemes, {'exampleapp'});
      // `callback` is a host under a custom scheme, not a web host.
      expect(links.hosts, {'go.example.test'});
    });

    test('ignores filters that are not VIEW, and unresolved values', () {
      write(
        'android/app/src/main/AndroidManifest.xml',
        _manifest(r'''
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <data android:scheme="notview"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <data android:scheme="${applicationId}"/>
                <data android:scheme="@string/link_scheme"/>
                <data android:scheme="https"/>
                <data android:host="${linkHost}"/>
                <data android:host="@string/link_host"/>
                <data android:host="*"/>
                <data android:host="www.example.test"/>
            </intent-filter>'''),
      );

      var links = read();

      expect(links.schemes, isEmpty);
      expect(links.hosts, {'www.example.test'});
    });
  });

  test('a malformed file declares nothing and costs the others nothing', () {
    write('ios/Runner/Info.plist', '<plist><dict><key>CFBundleURLTypes');
    write('ios/Runner/Runner.entitlements', 'not xml at all');
    write('android/app/src/main/AndroidManifest.xml', '<manifest><appl');
    write('macos/Runner/Info.plist', _urlTypes(['exampleapp']));

    var links = read();

    expect(links.schemes, {'exampleapp'});
    expect(links.hosts, isEmpty);
  });

  test('a project with no platform folders declares nothing', () {
    write('pubspec.yaml', 'name: example_app\n');

    var links = read();

    expect(links.isEmpty, isTrue);
    expect(links.claims('https://example.test/'), isFalse);
    expect(DeclaredLinks.read(p.join(root.path, 'missing')).isEmpty, isTrue);
  });

  group('claims', () {
    var links = DeclaredLinks(
      schemes: {'exampleapp'},
      hosts: {'example.test', '*.shop.example.test'},
    );

    test('a link on a custom scheme', () {
      expect(links.claims('exampleapp://order/42'), isTrue);
      expect(links.claims('ExampleApp://order/42'), isTrue);
      expect(links.claims('otherapp://order/42'), isFalse);
    });

    test('an http(s) link on a claimed host', () {
      expect(links.claims('https://example.test/order/42?ref=mail'), isTrue);
      expect(links.claims('http://Example.TEST/order/42'), isTrue);
      expect(links.claims('https://www.example.test/order/42'), isFalse);
    });

    test('a subdomain under a wildcard, but not the domain itself', () {
      expect(links.claims('https://eu.shop.example.test/cart'), isTrue);
      expect(links.claims('https://a.b.shop.example.test/cart'), isTrue);
      expect(links.claims('https://shop.example.test/cart'), isFalse);
      expect(links.claims('https://myshop.example.test/cart'), isFalse);
    });

    test('a store badge link is not claimed', () {
      expect(links.claims('https://apps.store.test/app/id123456789'), isFalse);
      expect(
        links.claims('https://market.store.test/details?id=test.example.app'),
        isFalse,
      );
    });

    test('a malformed link is not claimed', () {
      for (var link in [
        '',
        'not a link',
        'exampleapp',
        'https://',
        'https://[broken',
        '://example.test/order/42',
      ]) {
        expect(links.claims(link), isFalse, reason: link);
      }
    });

    test('a host under a custom scheme is not a web claim', () {
      var hostless = DeclaredLinks(schemes: {'exampleapp'});
      expect(hostless.claims('https://exampleapp/order/42'), isFalse);
    });
  });
}

String _plist(String body) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$body
</dict>
</plist>
''';

String _urlTypes(List<String> schemes) => _plist('''
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLSchemes</key>
			<array>
${[for (var scheme in schemes) '\t\t\t\t<string>$scheme</string>'].join('\n')}
			</array>
		</dict>
	</array>''');

String _manifest(String filters) =>
    '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="example_app" android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop">
$filters
        </activity>
    </application>
</manifest>
''';
