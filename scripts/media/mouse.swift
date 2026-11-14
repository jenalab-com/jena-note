// 데모 녹화용 마우스 조작. 좌표는 화면 왼쪽 위 기준 포인트(접근성 좌표와 같다).
// usage:
//   mouse move  x y [seconds]   부드럽게 이동
//   mouse click x y [seconds]   이동 후 클릭
//   mouse dclick x y [seconds]  이동 후 더블클릭
//   mouse rclick x y [seconds]  이동 후 우클릭
//   mouse cmdclick x y [seconds] 이동 후 ⌘클릭(추가 선택)
//   mouse scroll dy [steps]     세로 스크롤(픽셀, 음수 = 아래로)
import AppKit

let args = CommandLine.arguments
func num(_ i: Int, _ fallback: Double) -> Double { args.count > i ? Double(args[i]) ?? fallback : fallback }

func current() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

var flags: CGEventFlags = []

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.flags = flags
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

func move(to target: CGPoint, seconds: Double) {
    let start = current()
    let steps = max(1, Int(seconds * 90))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let k = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease-in-out
        post(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * k, y: start.y + (target.y - start.y) * k))
        usleep(useconds_t(seconds / Double(steps) * 1_000_000))
    }
}

func click(_ p: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) {
    let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    for n in 1...count {
        post(down, p, button, clicks: n); usleep(40_000)
        post(up, p, button, clicks: n); usleep(90_000)
    }
}

guard args.count >= 2 else { exit(2) }
switch args[1] {
case "scroll":
    let total = num(2, -300), steps = Int(num(3, 20))
    for _ in 0..<steps {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: Int32(total / Double(steps)), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
default:
    let p = CGPoint(x: num(2, 0), y: num(3, 0))
    move(to: p, seconds: num(4, 0.6))
    usleep(120_000)
    switch args[1] {
    case "click": click(p)
    case "dclick": click(p, count: 2)
    case "rclick": click(p, button: .right)
    case "cmdclick": flags = .maskCommand; click(p)
    default: break
    }
}
