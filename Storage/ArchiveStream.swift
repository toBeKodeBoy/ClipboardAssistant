import Foundation

/// Incremental JSON framing; a single record, rather than a whole Base64 archive, is buffered.
final class ArchiveStream {
    private let readChunk: () throws -> Data
    private var buffer = Data()
    private var offset = 0
    private var consumed = 0
    private var lookahead: UInt8?
    var cancelled: () -> Bool = { false }
    init(handle: FileHandle) { readChunk = { try handle.read(upToCount: 65536) ?? Data() } }
    init(data: Data) {
        var position = 0
        readChunk = {
            let end = min(position + 65536, data.count)
            defer { position = end }
            return data.subdata(in: position..<end)
        }
    }
    private func byte() throws -> UInt8? {
        if let lookahead { self.lookahead = nil; return lookahead }
        if offset == buffer.count {
            if cancelled() { throw CancellationError() }
            buffer = try readChunk(); offset = 0
            if buffer.isEmpty { return nil }
        }
        consumed += 1
        guard consumed <= HistoryArchive.maxBytes else { throw ArchiveError.limitExceeded }
        defer { offset += 1 }
        return buffer[offset]
    }
    private func nonspace() throws -> UInt8? {
        while let b = try byte() {
            switch b { case 9,10,13,32: continue; default: return b }
        }
        return nil
    }
    private func expect(_ b: UInt8) throws {
        guard try nonspace() == b else { throw ArchiveError.invalidFormat }
    }
    /// JSONDecoder validates scalars; framing also rejects duplicate object keys at every nesting level.
    private func value(first: UInt8, depth: Int = 0) throws -> Data {
        guard depth < 32 else { throw ArchiveError.limitExceeded }
        var data = Data([first])
        if first == 34 {
            var escaped = false
            while let b = try byte() {
                data.append(b)
                guard data.count <= 64 * 1024 * 1024 else { throw ArchiveError.limitExceeded }
                if !escaped && b == 34 { return data }
                if !escaped && b == 92 { escaped = true } else { escaped = false }
            }
            throw ArchiveError.invalidFormat
        }
        if first == 123 || first == 91 {
            let close: UInt8 = first == 123 ? 125 : 93
            var keys = Set<String>()
            guard var next = try nonspace() else { throw ArchiveError.invalidFormat }
            if next == close { data.append(close); return data }
            while true {
                if first == 123 {
                    guard next == 34 else { throw ArchiveError.invalidFormat }
                    let keyData = try value(first: next, depth: depth + 1)
                    let key = try JSONDecoder().decode(String.self, from: keyData)
                    guard keys.insert(key).inserted else { throw ArchiveError.invalidFormat }
                    data.append(keyData); try expect(58); data.append(58)
                    guard let b = try nonspace() else { throw ArchiveError.invalidFormat }; next = b
                }
                data.append(try value(first: next, depth: depth + 1))
                guard data.count <= 64 * 1024 * 1024, let delimiter = try nonspace() else { throw ArchiveError.limitExceeded }
                data.append(delimiter)
                if delimiter == close { return data }
                guard delimiter == 44, let b = try nonspace() else { throw ArchiveError.invalidFormat }; next = b
            }
        }
        while let b = try byte() {
            if [9,10,13,32,44,93,125].contains(b) { lookahead = b; break }
            data.append(b)
            guard data.count <= 4096 else { throw ArchiveError.limitExceeded }
        }
        return data
    }
    func read() throws -> HistoryArchive {
        try expect(123)
        var keys = Set<String>(), metadata: [String: Data] = [:]
        var items: [ArchiveRecord] = []
        var payloadBytes = 0, metadataBytes = 0
        let decoder = ArchiveDates.decoder()
        while true {
            guard try nonspace() == 34 else { throw ArchiveError.invalidFormat }
            let key = try decoder.decode(String.self, from: value(first: 34))
            guard keys.insert(key).inserted, ["format", "formatVersion", "exportedAt", "items"].contains(key) else { throw ArchiveError.invalidFormat }
            try expect(58)
            if key == "items" {
                try expect(91)
                guard var next = try nonspace() else { throw ArchiveError.invalidFormat }
                if next != 93 {
                    while true {
                        guard next == 123, items.count < 10000 else { throw ArchiveError.limitExceeded }
                        let record: ArchiveRecord
                        do {
                            let recordData = try value(first: next)
                            try ArchiveWire.validateRecord(recordData)
                            record = try decoder.decode(ArchiveRecord.self, from: recordData)
                            try HistoryArchive(items: [record]).validate(cancelled: cancelled)
                        } catch { throw ArchiveRecordFailure(index: items.count + 1, error: error) }
                        payloadBytes += record.plainText.utf8.count + (try record.representations.reduce(0) { $0 + (try $1.payloadByteCount()) })
                        guard payloadBytes <= HistoryArchive.maxPayloadBytes else { throw ArchiveError.limitExceeded }
                        metadataBytes += record.metadataByteCount
                        guard metadataBytes <= 16 * 1024 * 1024 else { throw ArchiveError.limitExceeded }
                        items.append(record)
                        guard let delimiter = try nonspace() else { throw ArchiveError.invalidFormat }
                        if delimiter == 93 { break }
                        guard delimiter == 44, let b = try nonspace() else { throw ArchiveError.invalidFormat }; next = b
                    }
                }
            } else {
                guard let b = try nonspace() else { throw ArchiveError.invalidFormat }
                let data = try value(first: b)
                guard data.count <= 4096 else { throw ArchiveError.limitExceeded }; metadata[key] = data
            }
            guard let delimiter = try nonspace() else { throw ArchiveError.invalidFormat }
            if delimiter == 125 { break }
            guard delimiter == 44 else { throw ArchiveError.invalidFormat }
        }
        guard try nonspace() == nil, keys.count == 4 else { throw ArchiveError.invalidFormat }
        var archive = HistoryArchive(items: items)
        archive.format = try decoder.decode(String.self, from: metadata["format"]!)
        archive.formatVersion = try decoder.decode(Int.self, from: metadata["formatVersion"]!)
        archive.exportedAt = try decoder.decode(Date.self, from: metadata["exportedAt"]!)
        try archive.validate(cancelled: cancelled)
        return archive
    }

    static func read(_ url: URL, cancelled: @escaping () -> Bool = { false }) throws -> HistoryArchive {
        guard let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { throw ArchiveError.invalidFormat }
        guard size <= HistoryArchive.maxBytes else { throw ArchiveError.limitExceeded }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let reader = ArchiveStream(handle: file); reader.cancelled = cancelled
        return try reader.read()
    }
}
