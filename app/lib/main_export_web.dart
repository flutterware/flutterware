import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutterware/comparison_report.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;

import 'src/comparison/web_viewer.dart';
import 'src/scenarios/web_report.dart';
import 'src/scenarios/web_viewer.dart';
import 'src/ui/loading_state.dart';
import 'src/ui/theme.dart';

/// The entry point of every exported page.
///
/// Data-free on purpose: the bundle this compiles to knows nothing about any
/// particular run or comparison, so it is built once, cached, and copied
/// beside whatever an export just wrote. That is what makes exporting a file
/// copy instead of a minute of `flutter build web`.
///
/// One bundle for both exports, not one each, because what a page *is* was
/// already written beside it: a comparison export writes `index.json`, a
/// scenario export writes `report.json`, and no page has both. So the two
/// compiles this replaces were the same viewer code paying for its identity
/// twice — the entry point asks for the files instead, and hands the body to
/// the viewer it names so nothing is fetched a second time.
void main() {
  // The engine's default strategy owns the browser history: it rewrites the
  // URL during boot — dropping the fragment a deep link arrived on — and
  // answers any outside change with a navigation back. This page's address
  // *is* its fragment, kept by the comparison viewer, so the engine is told
  // to leave the URL alone.
  setUrlStrategy(null);
  WidgetsFlutterBinding.ensureInitialized();
  // Semantics from the first frame. Without them the page is one canvas: a
  // screen reader finds nothing in it, and neither does anything else that
  // reads a page — the tab name is the only text a browser knows it holds.
  _semantics = SemanticsBinding.instance.ensureSemantics();
  runApp(ExportViewerApp(base: Uri.base));
}

/// Held for the life of the page; disposing it would turn semantics back off.
// ignore: unused_element
SemanticsHandle? _semantics;

class ExportViewerApp extends StatefulWidget {
  const ExportViewerApp({super.key, required this.base});

  /// What the data file and everything it names are resolved against — the
  /// page's own URL, so a page moved to another host or a subdirectory still
  /// finds its own files.
  final Uri base;

  @override
  State<ExportViewerApp> createState() => _ExportViewerAppState();
}

class _ExportViewerAppState extends State<ExportViewerApp> {
  /// The viewer this page turned out to be, with the body it was decided on.
  Widget? _viewer;
  String? _title;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_dispatch());
  }

  /// The comparison's file first — its page pays nothing extra that way — and
  /// the scenario report on a 404, which is cheap.
  Future<void> _dispatch() async {
    if (await _fetch('index.json') case var raw?) {
      if (!mounted) return;
      setState(() {
        _title = _titleOr('Comparison', () {
          return comparisonPageTitle(
            ComparisonIndex.fromJson((jsonDecode(raw) as Map).cast()),
          );
        });
        _viewer = ComparisonWebViewer(base: widget.base, raw: raw);
      });
      return;
    }
    if (await _fetch(scenarioWebReportFile) case var raw?) {
      if (!mounted) return;
      setState(() {
        _title = _titleOr('Scenarios', () {
          return ScenarioWebReport.fromJson((jsonDecode(raw) as Map).cast())
              .title;
        });
        _viewer = ScenarioWebViewer(base: widget.base, raw: raw);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _error =
          'This page could not read its own index.json or '
          '$scenarioWebReportFile. An exported page has to be served over '
          'HTTP — opening index.html from the filesystem leaves the browser '
          'unable to fetch anything beside it.';
    });
  }

  /// The tab's name out of the file, or [fallback] when the file will not
  /// read — in which case the viewer is about to say so on the page.
  static String _titleOr(String fallback, String Function() read) {
    try {
      return read();
    } catch (_) {
      return fallback;
    }
  }

  /// The file's body, or null when it is not there.
  ///
  /// "There" means it answers 200 *and* looks like JSON: a host that rewrites
  /// every path to the app shell answers 200 with HTML for anything, and
  /// dispatching on that would hand a scenario page to the comparison viewer.
  Future<String?> _fetch(String name) async {
    try {
      var response = await http.get(widget.base.resolve(name));
      if (response.statusCode != 200) return null;
      var body = response.body;
      return body.trimLeft().startsWith('{') ? body : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: _title ?? 'flutterware',
    theme: appTheme,
    debugShowCheckedModeBanner: false,
    home:
        _viewer ??
        Scaffold(
          body: _error == null
              ? const LoadingState(title: 'Loading…')
              : Builder(
                  builder: (context) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(FwSpacing.xl),
                      child: SelectableText(
                        _error!,
                        style: context.type.bodyMuted,
                      ),
                    ),
                  ),
                ),
        ),
  );
}
