import Foundation
import Testing
@testable import DeckCore

private struct TokenFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tokens-\(UUID().uuidString)")
    let now = ISO8601DateFormatter().date(from: "2026-11-13T03:00:00Z")!
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    func write(_ path: String, _ lines: [String], terminated: Bool = true, modified: Date? = nil) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + (terminated ? "\n" : "")).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: url.path)
    }

    func read() -> CodexTokenUsage {
        CodexTokenUsageReader.today(codexHome: home, now: now, calendar: calendar)
    }
}

private func withTokenFixture(_ body: (TokenFixture) throws -> Void) throws {
    let fixture = TokenFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try body(fixture)
}

private func tokenMeta(_ id: String, forkedFrom: String? = nil) -> String {
    var payload = ["id": id]
    if let forkedFrom { payload["forked_from_id"] = forkedFrom }
    return tokenJSON(["type": "session_meta", "payload": payload])
}

private func tokenJSON(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8)!
}

private func tokenRecord(_ id: String, thread: String = "main", at: String = "2026-11-13T02:00:00Z",
                         input: Int = 100, cached: Int = 40, output: Int = 20) -> String {
    tokenJSON(["type": "token_usage_record", "timestamp": at,
               "payload": ["thread_id": thread, "response_id": id,
                           "usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                     "reasoning_output_tokens": 7, "total_tokens": 999_999],
                           "thread_token_usage": ["input_tokens": 999_999]]])
        .replacingOccurrences(of: "\"payload\":", with: "\"payload\" : ")
}

