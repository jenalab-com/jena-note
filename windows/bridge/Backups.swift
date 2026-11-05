import Foundation
import JenaNoteCore

// Document history for the Windows app. See Bridge.swift for the conventions.

private var backups = DocumentBackupStore.shared

private func report(_ failure: Error, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    error.pointee = duplicate((failure as? AIError)?.message ?? String(describing: failure))
    return -1
}

/// For tests: keeps them away from the author's real history.
@_cdecl("jena_backup_use_directory")
public func jena_backup_use_directory(_ path: UnsafePointer<CChar>) {
    backups = DocumentBackupStore(directory: URL(fileURLWithPath: String(cString: path), isDirectory: true))
}

@_cdecl("jena_backup_has_snapshots")
public func jena_backup_has_snapshots(_ path: UnsafePointer<CChar>, _ has: UnsafeMutablePointer<Int32>,
                                      _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        has.pointee = try backups.hasSnapshots(for: URL(fileURLWithPath: String(cString: path))) ? 1 : 0
        return 0
    } catch let failure {
        return report(failure, error)
    }
}

/// `automatic` limits recording to one version per five minutes. `force` records even when the
/// content is the same as the latest version. A `name` makes a version that is never pruned.
@_cdecl("jena_backup_record")
public func jena_backup_record(_ path: UnsafePointer<CChar>, _ bytes: UnsafePointer<UInt8>?, _ length: Int,
                               _ automatic: Int32, _ name: UnsafePointer<CChar>?, _ force: Int32,
                               _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
        try backups.record(data, for: URL(fileURLWithPath: String(cString: path)), automatic: automatic != 0,
                           name: name.map { String(cString: $0) }, force: force != 0)
        return 0
    } catch let failure {
        return report(failure, error)
    }
}

private struct SnapshotDTO: Encodable {
    let id: String
    let createdAt: Double
    let name: String?
}

/// Newest first, without the text.
@_cdecl("jena_backup_list")
public func jena_backup_list(_ path: UnsafePointer<CChar>,
                             _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                             _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let items = try backups.snapshots(for: URL(fileURLWithPath: String(cString: path))).map {
            SnapshotDTO(id: $0.id.uuidString, createdAt: $0.createdAt.timeIntervalSince1970, name: $0.name)
        }
        result.pointee = duplicate(String(decoding: try JSONEncoder().encode(items), as: UTF8.self))
        return 0
    } catch let failure {
        return report(failure, error)
    }
}

@_cdecl("jena_backup_text")
public func jena_backup_text(_ path: UnsafePointer<CChar>, _ id: UnsafePointer<CChar>,
                             _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                             _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let wanted = UUID(uuidString: String(cString: id))
        let items = try backups.snapshots(for: URL(fileURLWithPath: String(cString: path)))
        guard let item = items.first(where: { $0.id == wanted }),
              let text = String(data: item.data, encoding: .utf8) else {
            throw AIError(message: L10n.tr("backup.invalid"))
        }
        result.pointee = duplicate(text)
        return 0
    } catch let failure {
        return report(failure, error)
    }
}

private struct HistoryRowDTO: Encodable {
    let previousLine: Int?
    let currentLine: Int?
    let previous: String?
    let current: String?
    let kind: String

    init(_ row: DocumentHistoryDiff.Row) {
        previousLine = row.previousLine
        currentLine = row.currentLine
        previous = row.previous
        current = row.current
        switch row.kind {
        case .unchanged: kind = "unchanged"
        case .added: kind = "added"
        case .removed: kind = "removed"
        case .modified: kind = "modified"
        }
    }
}

/// Aligned rows of a line comparison, or `null` when the texts are too large to compare.
@_cdecl("jena_history_rows")
public func jena_history_rows(_ previous: UnsafePointer<CChar>, _ current: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    let rows = DocumentHistoryDiff.rows(previous: String(cString: previous), current: String(cString: current))
    let encoded = rows.flatMap { try? JSONEncoder().encode($0.map(HistoryRowDTO.init)) }
    return duplicate(encoded.map { String(decoding: $0, as: UTF8.self) } ?? "null")
}
