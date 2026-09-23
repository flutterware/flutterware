// The native layer's eyes and hands on Apple platforms.
//
// Compiled on demand by `AxNativeDriver` (see ax_driver.dart) and cached; it
// is source in the package rather than a checked-in binary so it needs no
// signing, no install step and no separate release. One invocation per
// command, JSON on stdin-free argv, one JSON line on stdout.
//
// It holds no accessibility grant of its own: macOS attaches that to the
// *responsible* process — the app that spawned us, the Studio GUI or a
// terminal — and a child inherits it. `trusted` is how the Dart side asks
// whether that inheritance actually happened.
//
// Element addressing is a path of child indices, re-walked and re-checked on
// every command, exactly as the drive layer treats its node ids: a stale path
// is a loud error, never a press that lands on the wrong thing.

import AppKit
import ApplicationServices

// MARK: - JSON plumbing

func fail(_ message: String, code: String = "error") -> Never {
  let payload: [String: Any] = ["ok": false, "error": message, "code": code]
  emit(payload)
  exit(1)
}

func emit(_ payload: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: payload)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

guard CommandLine.arguments.count > 1,
  let commandData = CommandLine.arguments[1].data(using: .utf8),
  let command = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any]
else {
  fail("usage: ax_helper '<json command>'", code: "usage")
}

let verb = command["cmd"] as? String ?? ""

// MARK: - Trust

