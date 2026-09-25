import '../native_plugin.dart';
import '../registry.dart';
import 'assets_plugin.dart';
import 'dependencies_plugin.dart';
import 'dev_stack_core.dart';
import 'dev_stack_plugin.dart';
import 'icon_plugin.dart';
import 'lints_core.dart';
import 'lints_plugin.dart';
import 'run_plugin.dart';
import 'server_plugin.dart';
import 'renders_plugin.dart';
import 'scenarios_plugin.dart';
import 'scene_plugin.dart';
import 'splash_plugin.dart';
import 'store_plugin.dart';
import 'previews_plugin.dart';
import 'translations_plugin.dart';
import 'worlds_plugin.dart';

/// The panels compiled into this GUI binary.
///
/// v1 is first-party only, so this map *is* the extension point. A project can
/// choose and configure what it uses in `tool/flutterware.dart`, but it cannot
/// add to this list without a new GUI build — which is exactly why an unknown
/// id resolves to a visible [MissingPlugin] rather than nothing.
///
/// The ids here must also appear in `defaultCoreRegistry()`: a panel is drawn
/// over a core, so registering one without the other gets the plugin a
/// [MissingPlugin] and says why.
PluginRegistry buildNativeRegistry() => PluginRegistry({
  assetsPluginId: panelFor<AssetsCore>(AssetsPlugin.new),
  dependenciesPluginId: panelFor<DependenciesCore>(DependenciesPlugin.new),
  runPluginId: panelFor<RunCore>(RunPlugin.new),
  serverPluginId: panelFor<ServerCore>(ServerPlugin.new),
  scenariosPluginId: panelFor<ScenariosCore>(ScenariosPlugin.new),
  scenePluginId: panelFor<SceneCore>(ScenePlugin.new),
  rendersPluginId: panelFor<RendersCore>(RendersPlugin.new),
  launcherIconPluginId: panelFor<LauncherIconCore>(LauncherIconPlugin.new),
  splashPluginId: panelFor<SplashCore>(SplashPlugin.new),
  storePluginId: panelFor<StoreCore>(StorePlugin.new),
  uiCatalogPluginId: panelFor<PreviewsCore>(PreviewsPlugin.new),
  devStackPluginId: panelFor<DevStackCore>(DevStackPlugin.new),
  translationsPluginId: panelFor<TranslationsCore>(TranslationsPlugin.new),
  lintsPluginId: panelFor<LintsCore>(LintsPlugin.new),
  worldsPluginId: panelFor<WorldsCore>(WorldsPlugin.new),
});
