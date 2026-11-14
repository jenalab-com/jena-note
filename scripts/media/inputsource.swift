// 키보드 입력 소스를 확인·전환한다. 영문 타이핑 녹화 동안 ABC로 바꿨다가 원래대로 돌린다.
// 한글 입력 상태에서는 System Events keystroke가 조합·자동 마침표에 걸려 글자가 깨진다.
// usage:
//   inputsource get        현재 입력 소스 ID 출력
//   inputsource set <id>   입력 소스 선택(예: com.apple.keylayout.ABC)
import Carbon

let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }

func sourceID(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

switch args[1] {
case "get":
    print(sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
case "set" where args.count >= 3:
    let filter = [kTISPropertyInputSourceID as String: args[2]] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first else {
        FileHandle.standardError.write("input source not found: \(args[2])\n".data(using: .utf8)!)
        exit(1)
    }
    TISEnableInputSource(source)
    exit(TISSelectInputSource(source) == noErr ? 0 : 1)
default:
    exit(2)
}
