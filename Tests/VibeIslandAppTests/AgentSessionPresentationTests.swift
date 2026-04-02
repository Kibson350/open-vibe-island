import Foundation
import Testing
@testable import VibeIslandApp
import VibeIslandCore

struct AgentSessionPresentationTests {
    @Test
    func attachedCompletedSessionStaysActiveInIsland() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-3_600),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            )
        )

        #expect(session.islandPresence(at: referenceDate) == .active)
    }

    @Test
    func attachedCompletedSessionKeepsDetailLinesEvenWhenOld() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-7_200),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Initial prompt",
                lastUserPrompt: "Follow-up prompt",
                lastAssistantMessage: "Last assistant message"
            )
        )

        #expect(session.spotlightShowsDetailLines(at: referenceDate))
    }

    @Test
    func detachedCompletedSessionCanStillCollapseToInactive() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .detached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_801)
        )

        #expect(session.islandPresence(at: referenceDate) == .inactive)
        #expect(session.spotlightShowsDetailLines(at: referenceDate) == false)
    }

    @Test
    func detachedCompletedSessionStaysActiveWithinThirtyMinutes() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .detached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_799),
            codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "Follow-up prompt",
                lastAssistantMessage: "Last assistant message"
            )
        )

        #expect(session.islandPresence(at: referenceDate) == .active)
        #expect(session.spotlightShowsDetailLines(at: referenceDate))
    }

    @Test
    func headlineUsesInitialPromptWhilePromptLineUsesLatestPrompt() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Start by fixing the island hover behavior.",
                lastUserPrompt: "Now make the overlay height fit the content.",
                lastAssistantMessage: "Updating the layout logic."
            )
        )

        #expect(session.spotlightHeadlineText == "worktree · Start by fixing the island hover behavior.")
        #expect(session.spotlightPromptLineText == "You: Now make the overlay height fit the content.")
    }
}
