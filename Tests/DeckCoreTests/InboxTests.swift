import Foundation
import Testing
@testable import DeckCore

private let t0 = Date(timeIntervalSince1970: 1_000)

private func envelope(_ event: String, _ fields: [String: JSONValue] = [:], wait: Bool = false,
                      tool: Tool = .claude, session: String = "s1") -> HookEnvelope {
    var payload: [String: JSONValue] = ["session_id": .string(session), "cwd": .string("/w/devkits")]
    payload.merge(fields) { $1 }
    return HookEnvelope(tool: tool, event: event, wait: wait, payload: .object(payload))
}

private let bash: JSONValue = .object(["command": .string("touch probe_perm.txt")])

@Test func sessionMovesThroughRunningWaitingAndDone() {
    var inbox = Inbox()
    inbox.apply(envelope("SessionStart"), at: t0)
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .idle)

    inbox.apply(envelope("UserPromptSubmit"), at: t0)
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .running)

    let change = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0)
    #expect(change.opened?.toolName == "Bash")
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .waiting)
    #expect(inbox.waitingCount == 1)

    inbox.apply(envelope("Stop", ["last_assistant_message": .string("done")]), at: t0)
    let session = inbox.sessions["s1"]!
    #expect(inbox.state(of: session) == .doneUnread)
    #expect(session.lastMessage == "done")

    inbox.markRead("s1")
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .idle)
}

@Test func answeringInCursorClosesTheCardThroughPostToolUse() {
    var inbox = Inbox()
    let card = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0).opened!

    let other: JSONValue = .object(["command": .string("ls")])
    #expect(inbox.apply(envelope("PostToolUse", ["tool_name": .string("Bash"), "tool_input": other]), at: t0).closed.isEmpty)

    let change = inbox.apply(envelope("PostToolUse", ["tool_name": .string("Bash"), "tool_input": bash]), at: t0)
    #expect(change.closed == [card.id])
    #expect(inbox.cards.isEmpty)
}

@Test func stopAndNewPromptReleaseOpenCards() {
    var inbox = Inbox()
    let denied = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0).opened!
    #expect(inbox.apply(envelope("Stop"), at: t0).closed == [denied.id])

    let pending = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0).opened!
    #expect(inbox.apply(envelope("UserPromptSubmit"), at: t0).closed == [pending.id])
}

@Test func askUserQuestionBecomesAQuestionCard() throws {
    let input: JSONValue = .object(["questions": .array([.object([
        "question": .string("选 A 还是 B？"), "header": .string("A/B"), "multiSelect": .bool(false),
        "options": .array([.object(["label": .string("A"), "description": .string("选项 A")]),
                           .object(["label": .string("B")])]),
    ])])])
    var inbox = Inbox()
    let card = try #require(inbox.apply(envelope("PermissionRequest", ["tool_name": .string("AskUserQuestion"), "tool_input": input], wait: true), at: t0).opened)
    guard case .question(let questions, _) = card.kind else { Issue.record("expected a question card"); return }
    #expect(questions.first?.options.map(\.label) == ["A", "B"])

    // The tool runs with answers added to its input; matching ignores the answers.
    var answered = input
    if case .object(var fields) = answered { fields["answers"] = .object(["选 A 还是 B？": .string("B")]); answered = .object(fields) }
    #expect(inbox.apply(envelope("PostToolUse", ["tool_name": .string("AskUserQuestion"), "tool_input": answered]), at: t0).closed == [card.id])
}

@Test func nonWaitingPermissionRequestOpensNoCard() {
    var inbox = Inbox()
    #expect(inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash]), at: t0).opened == nil)
}

@Test func orderPutsWaitingFirstThenUnreadThenRunning() {
    var inbox = Inbox()
    inbox.apply(envelope("UserPromptSubmit", session: "running"), at: t0)
    inbox.apply(envelope("Stop", session: "done"), at: t0)
    inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true, session: "blocked"), at: t0)
    inbox.apply(envelope("SessionStart", session: "idle"), at: t0.addingTimeInterval(60))
    #expect(inbox.ordered.map(\.id) == ["blocked", "done", "running", "idle"])
}

@Test func sessionEndRemovesSessionAndReleasesItsCards() {
    var inbox = Inbox()
    let card = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0).opened!
    #expect(inbox.apply(envelope("SessionEnd"), at: t0).closed == [card.id])
    #expect(inbox.sessions.isEmpty)
}

@Test func discoveryWithoutANewerObservationDoesNotOverrideHookState() {
    var inbox = Inbox()
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/x", title: "修复登录", busy: true, at: t0)
    #expect(inbox.sessions["s1"]?.running == true)
    inbox.apply(envelope("Stop"), at: t0)
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/x", title: "修复登录", busy: true, at: t0)
    #expect(inbox.sessions["s1"]?.running == false)
    #expect(inbox.sessions["s1"]?.displayTitle == "修复登录")
}