// Asked before anything else: every other command is meaningless without it,
// and the answer tells the Dart side whether to prompt or to explain.
if verb == "trusted" {
  let shouldPrompt = command["prompt"] as? Bool ?? false
  let trusted: Bool
  if shouldPrompt {
    trusted = AXIsProcessTrustedWithOptions(
      ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  } else {
    trusted = AXIsProcessTrusted()
  }
  emit(["ok": true, "trusted": trusted])
  exit(0)
}

guard AXIsProcessTrusted() else {
  fail(
    "This process is not trusted for accessibility.",
    code: "untrusted")
}

// MARK: - Target application

guard let appQuery = command["app"] as? String else {
  fail("`app` is required: a bundle id or an application name", code: "usage")
}

// A bundle *path* identifies one running app exactly; a name does not. Two
// checkouts of the same project produce two apps with the same name, and
// attaching to whichever the window server lists first would drive somebody
// else's window — measured, on the machine this was built on.
let running = NSWorkspace.shared.runningApplications
guard
  let app = running.first(where: {
    $0.bundleURL?.path == appQuery || $0.bundleURL?.path == appQuery + "/"
  })
    ?? running.first(where: {
      $0.bundleIdentifier == appQuery || $0.localizedName == appQuery
    })
else {
  fail(
    appQuery.hasSuffix(".app")
      ? "No running application was launched from \(appQuery). It may have "
        + "been rebuilt since, or stopped."
      : "No running application matches \"\(appQuery)\"",
    code: "noApp")
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// MARK: - Attribute helpers

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
  attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
  guard let positionValue = attribute(element, kAXPositionAttribute),
    let sizeValue = attribute(element, kAXSizeAttribute)
  else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
  return CGRect(origin: point, size: size)
}

/// What this element says, from whichever attribute the platform filled in.
///
/// Joined rather than picked: a Simulator address field carries its role
/// description in one attribute and its contents in another, and an agent
/// looking for either should find the element.
func label(_ element: AXUIElement) -> String? {
  let parts = [
    string(element, kAXTitleAttribute),
    string(element, kAXDescriptionAttribute),
    attribute(element, kAXValueAttribute) as? String,
  ]
  let joined = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
  return joined.isEmpty ? nil : joined
}

func isActionable(_ element: AXUIElement) -> Bool {
  guard let actions = attribute(element, "AXActions") as? [String] else { return false }
  return actions.contains(kAXPressAction as String)
}

// MARK: - Scope

/// The window this command addresses, or the whole application.
///
/// Scoping matters for more than tidiness on the simulator: walked at
/// application level, the tree includes the host's own menu bar — the user's
/// recent documents among it — which is both noise in every reply and other
/// people's business in an agent's context.
func scopedRoots() -> [AXUIElement] {
  let windows = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  guard let wanted = command["window"] as? String, !wanted.isEmpty else {
    return windows.isEmpty ? [axApp] : windows
  }
  let matching = windows.filter { ($0.windowTitle() ?? "").hasPrefix(wanted) }
  if matching.isEmpty {
    let titles = windows.compactMap { $0.windowTitle() }
    fail(
      "No window of \(appQuery) starts with \"\(wanted)\". It has: "
        + (titles.isEmpty ? "no titled windows" : titles.joined(separator: ", ")),
      code: "noWindow")
  }
  // The simulator's window is a device *and* a piece of Mac furniture: bezel
  // buttons, a toolbar, Home, Rotate, Save Screen. Left in, they read as part
  // of the app — an agent looking for a way out of a screen would find a
  // "Home" button that is really the simulator's, and press it. So the device
  // screen is scoped to on its own: the largest group in the window, which is
  // the simulated display and nothing else.
  if command["scope"] as? String == "device" {
    return matching.compactMap { deviceScreen(of: $0) ?? $0 }
  }
  return matching
}

/// The simulated display inside a simulator window.
func deviceScreen(of window: AXUIElement) -> AXUIElement? {
  var best: (AXUIElement, CGFloat)?
  for child in children(window) {
    guard string(child, kAXRoleAttribute) == kAXGroupRole as String,
      let box = frame(child)
    else { continue }
    let area = box.width * box.height
    if best == nil || area > best!.1 { best = (child, area) }
  }
  return best?.0
}

extension AXUIElement {
  func windowTitle() -> String? { string(self, kAXTitleAttribute) }
}

// MARK: - Walk

/// Serialises the tree, tagging every node with the child-index path that
/// reaches it. Depth capped: an accessibility tree can contain a cycle, and a
/// menu tree is deep enough to be pointless.
func serialise(_ element: AXUIElement, path: String, depth: Int) -> [String: Any] {
  var node: [String: Any] = [
    "role": string(element, kAXRoleAttribute) ?? "AXUnknown",
    "path": path,
  ]
  if let text = label(element) { node["label"] = text }
  if let box = frame(element) {
    node["bounds"] = [
      "x": box.origin.x, "y": box.origin.y,
      "width": box.size.width, "height": box.size.height,
    ]
  }
  if isActionable(element) { node["clickable"] = true }
  if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled {
    node["enabled"] = false
  }
  if let focused = attribute(element, kAXFocusedAttribute) as? Bool, focused {
    node["focused"] = true
  }
  // A checkbox reports its state as its value; anything else's value is text
  // and already read as the label.
  if string(element, kAXRoleAttribute) == "AXCheckBox",
    let state = attribute(element, kAXValueAttribute) as? Int
  {
    node["checked"] = state != 0
  }
  if depth < 40 {
    let kids = children(element)
    if !kids.isEmpty {
      node["children"] = kids.enumerated().map { index, child in
        serialise(child, path: path.isEmpty ? "\(index)" : "\(path).\(index)", depth: depth + 1)
      }
    }
  }
  return node
}

/// Walks a path back to its element, refusing rather than guessing.
func element(at path: String, from roots: [AXUIElement]) -> AXUIElement {
  let steps = path.split(separator: ".").compactMap { Int($0) }
  guard let first = steps.first, first < roots.count else {
    fail("No element at path \(path) — the screen has changed.", code: "stale")
  }
  var current = roots[first]
  for step in steps.dropFirst() {
    let kids = children(current)
    guard step < kids.count else {
      fail("No element at path \(path) — the screen has changed.", code: "stale")
    }
    current = kids[step]
  }
  return current
}

/// The check that makes a path safe to act on.
///
/// A path is a shape, and shapes go stale: between the walk that produced one
/// and the press that uses it, a row can be inserted and the same path can now
/// reach a different button. Re-reading the label and comparing is what turns
/// that from a silent wrong press into a refusal.
func verify(_ element: AXUIElement, expects expected: String?) {
  guard let expected = expected else { return }
  let actual = label(element) ?? ""
  if actual != expected {
    fail(
      "That element is now \"\(actual)\", not \"\(expected)\" — the screen "
        + "changed under the step. Observe again and retry.",
      code: "stale")
  }
}

/// Which process owns the frontmost on-screen window covering [point].
///
/// `CGWindowListCopyWindowInfo` lists front to back, so the first hit is what
/// a click would reach. Bounds and owner pid need no screen-recording grant —
/// only window *titles* do, and none are read here. Nil when nothing covers
/// the point, or when the list cannot be had: an unknown owner is not
/// evidence of a wrong one, and refusing on it would break clicking on a
/// machine that answers no list.
func ownerOfWindow(at point: CGPoint) -> pid_t? {
  guard
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
      as? [[String: Any]]
  else { return nil }
  for window in list {
    // Negative layers are the desktop and its picture; the cursor and menu
    // bar sit above. Neither is something a click is aimed at.
    if let layer = window[kCGWindowLayer as String] as? Int, layer < 0 { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      rect.contains(point)
    else { continue }
    return (window[kCGWindowOwnerPID as String] as? pid_t)
  }
  return nil
}

/// The item at the end of [titles] in the app's menu bar — `File`, `Open
/// Simulator`, `iOS 18.1`, `iPhone 16`.
///
/// Titles, compared exactly, one level at a time: an item with a submenu holds
/// its items inside an `AXMenu`, which is looked through rather than named.
/// Exact, because the simulator's menus pair every device with an alternate
/// spelling of it (`iOS 18.1 (22B81) - iPhone 16`), and a prefix match would
/// press whichever came first.
func menuItem(_ titles: [String]) -> AXUIElement {
  guard let bar = attribute(axApp, kAXMenuBarAttribute) else {
    fail("\(appQuery) has no menu bar yet.", code: "noMenu")
  }
  var level = bar as! AXUIElement
  for (depth, wanted) in titles.enumerated() {
    let items = children(level).flatMap { child in
      string(child, kAXRoleAttribute) == kAXMenuRole as String ? children(child) : [child]
    }
    guard let found = items.first(where: { string($0, kAXTitleAttribute) == wanted }) else {
      let offered = items.compactMap { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
      fail(
        "No menu item \"\(wanted)\" under \(depth == 0 ? "the menu bar" : titles[..<depth].joined(separator: " › ")). "
          + "It has: \(offered.isEmpty ? "nothing" : offered.joined(separator: ", "))",
        code: "noMenu")
    }
    level = found
  }
  return level
}

// MARK: - Commands

// The one command that needs no window: it is how a window gets opened.
let roots = verb == "menu" ? [] : scopedRoots()

switch verb {
case "observe":
  let trees = roots.enumerated().map { index, root in
    serialise(root, path: "\(index)", depth: 0)
  }
  emit([
    "ok": true,
    "scale": NSScreen.main?.backingScaleFactor ?? 1,
    "roots": trees,
  ])

case "press":
  var target: AXUIElement
  if let path = command["path"] as? String {
    target = element(at: path, from: roots)
    verify(target, expects: command["expect"] as? String)
  } else if let wanted = command["label"] as? String {
    // By label, for the few elements the Dart side knows by name rather than
    // by walk — the simulator's own Home button, pressed to un-suspend an app.
    //
    // `in` narrows the search to inside elements of one role. A device with a
    // Home button has two labelled "Home": the toolbar's, and one drawn in the
    // bezel that accepts the press and does nothing (measured, iPhone SE).
    let within = command["in"] as? String
    var found: [AXUIElement] = []
    func search(_ element: AXUIElement, depth: Int, inside: Bool) {
      let here = inside || within == nil || string(element, kAXRoleAttribute) == within
      if here && label(element) == wanted { found.append(element) }
      if depth >= 40 { return }
      for child in children(element) { search(child, depth: depth + 1, inside: here) }
    }
    for root in roots { search(root, depth: 0, inside: false) }
    guard found.count == 1 else {
      fail(
        found.isEmpty
          ? "Nothing here is labelled \"\(wanted)\"."
          : "\(found.count) elements are labelled \"\(wanted)\".",
        code: found.isEmpty ? "stale" : "ambiguous")
    }
    target = found[0]
  } else {
    fail("`path` or `label` is required for press", code: "usage")
  }
  // The element's own press action, not a click at its centre: it needs no
  // coordinates, and — unlike a synthetic click — it works on a window that
  // is not frontmost.
  let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
  if status != .success {
    fail(
      "The platform refused to press that element (AX error \(status.rawValue)). "
        + "If it is a plain view rather than a control, tap it by point instead: "
        + "{\"at\": {\"x\": …, \"y\": …}}.",
      code: "notPressable")
  }
  emit(["ok": true])

case "click":
  guard let x = command["x"] as? Double, let y = command["y"] as? Double else {
    fail("`x` and `y` are required for click", code: "usage")
  }
  // A synthetic click only lands when the target app owns the front window,
  // and only when it carries a click count — all three ingredients were found
  // the hard way (S-N2, 2026-08-12).
  app.activate()
  if let window = roots.first {
    AXUIElementPerformAction(window, "AXRaise" as CFString)
  }
  usleep(250_000)
  let point = CGPoint(x: x, y: y)
  // Raised first, checked after: this posts a real HID event at a screen
  // coordinate, so a point outside this app lands in whatever else is there —
  // reported by a consumer whose click went into an unrelated application.
  // Asked of the window server rather than of the window frames, because the
  // legitimate targets that are not in the frames are real: a menu the app
  // opened, a sheet, a popover. All of them are windows this app owns.
  if let owner = ownerOfWindow(at: point), owner != app.processIdentifier {
    let other = NSRunningApplication(processIdentifier: owner)?.localizedName
    fail(
      "\(Int(x)),\(Int(y)) is not over \(app.localizedName ?? appQuery) — "
        + (other.map { "\($0) owns the window there" } ?? "another application owns the window there")
        + ". Nothing was clicked. Coordinates on this layer are screen "
        + "points; a point read off the screenshot is relative to the "
        + "picture's own origin, which the reply states.",
      code: "outsideApp")
  }
  let move = CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
    mouseButton: .left)
  move?.post(tap: .cghidEventTap)
  usleep(40_000)
  let down = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
    mouseButton: .left)
  let up = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
    mouseButton: .left)
  down?.setIntegerValueField(.mouseEventClickState, value: 1)
  up?.setIntegerValueField(.mouseEventClickState, value: 1)
  down?.post(tap: .cghidEventTap)
  usleep(60_000)
  up?.post(tap: .cghidEventTap)
  emit(["ok": true])

case "foreground":
  app.activate()
  if let window = roots.first {
    AXUIElementPerformAction(window, "AXRaise" as CFString)
  }
  emit(["ok": true])

case "menu":
  guard let titles = command["path"] as? [String], !titles.isEmpty else {
    fail("`path` is required for menu: the item titles, outermost first", code: "usage")
  }
  // Pressed where it sits: a menu item's action runs without its menu being
  // opened first.
  let status = AXUIElementPerformAction(menuItem(titles), kAXPressAction as CFString)
  if status != .success {
    fail(
      "The platform refused to press \(titles.joined(separator: " › ")) "
        + "(AX error \(status.rawValue)).",
      code: "notPressable")
  }
  emit(["ok": true])

default:
  fail(
    "Unknown command \"\(verb)\". This helper does: trusted, observe, press, "
      + "click, foreground, menu.", code: "usage")
}
