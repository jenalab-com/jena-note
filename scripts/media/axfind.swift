// 데모 앱 창에서 접근성 이름(설명·제목·도움말·문자열 값)이 일치하는 요소의 화면 중심 좌표를 출력한다.
// AppleScript의 entire contents보다 훨씬 빨라 녹화 중 대기(응답 완료 감지 등)에 쓴다.
// usage: axfind <bundle-id> <label> [role]
// 출력: <centerX> <centerY>  (없으면 종료 코드 1)
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
    FileHandle.standardError.write("usage: axfind <bundle-id> <label> [role]\n".data(using: .utf8)!)
    exit(2)
}
let label = args[2]
let role = args.count >= 4 ? args[3] : nil

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 40 else { return nil }
    let names = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXValueAttribute].compactMap { attr(e, $0) as String? }
    if names.contains(label), role == nil || (attr(e, kAXRoleAttribute) as String?) == role { return e }
    for c in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
        if let hit = find(c, depth: depth + 1) { return hit }
    }
    return nil
}

let appEl = AXUIElementCreateApplication(app.processIdentifier)
for win in (attr(appEl, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
    guard let hit = find(win, depth: 0),
          let p: AXValue = attr(hit, kAXPositionAttribute),
          let s: AXValue = attr(hit, kAXSizeAttribute) else { continue }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt)
    AXValueGetValue(s, .cgSize, &sz)
    print(Int(pt.x + sz.width / 2), Int(pt.y + sz.height / 2))
    exit(0)
}
exit(1)
