// 데모 앱 창의 CGWindowID와 화면 좌표(포인트)를 출력한다.
// usage: swift window.swift <bundle-id> [title-substring]
// 출력: <windowID> <x> <y> <width> <height>  (제목 필터가 없으면 가장 큰 창, 있으면 맨 앞 창)
import AppKit

let args = CommandLine.arguments
guard args.count >= 2,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
    FileHandle.standardError.write("app not running\n".data(using: .utf8)!)
    exit(1)
}
let titleFilter = args.count >= 3 ? args[2] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter {
    ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
        && ($0[kCGWindowLayer as String] as? Int) == 0
        && (titleFilter == nil || (($0[kCGWindowName as String] as? String) ?? "").contains(titleFilter!))
}
func area(_ w: [String: Any]) -> CGFloat {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
// 창 목록은 앞에서 뒤 순서다. 제목이 겹칠 수 있는 보조 창(정보·비교)은 맨 앞 창을 고른다.
guard let win = titleFilter != nil ? windows.first : windows.max(by: { area($0) < area($1) }),
      let id = win[kCGWindowNumber as String] as? Int,
      let b = win[kCGWindowBounds as String] as? [String: CGFloat] else {
    FileHandle.standardError.write("window not found\n".data(using: .utf8)!)
    exit(1)
}
print(id, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
