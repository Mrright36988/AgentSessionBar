import Foundation
import Testing
@testable import DeckCore

private let activityMeta = #"{"type":"session_meta","payload":{"id":"owner"}}"#

private func activityEvent(_ type: String, turn: String = "turn", at: String = "2026-11-13T04:00:00Z") -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
}

private func withActivityFile(_ lines: [String], terminated: Bool = true, _ body: (URL) throws -> Void) throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("codex-activity-\(UUID().uuidString).jsonl")
    try Data((lines.joined(separator: "\n") + (terminated ? "\n" : "")).utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    try body(file)
}

@Test func codexActivityUsesExplicitTaskStartAndItsTimestamp() throws {
    try withActivityFile([activityMeta, activityEvent("task_started", at: "2026-11-13T04:00:00.125Z")]) { file in
        let activity = try #require(CodexRollouts.latestActivity(in: file))
        #expect(activity.running)
        #expect(activity.at.timeIntervalSince1970 == 1794542400.125)
    }
}

@Test func codexActivityFinishesTheMatchingTurnOnCompletionOrAbort() throws {
    for boundary in ["task_complete", "turn_aborted", "task_aborted"] {
        try withActivityFile([activityMeta, activityEvent("task_started"),
                              activityEvent(boundary, at: "2026-11-13T04:00:01Z")]) { file in
            let activity = try #require(CodexRollouts.latestActivity(in: file))
            #expect(!activity.running)
            #expect(activity.at == ISO8601DateFormatter().date(from: "2026-11-13T04:00:01Z"))
        }
    }
}

@Test func codexActivityCanReadAnExplicitEndWithoutAPrecedingStart() throws {
    try withActivityFile([activityMeta, activityEvent("task_complete")]) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == false)
    }
}

@Test func codexActivityWithoutTaskBoundariesDoesNotInventRunningState() throws {
    try withActivityFile([activityMeta,
        #"{"type":"event_msg","timestamp":"2026-11-13T04:00:00Z","payload":{"type":"token_count","info":null}}"#,
        #"{"type":"response_item","payload":{"type":"task_started"}}"#]) { file in
        #expect(CodexRollouts.latestActivity(in: file) == nil)
    }
}

@Test func codexActivityIgnoresRewrittenLifecycleFromCopiedHistory() throws {
    let inherited = [activityMeta, #"{"type":"session_meta","payload":{"id":"parent"}}"#,
        #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"parent"}}"#,
        activityEvent("task_started", turn: "parent-turn"), activityEvent("turn_aborted", turn: "parent-turn")]
    try withActivityFile(inherited) { file in
        #expect(CodexRollouts.latestActivity(in: file) == nil)
    }
    try withActivityFile(inherited + [
        #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"owner"}}"#,
        activityEvent("task_started", turn: "owner-turn", at: "2026-11-13T04:01:00Z")]) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == true)
    }
}

@Test func codexActivityAnOldTurnsLateEndDoesNotCloseTheNewTurn() throws {
    try withActivityFile([activityMeta, activityEvent("task_started", turn: "old"),
        activityEvent("task_started", turn: "new", at: "2026-11-13T04:01:00Z"),
        activityEvent("task_complete", turn: "old", at: "2026-11-13T04:02:00Z"),
        activityEvent("turn_aborted", turn: "old", at: "2026-11-13T04:03:00Z")]) { file in
        let activity = try #require(CodexRollouts.latestActivity(in: file))
        #expect(activity.running)
        #expect(activity.at == ISO8601DateFormatter().date(from: "2026-11-13T04:01:00Z"))
    }
}

@Test func codexActivityLongToolOutputDoesNotHideTheStartOrBreakChunkBoundaries() throws {
    let output = #"{"type":"response_item","payload":{"type":"function_call_output","output":"\#(String(repeating: "x", count: 700_000))"}}"#
    try withActivityFile([activityMeta, activityEvent("task_started"), output]) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == true)
    }
    try withActivityFile([activityMeta, activityEvent("task_started"), output, activityEvent("task_complete")]) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == false)
    }
}

@Test func codexActivityIgnoresMalformedLinesAndAnUnfinishedAppend() throws {
    try withActivityFile([activityMeta, activityEvent("task_started"), "broken JSON",
        String(activityEvent("task_complete").dropLast(5))], terminated: false) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == true)
    }
}

@Test func codexActivityAcceptsACompleteFinalBoundaryWithoutNewline() throws {
    try withActivityFile([activityMeta, activityEvent("task_complete")], terminated: false) { file in
        #expect(CodexRollouts.latestActivity(in: file)?.running == false)
    }
}

@Test func codexActivityRequiresFirstMetadataAndAValidTurnAndTime() throws {
    try withActivityFile([#"{"type":"session_meta","payload":broken}"#, activityMeta, activityEvent("task_started")]) { file in
        #expect(CodexRollouts.latestActivity(in: file) == nil)
    }
    try withActivityFile([activityMeta, activityEvent("task_started", at: "invalid"),
        #"{"type":"event_msg","timestamp":"2026-11-13T04:00:00Z","payload":{"type":"task_started"}}"#]) { file in
        #expect(CodexRollouts.latestActivity(in: file) == nil)
    }
}
