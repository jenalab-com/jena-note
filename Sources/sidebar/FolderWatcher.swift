import Foundation
import CoreServices

/// FSEvents 기반 폴더 변경 감시기.
///
/// 등록된 모든 폴더에 대해 단일 FSEventStream을 운용한다.
/// 콜백은 메인 큐에서 200ms debounce 후 `.folderContentsDidChange` 알림을 발행한다.
/// (ADR-0005)
final class FolderWatcher {

    static let shared = FolderWatcher()

    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.2

    private init() {}

    // MARK: - Public API

    func startWatching(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        watchedPaths = paths

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, _, _, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleNotification(eventCount: numEvents)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watchedPaths = []
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    func restart(with paths: [String]) {
        startWatching(paths)
    }

    // MARK: - Private

    private func scheduleNotification(eventCount: Int) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .folderContentsDidChange, object: nil)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
