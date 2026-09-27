// A page rendered to a picture by the WebKit macOS ships: no window on
// screen, nothing downloaded. Compiled on first use by the studio
// (web_snapshot.dart).
//
//   web_snapshot <page.html> <picture.png> <width>
//
// Answers on stdout, one line of JSON: the page's size in points and where
// each of its links is, so the picture can stay clickable:
//   {"width": 600, "height": 671, "links": [{"href", "text", "x", "y", "w", "h"}]}
// A failure is a line on stderr and a non-zero exit.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let width = Double(args[3]) else {
  FileHandle.standardError.write("usage: web_snapshot <page.html> <picture.png> <width>\n".data(using: .utf8)!)
  exit(64)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
  exit(1)
}

final class Snapper: NSObject, WKNavigationDelegate {
  let view: WKWebView

  init(width: Double) {
    let configuration = WKWebViewConfiguration()
    // A mail client runs no script a mail carries; the measuring below is
    // the snapshot's own.
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    view = WKWebView(
      frame: NSRect(x: 0, y: 0, width: width, height: 1),
      configuration: configuration)
    super.init()
    view.navigationDelegate = self
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail("the page did not load: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail("the page did not load: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // Measured while the view is one point tall, so the height is the
    // content's and not the view's.
    let measure = """
      JSON.stringify({
        height: document.documentElement.scrollHeight,
        links: [...document.links].map(a => {
          const r = a.getBoundingClientRect();
          return {href: a.href, text: a.innerText.trim(),
                  x: r.x, y: r.y + scrollY, w: r.width, h: r.height};
        })
      })
      """
    webView.evaluateJavaScript(measure) { value, error in
      guard let json = value as? String,
            let data = json.data(using: .utf8),
            var page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let height = page["height"] as? Double else {
        fail("could not measure the page: \(String(describing: error))")
      }
      webView.frame.size.height = height
      let configuration = WKSnapshotConfiguration()
      configuration.rect = NSRect(x: 0, y: 0, width: webView.frame.width, height: height)
      webView.takeSnapshot(with: configuration) { image, error in
        guard let image, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
          fail("could not take the picture: \(String(describing: error))")
        }
        do {
          try png.write(to: output)
        } catch {
          fail("could not write \(output.path): \(error.localizedDescription)")
        }
        page["width"] = webView.frame.width
        let answer = try! JSONSerialization.data(withJSONObject: page)
        FileHandle.standardOutput.write(answer)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        exit(0)
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let snapper = Snapper(width: width)
snapper.view.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fail("the page took over 20 s") }
app.run()
