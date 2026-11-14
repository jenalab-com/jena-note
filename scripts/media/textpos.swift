// 데모 앱 본문(AXTextArea)에서 문자열의 화면 좌표를 출력한다. 좌표는 화면 왼쪽 위 기준 포인트.
// usage: textpos <bundle-id> <substring> [occurrence(1부터)]
// 출력: <centerX> <centerY> <x> <y> <width> <height>
// 본문이 여러 개(사이드바 검색창 등)면 가장 넓은 텍스트 영역을 고른다.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
    FileHandle.standardError.write("usage: textpos <bundle-id> <substring> [occurrence]\n".data(using: .utf8)!)
    exit(2)
}
let needle = args[2]
let occurrence = args.count >= 4 ? max(1, Int(args[3]) ?? 1) : 1

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func width(_ e: AXUIElement) -> CGFloat {
    guard let v: AXValue = attr(e, kAXSizeAttribute) else { return 0 }
    var s = CGSize.zero
    AXValueGetValue(v, .cgSize, &s)
    return s.width
}

var areas: [AXUIElement] = []
func walk(_ e: AXUIElement, depth: Int) {
    guard depth < 40 else { return }
    if (attr(e, kAXRoleAttribute) as String?) == kAXTextAreaRole { areas.append(e) }
    for c in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth: depth + 1) }
}
let appEl = AXUIElementCreateApplication(app.processIdentifier)
guard let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) ?? (attr(appEl, kAXWindowsAttribute) as [AXUIElement]?)?.first else {
    FileHandle.standardError.write("window not found\n".data(using: .utf8)!)
    exit(1)
}
walk(win, depth: 0)
guard let area = areas.max(by: { width($0) < width($1) }),
      let text: String = attr(area, kAXValueAttribute) else {
    FileHandle.standardError.write("text area not found\n".data(using: .utf8)!)
    exit(1)
}

let ns = text as NSString
var search = NSRange(location: 0, length: ns.length)
var found = NSRange(location: NSNotFound, length: 0)
for _ in 0..<occurrence {
    found = ns.range(of: needle, options: [], range: search)
    guard found.location != NSNotFound else { break }
    search = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
}
guard found.location != NSNotFound else {
    FileHandle.standardError.write("not found: \(needle)\n".data(using: .utf8)!)
    exit(1)
}

var cfRange = CFRange(location: found.location, length: found.length)
let rangeValue = AXValueCreate(.cfRange, &cfRange)!
var boundsRef: CFTypeRef?
guard AXUIElementCopyParameterizedAttributeValue(area, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                 rangeValue, &boundsRef) == .success,
      let boundsValue = boundsRef else {
    FileHandle.standardError.write("bounds unavailable\n".data(using: .utf8)!)
    exit(1)
}
var r = CGRect.zero
AXValueGetValue(boundsValue as! AXValue, .cgRect, &r)
print(Int(r.midX), Int(r.midY), Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
