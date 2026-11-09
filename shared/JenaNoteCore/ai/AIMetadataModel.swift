import Foundation

public struct AIModelOption {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct AIQuota {
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public var modelName: String? = nil

    public init(title: String, usedPercent: Double, resetsAt: Date?, modelName: String? = nil) {
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.modelName = modelName
    }

    public func resetCountdown(now: Date = Date()) -> String {
        guard let resetsAt else { return "—" }
        let minutes = Int(ceil(max(0, resetsAt.timeIntervalSince(now)) / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public func compactSummary(now: Date = Date()) -> String {
        let percent = String(format: "%.0f", usedPercent) + "%"
        return percent + " " + (modelName ?? resetCountdown(now: now))
    }

    public var summary: String { "\(title) \(String(format: "%.0f", usedPercent))%" }
}

public struct AIMetadata {
    public var models: [AIModelOption] = []
    public var quotas: [AIQuota] = []
    public var usageAvailable = false

    public init() {}

    /// `grok models` prints a table. Only rows naming a Grok model count.
    public static func grokModels(from output: String) -> [AIModelOption] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, ["*", "-"].contains(String(words[0])), words[1].hasPrefix("grok-") else { return nil }
            let id = String(words[1])
            return AIModelOption(id: id, title: id)
        }
    }

    /// Offered when a CLI cannot list its models.
    public static func fallbackModels(for provider: AIProvider) -> [String] {
        switch provider {
        case .claude: return ["opus", "sonnet", "haiku"]
        case .gemini: return ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash"]
        case .codex, .grok: return []
        }
    }

    public static func claude(models: [String: Any], usage: [String: Any]) -> AIMetadata {
        var result = AIMetadata()
        result.models = (models["models"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["value"] as? String, id != "default" else { return nil }
            return AIModelOption(id: id, title: $0["displayName"] as? String ?? id)
        }
        guard let limits = usage["rate_limits"] as? [String: Any] else { return result }
        // The normalized list includes model-specific limits on recent CLI versions.
        if let rows = limits["limits"] as? [[String: Any]], !rows.isEmpty {
            for row in rows {
                guard let percent = (row["percent"] as? NSNumber)?.doubleValue, percent.isFinite else { continue }
                let group = row["group"] as? String ?? ""
                var title = group == "session" ? L10n.tr("ai.quotaSession") : group == "weekly" ? L10n.tr("ai.quotaWeekly") : group == "monthly" ? L10n.tr("ai.quotaMonth") : group
                var modelName: String?
                if let scope = row["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String { title += " (\(name))"; modelName = name }
                result.quotas.append(AIQuota(title: title, usedPercent: percent, resetsAt: date(row["resets_at"]), modelName: modelName))
            }
        } else {
            for (key, title) in [("five_hour", "ai.quotaSession"), ("seven_day", "ai.quotaWeekly"),
                                  ("seven_day_opus", "ai.quotaWeekly"), ("seven_day_sonnet", "ai.quotaWeekly")] {
                guard let row = limits[key] as? [String: Any], let percent = (row["utilization"] as? NSNumber)?.doubleValue, percent.isFinite else { continue }
                let suffix = key == "seven_day_opus" ? " (Opus)" : key == "seven_day_sonnet" ? " (Sonnet)" : ""
                result.quotas.append(AIQuota(title: L10n.tr(title) + suffix, usedPercent: percent, resetsAt: date(row["resets_at"]),
                                             modelName: key == "seven_day_opus" ? "Opus" : key == "seven_day_sonnet" ? "Sonnet" : nil))
            }
        }
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let percent = (extra["utilization"] as? NSNumber)?.doubleValue, percent.isFinite {
            result.quotas.append(AIQuota(title: L10n.tr("ai.quotaMonthly"), usedPercent: percent, resetsAt: nil))
        }
        result.usageAvailable = !result.quotas.isEmpty
        return result
    }

    public static func codex(models: [String: Any], usage: [String: Any]) -> AIMetadata {
        var result = AIMetadata()
        result.models = (models["data"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["model"] as? String, $0["hidden"] as? Bool != true else { return nil }
            return AIModelOption(id: id, title: $0["displayName"] as? String ?? id)
        }
        let buckets = usage["rateLimitsByLimitId"] as? [String: [String: Any]]
        let limits = buckets?.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            ?? (usage["rateLimits"] as? [String: Any]).map { [("codex", $0)] } ?? []
        for (name, bucket) in limits {
            for key in ["primary", "secondary"] {
                guard let row = bucket[key] as? [String: Any], let percent = (row["usedPercent"] as? NSNumber)?.doubleValue,
                      percent.isFinite, let minutes = row["windowDurationMins"] as? Int else { continue }
                let period: String
                switch minutes {
                case 300: period = L10n.tr("ai.quotaSession")
                case 1440: period = L10n.tr("ai.quotaDaily")
                case 10080: period = L10n.tr("ai.quotaWeekly")
                case 43200: period = L10n.tr("ai.quotaMonth")
                default: period = "\(minutes) " + L10n.tr("ai.minutes")
                }
                let title = name == "codex" ? period : "\(bucket["limitName"] as? String ?? name) · \(period)"
                result.quotas.append(AIQuota(title: title, usedPercent: percent, resetsAt: date(row["resetsAt"])))
            }
        }
        result.usageAvailable = !result.quotas.isEmpty
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public final class AIMetadataExchange: AIProcessExchange {
    public let provider: AIProvider
    public private(set) var isComplete = false
    public private(set) var models: [String: Any] = [:]
    public private(set) var usage: [String: Any] = [:]
    private var received = Set<Int>()
    public init(provider: AIProvider) { self.provider = provider }

    public var initial: String {
        provider == .claude
            ? json(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])
            : json(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "jena_note", "version": "1.0"]]])
    }

    public func receive(_ line: String) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if provider == .claude {
            guard event["type"] as? String == "control_response", let response = event["response"] as? [String: Any] else { return nil }
            let payload = response["response"] as? [String: Any] ?? [:]
            if response["request_id"] as? String == "init" {
                models = payload
                return json(["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage"]])
            }
            if response["request_id"] as? String == "usage" { usage = payload; isComplete = true }
        } else {
            guard let id = event["id"] as? Int else { return nil }
            let payload = event["result"] as? [String: Any] ?? [:]
            if id == 1 {
                if event["error"] != nil { isComplete = true; return nil }
                return json(["method": "initialized"])
                    + json(["id": 2, "method": "model/list", "params": ["limit": 100, "includeHidden": false]])
                    + json(["id": 3, "method": "account/rateLimits/read"])
            }
            if id == 2 { models = payload; received.insert(id) }
            if id == 3 { usage = payload; received.insert(id) }
            isComplete = received.count == 2
        }
        return nil
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }
}
