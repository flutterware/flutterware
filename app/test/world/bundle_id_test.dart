import 'dart:io';

import 'package:flutterware_app/src/world/bundle_id.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bundle_id_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void project(String configurations) =>
      write('ios/Runner.xcodeproj/project.pbxproj', _project(configurations));

  test("reads the Runner target's Debug configuration without a flavor", () {
    project(r'''
		A1 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.shop;
			};
			name = Debug;
		};
		A2 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.shop.release;
			};
			name = Release;
		};
		T1 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.shop.RunnerTests;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Runner.app/Runner";
			};
			name = Debug;
		};
''');
    expect(iosBundleId(root.path), 'com.example.shop');
  });

  test("reads the flavor's Debug configuration, whatever its case", () {
    project('''
		A1 /* Debug-staging */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.shop.staging";
			};
			name = "Debug-Staging";
		};
		A2 /* Debug-dev */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.shop.dev;
			};
			name = "Debug-dev";
		};
''');
    expect(
      iosBundleId(root.path, flavor: 'staging'),
      'com.example.shop.staging',
    );
    expect(iosBundleId(root.path, flavor: 'dev'), 'com.example.shop.dev');
    expect(iosBundleId(root.path, flavor: 'prod'), isNull);
  });

  test('fills in what the configuration and its xcconfig define', () {
    write('ios/Flutter/Debug.xcconfig', '''
#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"
#include "Shared.xcconfig"
APP_SUFFIX = .dev // the dev app installs beside the store one
''');
    write('ios/Flutter/Shared.xcconfig', 'APP_ID_BASE = com.example.shop\n');
    project(r'''
		A1 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = F1 /* Debug.xcconfig */;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "$(APP_ID_BASE)${APP_SUFFIX}";
			};
			name = Debug;
		};
''');
    expect(iosBundleId(root.path), 'com.example.shop.dev');
  });

  test('says nothing for a setting only Xcode knows', () {
    project(r'''
		A1 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.$(PRODUCT_NAME:rfc1034identifier)";
			};
			name = Debug;
		};
''');
    expect(iosBundleId(root.path), isNull);
  });

  test('says nothing without an iOS project', () {
    expect(iosBundleId(root.path), isNull);
  });

  test('parses the parts of a property list a project uses', () {
    expect(
      parseOpenStepPlist(r'''
// !$*UTF8*$!
{
	list = (a, "b c", /* a comment */ d,);
	"quoted \"key\"" = { nested = 1; };
}
'''),
      {
        'list': ['a', 'b c', 'd'],
        'quoted "key"': {'nested': '1'},
      },
    );
  });
}

/// A project whose application target `Runner` lists [configurations] whose
/// ids start with `A`, and whose test target lists those starting with `T`.
String _project(String configurations) {
  var ids = RegExp(
    r'^\t\t(\w+) /\*',
    multiLine: true,
  ).allMatches(configurations).map((m) => m[1]!).toList();
  String list(String prefix) => [
    for (var id in ids)
      if (id.startsWith(prefix)) '\t\t\t\t$id,\n',
  ].join();
  return '''
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	objects = {

/* Begin PBXFileReference section */
		F1 /* Debug.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Debug.xcconfig; path = Flutter/Debug.xcconfig; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXNativeTarget section */
		N1 /* Runner */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = L1 /* Build configuration list for PBXNativeTarget "Runner" */;
			name = Runner;
			productType = "com.apple.product-type.application";
		};
		N2 /* RunnerTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = L2;
			name = RunnerTests;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin XCBuildConfiguration section */
$configurations
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		L1 = {
			isa = XCConfigurationList;
			buildConfigurations = (
${list('A')}			);
		};
		L2 = {
			isa = XCConfigurationList;
			buildConfigurations = (
${list('T')}			);
		};
/* End XCConfigurationList section */
	};
	rootObject = R1;
}
''';
}