@Test func newerDiscoveryClearsRunningWhenTheStopHookWasMissed() {
    var inbox = Inbox()
    inbox.apply(envelope("UserPromptSubmit", tool: .codex), at: t0)
    let finished = t0.addingTimeInterval(60)
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: false,
                     activeAt: finished, at: finished.addingTimeInterval(5))
    #expect(inbox.sessions["s1"]?.running == false)
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .doneUnread)
    #expect(inbox.sessions["s1"]?.updatedAt == finished)
}

@Test func newerDiscoveryStartsARunningTurnAndClearsUnread() {
    var inbox = Inbox()
    inbox.apply(envelope("Stop", tool: .codex), at: t0)
    let started = t0.addingTimeInterval(60)
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: true,
                     activeAt: started, at: started.addingTimeInterval(5))
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .running)
    #expect(inbox.sessions["s1"]?.unread == false)
}

@Test func olderDiscoveryCannotUndoANewerPromptOrStop() {
    var inbox = Inbox()
    let later = t0.addingTimeInterval(60)
    inbox.apply(envelope("UserPromptSubmit", tool: .codex), at: later)
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: false, activeAt: t0, at: later)
    #expect(inbox.sessions["s1"]?.running == true)
    inbox.apply(envelope("Stop", tool: .codex), at: later)
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: true, activeAt: t0, at: later)
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .doneUnread)
}

@Test func metadataRefreshDoesNotHideANewerStateObservation() {
    var inbox = Inbox()
    inbox.apply(envelope("UserPromptSubmit", tool: .codex), at: t0)
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: "renamed", busy: nil,
                     activeAt: t0.addingTimeInterval(120), at: t0.addingTimeInterval(120))
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: false,
                     activeAt: t0.addingTimeInterval(60), at: t0.addingTimeInterval(125))
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .doneUnread)
}

@Test func discoveryCanResolveAnInitiallyUnknownState() {
    var inbox = Inbox()
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: nil, at: t0.addingTimeInterval(60))
    inbox.discovered(id: "s1", tool: .codex, cwd: "/w/devkits", title: nil, busy: true, activeAt: t0, at: t0.addingTimeInterval(65))
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .running)
}

@Test func discoveryKeepsPendingApprovalsWaiting() {
    var inbox = Inbox()
    let card = inbox.apply(envelope("PermissionRequest", ["tool_name": .string("Bash"), "tool_input": bash], wait: true), at: t0).opened!
    let later = t0.addingTimeInterval(60)
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/devkits", title: nil, busy: false, activeAt: later, at: later)
    #expect(inbox.state(of: inbox.sessions["s1"]!) == .waiting)
    #expect(inbox.cards[card.id] == card)
}

@Test func discoveredSessionsShowTheirLastActivityNotTheScanTime() {
    var inbox = Inbox()
    let lastActive = t0.addingTimeInterval(-3600)
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/x", title: nil, busy: false, activeAt: lastActive, at: t0)
    #expect(inbox.sessions["s1"]?.updatedAt == lastActive)
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/x", title: nil, busy: false, activeAt: lastActive.addingTimeInterval(-60), at: t0)
    #expect(inbox.sessions["s1"]?.updatedAt == lastActive)  // never moves backwards
    let json = #"{"pid": 1, "sessionId": "s", "cwd": "/w", "statusUpdatedAt": 1793276434822}"#
    #expect(ClaudeRegistry.parse(Data(json.utf8))?.activeAt == Date(timeIntervalSince1970: 1793276434.822))
}

@Test func sessionKeepsTheDirectoryItStartedIn() {
    var inbox = Inbox()
    inbox.discovered(id: "s1", tool: .claude, cwd: "/w/workspace", title: nil, busy: false, at: t0)
    inbox.apply(envelope("UserPromptSubmit", ["cwd": .string("/w/workspace/agent-deck")]), at: t0)
    #expect(inbox.sessions["s1"]?.project == "workspace")

    var hookFirst = Inbox()
    hookFirst.apply(envelope("SessionStart", ["cwd": .string("/w/codex-repo")], tool: .codex, session: "t1"), at: t0)
    hookFirst.apply(envelope("Stop", ["cwd": .string("/w/codex-repo/sub")], tool: .codex, session: "t1"), at: t0)
    #expect(hookFirst.sessions["t1"]?.cwd == "/w/codex-repo")
}

@Test func envelopeDecodesFromShimJSON() throws {
    let line = #"{"v":1,"tool":"codex","event":"Stop","wait":false,"payload":{"session_id":"thr_1","cwd":"/w","last_assistant_message":"OK","stop_hook_active":false}}"#
    let decoded = try JSONDecoder().decode(HookEnvelope.self, from: Data(line.utf8))
    #expect(decoded.tool == .codex)
    #expect(decoded.sessionId == "thr_1")
    #expect(decoded.payload["stop_hook_active"]?.bool == false)
}