private func tokenSnapshot(at: String = "2026-11-13T02:00:00Z", info: Bool = true) -> String {
    let usage: Any = info ? ["total_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20]] as Any : NSNull()
    return tokenJSON(["type": "event_msg", "timestamp": at, "payload": ["type": "token_count", "info": usage]])
}

@Test func codexTokensUseLocalDayAndExcludeFutureResponses() throws {
    try withTokenFixture { f in
        try f.write("sessions/2026/11/12/day.jsonl", [tokenMeta("main"),
            tokenRecord("before", at: "2026-11-12T15:59:59Z"),
            tokenRecord("start", at: "2026-11-12T16:00:00.000Z"),
            tokenRecord("today", at: "2026-11-13T02:59:59.999Z"),
            tokenRecord("now", at: "2026-11-13T03:00:00Z"),
            tokenRecord("future", at: "2026-11-13T04:00:00Z"),
            tokenRecord("next-day", at: "2026-11-13T16:00:00Z")])
        #expect(f.read() == CodexTokenUsage(inputTokens: 200, cachedInputTokens: 80, outputTokens: 40, responseCount: 2))
        #expect(f.read().totalTokens == 240)
    }
}

@Test func codexTokensDeduplicateResponsesAcrossRolloutsAndArchives() throws {
    try withTokenFixture { f in
        try f.write("sessions/one.jsonl", [tokenMeta("main"), tokenRecord("same"), tokenRecord("same"), tokenRecord("second")])
        try f.write("archived_sessions/copy.jsonl", [tokenMeta("main"), tokenRecord("same")])
        #expect(f.read() == CodexTokenUsage(inputTokens: 200, cachedInputTokens: 80, outputTokens: 40, responseCount: 2))
    }
}

@Test func codexTokensCountSubagentsWithoutRecountingTheirCopiedHistory() throws {
    try withTokenFixture { f in
        try f.write("sessions/main.jsonl", [tokenMeta("main"), tokenRecord("parent")])
        try f.write("sessions/child.jsonl", [tokenMeta("child", forkedFrom: "main"), tokenMeta("main"),
            tokenRecord("parent"), tokenRecord("child-response", thread: "child")])
        try f.write("sessions/standalone-child.jsonl", [tokenMeta("standalone"), tokenRecord("standalone-response", thread: "standalone")])
        #expect(f.read() == CodexTokenUsage(inputTokens: 300, cachedInputTokens: 120, outputTokens: 60, responseCount: 3))
    }
}

@Test func codexTokensIgnoreCopiedLegacySnapshotsBeforeTheChildStarts() throws {
    try withTokenFixture { f in
        try f.write("sessions/child.jsonl", [tokenMeta("child", forkedFrom: "main"), tokenMeta("main"), tokenSnapshot()])
        #expect(f.read() == CodexTokenUsage())
    }
}

@Test func codexTokensFindContinuedOldSessionsAndArchivedSessions() throws {
    try withTokenFixture { f in
        try f.write("sessions/2025/01/01/continued.jsonl", [tokenMeta("main"),
            tokenRecord("yesterday", at: "2026-11-12T10:00:00Z"), tokenRecord("continued")])
        try f.write("archived_sessions/archived.jsonl", [tokenMeta("archived"), tokenRecord("archived-response", thread: "archived")])
        try f.write("sessions/old.jsonl", [tokenMeta("old"), tokenRecord("old-response", thread: "old")],
                    modified: f.now.addingTimeInterval(-86400))
        #expect(f.read().responseCount == 2)
        #expect(!f.read().isPartial)
    }
}

@Test func codexTokensAllowMissingDirectoriesAndArchiveOnlyData() throws {
    try withTokenFixture { f in
        #expect(f.read() == CodexTokenUsage())
        try f.write("archived_sessions/only.jsonl", [tokenMeta("main"), tokenRecord("only")])
        #expect(f.read().responseCount == 1)
        #expect(!f.read().isPartial)
    }
}

@Test func codexTokensMarkLegacyUsagePartialInsteadOfAddingSnapshots() throws {
    try withTokenFixture { f in
        try f.write("sessions/current.jsonl", [tokenMeta("main"), tokenRecord("one"), tokenSnapshot(), tokenSnapshot()])
        try f.write("sessions/legacy.jsonl", [tokenMeta("legacy"), tokenSnapshot(), tokenSnapshot()])
        #expect(f.read() == CodexTokenUsage(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, responseCount: 1, isPartial: true))
    }
}

@Test func codexTokensIgnoreEmptyOrOlderLegacyUsage() throws {
    try withTokenFixture { f in
        try f.write("sessions/legacy.jsonl", [tokenMeta("main"), tokenSnapshot(info: false),
            tokenSnapshot(at: "2026-11-12T10:00:00Z")])
        #expect(f.read() == CodexTokenUsage())
    }
}

@Test func codexTokensMarkBrokenCompleteRecordsPartialAndKeepGoodResponses() throws {
    try withTokenFixture { f in
        try f.write("sessions/broken.jsonl", [tokenMeta("main"), tokenRecord("good"),
            #"{"type":"token_usage_record","timestamp":"2026-11-13T02:00:00Z","payload":broken}"#,
            #"{"type":"token_usage_record","timestamp":"not-a-date","payload":{}}"#])
        #expect(f.read() == CodexTokenUsage(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, responseCount: 1, isPartial: true))
    }
}

@Test func codexTokensRejectNegativeFractionalAndInvalidCachedCounts() throws {
    try withTokenFixture { f in
        let fractional = tokenRecord("fractional").replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":1.5")
        try f.write("sessions/invalid.jsonl", [tokenMeta("main"), tokenRecord("negative", input: -1, cached: 0),
            tokenRecord("bad-cache", input: 1, cached: 2), tokenRecord("negative-output", output: -1), fractional])
        #expect(f.read() == CodexTokenUsage(isPartial: true))
    }
}

@Test func codexTokensHandleIntegerOverflowWithoutCrashing() throws {
    try withTokenFixture { f in
        try f.write("sessions/overflow.jsonl", [tokenMeta("main"), tokenRecord("max", input: Int.max, cached: 0, output: 0),
            tokenRecord("overflow-sum", input: 1, cached: 0, output: 0),
            tokenRecord("overflow-total", input: Int.max, cached: 0, output: 1)])
        #expect(f.read() == CodexTokenUsage(inputTokens: Int.max, responseCount: 1, isPartial: true))
        #expect(f.read().totalTokens == Int.max)
    }
}

@Test func codexTokensIgnoreAnUnfinishedAppendedLine() throws {
    try withTokenFixture { f in
        try f.write("sessions/appending.jsonl", [tokenMeta("main"), tokenRecord("good"), String(tokenRecord("unfinished").dropLast(10))], terminated: false)
        #expect(f.read() == CodexTokenUsage(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, responseCount: 1))
    }
}

@Test func codexTokensAcceptACompleteFinalRecordWithoutNewline() throws {
    try withTokenFixture { f in
        try f.write("sessions/final.jsonl", [tokenMeta("main"), tokenRecord("good")], terminated: false)
        #expect(f.read().responseCount == 1)
        #expect(!f.read().isPartial)
    }
}

@Test func codexTokensDoNotUseCopiedMetadataWhenTheFirstMetadataIsInvalid() throws {
    try withTokenFixture { f in
        try f.write("sessions/no-owner.jsonl", [#"{"type":"session_meta","payload":{}}"#,
            tokenMeta("main"), tokenRecord("foreign")])
        #expect(f.read() == CodexTokenUsage(isPartial: true))
    }
}

@Test func codexTokensDoNotRecoverOwnershipFromCopiedMetadataAfterBrokenJSON() throws {
    try withTokenFixture { f in
        try f.write("sessions/broken-owner.jsonl", [#"{"type":"session_meta","payload":broken}"#,
            tokenMeta("main"), tokenRecord("copied-response")])
        #expect(f.read() == CodexTokenUsage(isPartial: true))
    }
}

@Test func codexTokensIgnoreMalformedUsageBelongingToAnotherThread() throws {
    try withTokenFixture { f in
        try f.write("sessions/child.jsonl", [tokenMeta("child"),
            #"{"type":"token_usage_record","timestamp":"2026-11-13T02:00:00Z","payload":{"thread_id":"main","response_id":"copied","usage":"bad"}}"#])
        #expect(f.read() == CodexTokenUsage())
    }
}

@Test func codexTokensReportAnUnreadableSessionsLocationAsPartial() throws {
    try withTokenFixture { f in
        try f.write("sessions", [])
        #expect(f.read().isPartial)
    }
}
