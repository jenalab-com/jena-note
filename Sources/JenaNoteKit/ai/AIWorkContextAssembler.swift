import Foundation

/// 해석된 문맥 + 요약 저장소 → AIWorkPayload. 읽기 실패 파일은 건너뛰고 skipped에 모은다.
///
/// - Settings: raw text (open document wins, §6.7); files listed in `summarizedSettings` send their
///   cached summary instead (`summarized == true`). A summarized setting with no summary file falls
///   back to its raw text so a canonical setting is never silently dropped.
/// - Previous summaries: every earlier episode with a readable summary file, in episode order.
///   Episodes without one go to `skipped`.
/// - Previous episode: full disk text (§6.2), only when `includePreviousEpisode` is on.
/// - Outside the writing folder: settings only.
struct AIWorkContextAssembler {
    let resolved: AIResolvedWorkContext
    let store: AIEpisodeSummaryStore

    func payload(currentFile: URL) -> (payload: AIWorkPayload, skipped: [AIWorkFile]) {
        let current = resolved.currentIndex.map { resolved.episodes[$0].relativePath } ?? currentFile.lastPathComponent
        return build(currentEpisode: current)
    }

    func status(isGenerating: (Int, Int)?) -> AIWorkContextStatus {
        if let (done, total) = isGenerating { return .generating(done: done, total: total) }
        guard resolved.context.config.enabled else { return .disabled }
        let bytes = build(currentEpisode: "").payload.contextByteCount
        let index = store.snapshotIndex()
        let ready = resolved.previousEpisodes.filter {
            switch store.state(of: $0, isSetting: false, index: index) {
            case .ready, .manuallyEdited: return true
            case .missing, .stale: return false
            }
        }.count
        return .active(settingsCount: resolved.settings.count, contextBytes: bytes,
                       summariesReady: ready, summariesTotal: resolved.previousEpisodes.count,
                       previousEpisode: !resolved.isOutsideWritingFolder && resolved.previousEpisode != nil,
                       outsideWriting: resolved.isOutsideWritingFolder,
                       budget: AIPrompt.budget(for: bytes))
    }

    /// Settings files whose summary is sent instead of their text.
    var summarizedSettings: [AIWorkFile] {
        let keys = Set(resolved.context.config.summarizedSettings)
        return resolved.settings.filter { keys.contains($0.relativePath) }
    }

    private func build(currentEpisode: String) -> (payload: AIWorkPayload, skipped: [AIWorkFile]) {
        var skipped: [AIWorkFile] = []
        let summarizedKeys = Set(resolved.context.config.summarizedSettings)

        var settings: [AIWorkSetting] = []
        for file in resolved.settings {
            if summarizedKeys.contains(file.relativePath), let summary = store.summaryText(for: file, isSetting: true) {
                settings.append(AIWorkSetting(name: file.relativePath, text: summary, summarized: true))
            } else if let text = try? AIWorkContextResolver.readSettingText(file) {
                settings.append(AIWorkSetting(name: file.relativePath, text: text, summarized: false))
            } else {
                skipped.append(file)
            }
        }

        var summaries: [AIWorkSummary] = []
        var previousEpisode: AIWorkEpisodeText?
        if !resolved.isOutsideWritingFolder {
            for file in resolved.previousEpisodes {
                if let summary = store.summaryText(for: file, isSetting: false) {
                    summaries.append(AIWorkSummary(name: file.relativePath, summary: summary))
                } else {
                    skipped.append(file)
                }
            }
            if let file = resolved.previousEpisode {
                if let text = try? AIWorkContextResolver.readText(file) {
                    previousEpisode = AIWorkEpisodeText(name: file.relativePath, text: text)
                } else if !skipped.contains(file) {
                    skipped.append(file)
                }
            }
        }

        let payload = AIWorkPayload(title: resolved.context.config.title, currentEpisode: currentEpisode,
                                    settings: settings, previousSummaries: summaries,
                                    previousEpisode: previousEpisode)
        return (payload, skipped)
    }
}
