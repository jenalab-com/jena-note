import Foundation

/// A bounded line comparison: selected revision → current manuscript.
enum DocumentHistoryDiff {
    enum Kind { case unchanged, added, removed, modified }
    struct Row {
        let previousLine: Int?
        let currentLine: Int?
        let previous: String?
        let current: String?
        let kind: Kind
    }

    static func rows(previous: String, current: String) -> [Row]? {
        let old = previous.components(separatedBy: "\n")
        let new = current.components(separatedBy: "\n")
        guard previous.utf8.count + current.utf8.count <= 2_000_000,
              previous == current || old.count * new.count <= 1_000_000 else { return nil }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Row] = [], a = 0, b = 0
        while a < old.count || b < new.count {
            var deletions: [Int] = [], additions: [Int] = []
            while a < old.count, removed.contains(a) { deletions.append(a); a += 1 }
            while b < new.count, inserted.contains(b) { additions.append(b); b += 1 }
            if !deletions.isEmpty || !additions.isEmpty {
                for index in 0..<max(deletions.count, additions.count) {
                    let left = index < deletions.count ? deletions[index] : nil
                    let right = index < additions.count ? additions[index] : nil
                    result.append(Row(previousLine: left.map { $0 + 1 }, currentLine: right.map { $0 + 1 },
                                      previous: left.map { old[$0] }, current: right.map { new[$0] },
                                      kind: left == nil ? .added : right == nil ? .removed : .modified))
                }
            } else if a < old.count, b < new.count {
                result.append(Row(previousLine: a + 1, currentLine: b + 1, previous: old[a], current: new[b], kind: .unchanged))
                a += 1; b += 1
            } else { break }
        }
        return result
    }

    static func compare(previous: String, current: String) -> String? {
        if previous == current { return L10n.tr("history.identical") }
        let old = previous.components(separatedBy: "\n")
        let new = current.components(separatedBy: "\n")
        guard old.count * new.count <= 1_000_000,
              previous.utf8.count + current.utf8.count <= 2_000_000 else { return nil }
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [String] = [], a = 0, b = 0
        while a < old.count || b < new.count {
            if a < old.count, removed.contains(a) { result.append("− " + old[a]); a += 1 }
            else if b < new.count, inserted.contains(b) { result.append("+ " + new[b]); b += 1 }
            else if b < new.count { result.append("  " + new[b]); a += 1; b += 1 }
            else { result.append("− " + old[a]); a += 1 }
        }
        return result.joined(separator: "\n")
    }
}
