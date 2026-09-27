# Worlds: showing a web page — spike findings

2026-09-27. The question: can a world show web content itself — a mail's
HTML first, and later a third party's page or a person using a browser — and
which way can it rely on? Four ways were compared on macOS, on one realistic
transactional mail (inline CSS, a table, a remote image, a code, a button
carrying an app link, two web links).

Mail itself reaches the world as the project reports it (a `mail` event with
its HTML); flutterware reads no third-party catcher. This spike is only about
showing what arrives.

## What was measured

| | A webview in the studio | A WebKit snapshot | Headless Chrome | The outside browser |
|---|---|---|---|---|
| What | `webview_flutter` (WKWebView) as a platform view | a Swift helper renders the page to a PNG with the WebKit macOS ships | `package:puppeteer` driving the installed Chrome | write the page to a file, open it |
| First page | 654 ms cold, 151 ms warm | 0.42–0.55 s a render, process start and the remote image included | 0.84 s launch, 1.85 s first render, 1.12 s each after | — |
| Setup | one more plugin in the studio's build | `swiftc` once: 0.71 s, 88 KB | Chrome installed, or a download of well over 100 MB | none |
| Clicks | routed: `onNavigationRequest` saw the app link and the web link, and prevented both | a picture, plus each link's box from the page (`getBoundingClientRect`), so the studio can draw it clickable | a picture | followed by the browser: an app link goes to the OS, not to the person's app |
| On the canvas | composes under Flutter widgets, follows a `Transform.scale` (50 %, 200 %) and a `ClipRect` | an image: zooms, clips, photographs like any widget | an image | not on it |
| Seen by flutterware's own screenshots | no: a native view is a hole in the Flutter layer | yes | yes | no |
| Interactive | yes: a form, a script, a checkout | no | no | yes |
| Fidelity | WebKit | WebKit, identical | Chrome; `-apple-system` fell back to Helvetica | the user's browser |
| Beyond macOS | iOS/Android only | no | yes | yes |

Details worth keeping:

- **The plugin costs the studio next to nothing.** A blank macOS app built
  in release in 26.1 s without `webview_flutter` and 23.7 s with it, from
  clean: noise. The studio already builds four native plugins (`file_picker`,
  `file_selector`, `package_info_plus`, `url_launcher`) with a Podfile, so a
  webview adds a fifth through machinery every user already pays for — not
  the new cost the design assumed. On this machine the plugin came through
  Swift Package Manager (`enable-swift-package-manager: true`).
- **A magnified page is a scaled bitmap.** At 200 % the webview's text is
  soft, as the guests' was before they re-rendered at size; WebKit's page
  zoom is the equivalent fix once a zoom settles.
- **An app can photograph its own window, native views included, without
  asking.** `CGWindowListCreateImage` on the app's own window number needed
  no Screen Recording permission and returned the page composited with the
  Flutter widget over it. That is the way round the hole in flutterware's
  own screenshots, for any native view in the studio.
- **The snapshot helper has a precedent.** The native accessibility layer
  already compiles a Swift helper from source shipped beside the Dart code,
  cached by the source's hash (`ensureHelper`,
  `app/lib/src/run/native/ax_driver.dart`); a WebKit helper would be the
  second. It needs the Xcode command line tools, as that one does.
- **The snapshot measures the page's own height** once the view is made
  short first; a tall view reports its own height instead.

## Not measured

- Pointer gestures between the canvas's pan and zoom and a native view
  under it: whether a drag over a webview moves the stage or the page.
  Nothing here could synthesize input into the test window.
- Memory: each WKWebView page is served by a WebContent process of its own;
  several on one canvas were not tried.
- Keyboard focus passing between Flutter and the page.

## What it suggests

- **For a mail, and anything read rather than used: the WebKit snapshot.**
  It is a picture the studio owns — it zooms with the canvas, lands in
  screenshots and history, and an agent sees it — with each link drawn
  clickable and routed like a delivery. No download, half a second, and a
  helper pattern flutterware already maintains.
- **For a page someone has to use — a checkout, a consent screen, a person
  in a browser: the studio webview.** It holds up in everything tested:
  loading, routing every click, composing under Flutter, following the
  canvas's transform and clip. Open before relying on it for a whole world:
  gestures over it, memory with several at once.
- **Headless Chrome only if worlds leave macOS.** It is slower, needs a
  Chrome, and renders the system fonts differently.
- **The outside browser as an escape hatch,** never the way: an app link
  opened there goes to the OS instead of to the person.
