// 데모 앱의 화면에 보이는 모든 창을 뒤에서 앞 순서로 출력한다(툴팁·팝오버 감지용).
// usage: windows <bundle-id>
// 출력: 줄마다 <windowID> <x> <y> <width> <height>  (포인트, 화면 왼쪽 위 기준)
import AppKit

let args = CommandLine.arguments
guard args.count >= 2,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
    FileHandle.standardError.write("app not running\n".data(using: .utf8)!)
    exit(1)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
// 창 목록은 앞에서 뒤 순서다. 합성은 뒤에서부터 덮어야 하므로 뒤집는다.
for w in list.reversed() where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          (b["Width"] ?? 0) > 4, (b["Height"] ?? 0) > 4 else { continue }
    print(id, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
}
