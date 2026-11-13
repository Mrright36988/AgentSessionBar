import Foundation

public struct CodexTokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var responseCount: Int
    public var isPartial: Bool
    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0,
                responseCount: Int = 0, isPartial: Bool = false) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.responseCount = responseCount
        self.isPartial = isPartial
    }
}

public enum CodexTokenUsageReader {
    public static func today(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                             now: Date = Date(), calendar: Calendar = .current) -> CodexTokenUsage {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return CodexTokenUsage(isPartial: true) }
        var result = CodexTokenUsage()
        var responses: Set<String> = []
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        for name in ["sessions", "archived_sessions"] {
            let directory = codexHome.appendingPathComponent(name)
            do {
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    result.isPartial = true
                    continue
                }
            } catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError { result.isPartial = true }
                continue
            }
            guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
                result.isPartial = true
                return true
            }) else {
                result.isPartial = true
                continue
            }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                do {
                    let values = try file.resourceValues(forKeys: keys)
                    guard values.isRegularFile == true else { continue }
                    guard let modified = values.contentModificationDate else { result.isPartial = true; continue }
                    guard modified >= day.start else { continue }
                    read(file, from: day.start, until: min(now, day.end), result: &result, responses: &responses)
                } catch { result.isPartial = true }
            }
        }
        return result
    }

    private static func read(_ file: URL, from start: Date, until end: Date,
                             result: inout CodexTokenUsage, responses: inout Set<String>) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        func date(_ text: String) -> Date? { fractional.date(from: text) ?? standard.date(from: text) }
        var sawMeta = false
        var owner: String?
        var copiedHistory = false
        var hasTodayRecord = false
        var hasTodaySnapshot = false

        func consume(_ line: Data, terminated: Bool = true) {
            // A writer can leave a partial JSON value at EOF while it is appending a response.
            guard terminated || (try? decoder.decode(Header.self, from: line)) != nil else { return }
            do {
                let header = try decoder.decode(Header.self, from: line)
                switch header.type {
                case "session_meta":
                    let isFirst = !sawMeta
                    sawMeta = true
                    let meta = try decoder.decode(Meta.self, from: line)
                    if isFirst {
                        guard !meta.payload.id.isEmpty else { result.isPartial = true; return }
                        owner = meta.payload.id
                    } else { copiedHistory = meta.payload.id != owner }
                case "token_usage_record":
                    guard let owner else { result.isPartial = true; return }
                    guard try decoder.decode(RecordOwner.self, from: line).payload.threadId == owner else { return }
                    let record = try decoder.decode(Record.self, from: line)
                    copiedHistory = false
                    guard let at = date(record.timestamp) else { result.isPartial = true; return }
                    guard at >= start, at < end else { return }
                    let usage = record.payload.usage
                    guard !record.payload.responseId.isEmpty, usage.inputTokens >= 0, usage.cachedInputTokens >= 0,
                          usage.outputTokens >= 0, usage.cachedInputTokens <= usage.inputTokens else {
                        result.isPartial = true
                        return
                    }
                    hasTodayRecord = true
                    guard !responses.contains(record.payload.responseId) else { return }
                    let input = result.inputTokens.addingReportingOverflow(usage.inputTokens)
                    let cached = result.cachedInputTokens.addingReportingOverflow(usage.cachedInputTokens)
                    let output = result.outputTokens.addingReportingOverflow(usage.outputTokens)
                    let count = result.responseCount.addingReportingOverflow(1)
                    guard !input.overflow, !cached.overflow, !output.overflow, !count.overflow,
                          input.partialValue <= Int.max - output.partialValue else {
                        result.isPartial = true
                        return
                    }
                    result.inputTokens = input.partialValue
                    result.cachedInputTokens = cached.partialValue
                    result.outputTokens = output.partialValue
                    result.responseCount = count.partialValue
                    responses.insert(record.payload.responseId)
                case "event_msg":
                    let message = try decoder.decode(Message.self, from: line)
                    if message.payload.type == "thread_settings_applied", let thread = message.payload.threadId {
                        copiedHistory = thread != owner
                    }
                    if message.payload.type == "token_count", !copiedHistory, message.payload.info?.totalTokenUsage != nil,
                       let timestamp = message.timestamp {
                        guard let at = date(timestamp) else { result.isPartial = true; return }
                        if at >= start, at < end { hasTodaySnapshot = true }
                    }
                default: break
                }
            } catch {
                // Ignore unrelated session content; only malformed usage or ownership records affect this total.
                if line.range(of: Data("\"session_meta\"".utf8)) != nil { sawMeta = true }
                if ["token_usage_record", "token_count", "session_meta"].contains(where: {
                    line.range(of: Data("\"\($0)\"".utf8)) != nil
                }) { result.isPartial = true }
            }
        }

        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var buffer = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    consume(Data(buffer[..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { consume(buffer, terminated: false) }
        } catch { result.isPartial = true }
        if hasTodaySnapshot && !hasTodayRecord { result.isPartial = true }
    }
}

private struct Header: Decodable {
    let type: String
}

private struct Meta: Decodable {
    struct Payload: Decodable { let id: String }
    let payload: Payload
}

private struct Counts: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
}

private struct Record: Decodable {
    struct Payload: Decodable {
        let threadId: String
        let responseId: String
        let usage: Counts
    }
    let timestamp: String
    let payload: Payload
}

private struct RecordOwner: Decodable {
    struct Payload: Decodable { let threadId: String }
    let payload: Payload
}

private struct Message: Decodable {
    struct Info: Decodable { let totalTokenUsage: Counts? }
    struct Payload: Decodable {
        let type: String
        let threadId: String?
        let info: Info?
    }
    let timestamp: String?
    let payload: Payload
}
