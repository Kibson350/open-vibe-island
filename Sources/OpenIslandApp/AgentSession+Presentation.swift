import Foundation
import OpenIslandCore

enum SpotlightActivityTone {
    case live
    case idle
    case ready
    case attention
}

enum IslandSessionPresence: Equatable {
    case running
    case active
    case inactive
}

extension AgentSession {
    private static let collapsedDetailAgeThreshold: TimeInterval = 20 * 60
    private static let islandActivityThreshold: TimeInterval = 20 * 60

    /// Whether this session represents a subagent (worktree agent) that should
    /// not appear as a separate entry in the session list.  The parent session
    /// already tracks subagents via `claudeMetadata.activeSubagents`.
    ///
    /// Note: `claudeMetadata.agentID` is NOT a reliable signal here because
    /// SubagentStart hooks set `agent_id` on the *parent* session's metadata.
    var isSubagentSession: Bool {
        if let path = claudeMetadata?.transcriptPath, path.contains("/subagents/") {
            return true
        }
        return false
    }

    var islandActivityDate: Date {
        updatedAt
    }

    var spotlightPrimaryText: String {
        if let request = permissionRequest {
            return request.summary
        }

        if let prompt = questionPrompt {
            return prompt.title
        }

        if let assistantMessage = lastAssistantMessageText?.trimmedForSurface,
           !assistantMessage.isEmpty {
            return assistantMessage
        }

        return summary
    }

    var spotlightSecondaryText: String? {
        if let request = permissionRequest {
            return request.affectedPath.isEmpty ? nil : request.affectedPath
        }

        if let currentTool = currentToolName?.trimmedForSurface,
           !currentTool.isEmpty {
            return phase == .completed
                ? summary
                : "Running \(currentTool)"
        }

        let normalizedPrimary = spotlightPrimaryText.trimmedForSurface
        let normalizedSummary = summary.trimmedForSurface
        guard normalizedSummary != normalizedPrimary else {
            return nil
        }

        return summary
    }

    var spotlightCurrentToolLabel: String? {
        guard let currentTool = currentToolName?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        return currentTool
    }

    var spotlightTrackingLabel: String? {
        guard let transcriptPath = trackingTranscriptPath?.trimmedForSurface,
              !transcriptPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: transcriptPath).lastPathComponent
    }

    var spotlightStatusLabel: String {
        switch phase {
        case .running:
            if let currentTool = spotlightCurrentToolLabel {
                return "Live · \(currentTool)"
            }
            return "Live"
        case .waitingForApproval:
            return "Approval"
        case .waitingForAnswer:
            return "Question"
        case .completed:
            return jumpTarget != nil ? "Idle" : "Completed"
        }
    }

    var spotlightTerminalLabel: String? {
        guard let jumpTarget else {
            return nil
        }

        return "\(jumpTarget.terminalApp) · \(jumpTarget.workspaceName)"
    }

    var spotlightTerminalBadge: String? {
        jumpTarget?.terminalApp
    }

    /// Orange model badge for Claude Code family sessions.
    /// Returns "Opus 4.6", "Sonnet 4.6", etc. when the model is known;
    /// returns "Claude" as a generic fallback so "Terminal" never appears.
    var spotlightModelBadge: String? {
        guard tool.isClaudeCodeFork else { return nil }

        guard let rawModel = claudeMetadata?.model, !rawModel.isEmpty else {
            return "Claude"
        }

        let lower = rawModel.lowercased()

        // Identify family
        let family: String
        if lower.contains("opus") { family = "Opus" }
        else if lower.contains("sonnet") { family = "Sonnet" }
        else if lower.contains("haiku") { family = "Haiku" }
        else {
            let stripped = lower.hasPrefix("claude-") ? String(lower.dropFirst(7)) : lower
            return stripped.split(separator: "-").prefix(2).map(String.init).joined(separator: " ").capitalized
        }

        // Extract first N.N version pattern (e.g. "4-6" → "4.6")
        let pattern = #"(\d+)-(\d+)"#
        let shortName: String
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r1 = Range(match.range(at: 1), in: lower),
           let r2 = Range(match.range(at: 2), in: lower) {
            shortName = "\(family) \(lower[r1]).\(lower[r2])"
        } else {
            shortName = family
        }

        return shortName
    }

    var spotlightWorkspaceName: String {
        if let workspaceName = jumpTarget?.workspaceName.trimmedForSurface,
           !workspaceName.isEmpty {
            return workspaceName
        }

        let trimmedTitle = title.trimmedForSurface
        let pieces = trimmedTitle.split(separator: "·", maxSplits: 1).map {
            String($0).trimmedForSurface
        }
        if pieces.count == 2, !pieces[1].isEmpty {
            return pieces[1]
        }

        return trimmedTitle
    }

    var spotlightWorktreeBranch: String? {
        claudeMetadata?.worktreeBranch
    }

    var spotlightSubagentLabel: String? {
        guard let subagents = claudeMetadata?.activeSubagents, !subagents.isEmpty else {
            return nil
        }
        return "Subagents (\(subagents.count))"
    }

    var spotlightHeadlineText: String {
        // Priority 1: terminal pane title — exactly what the user sees in the tab
        //             (e.g. "Claude Code -- sourcekit-lsp"). This is the ground truth:
        //             it can't be wrong because it comes from the actual terminal.
        //             Skip auto-generated "Claude XXXXXXXX" placeholders.
        // Priority 2: initial user prompt — descriptive once hooks fire, but can be
        //             wrong when sessions from the same CWD are mismatched in the registry.
        // Priority 3: workspace name — last CWD component (last resort).
        let base: String
        if let pane = meaningfulPaneTitle {
            base = pane
        } else if let prompt = initialPromptText, !prompt.isEmpty {
            base = prompt
        } else {
            base = spotlightWorkspaceName
        }

        if let branch = spotlightWorktreeBranch {
            return "\(base) (\(branch))"
        }

        return base
    }

    /// Returns the pane title when it is a user-meaningful label.
    /// Filters out the auto-generated "Claude XXXXXXXX" placeholder (7 + 8 hex chars = 15)
    /// that transcript discovery creates before real terminal info is available.
    private var meaningfulPaneTitle: String? {
        guard let pane = jumpTarget?.paneTitle.trimmedForSurface,
              !pane.isEmpty else { return nil }
        // "Claude " (7) + 8-char UUID prefix (always hex) = exactly 15 chars
        if pane.count == 15,
           pane.hasPrefix("Claude "),
           pane.dropFirst(7).allSatisfy({ $0.isHexDigit }) {
            return nil
        }
        return pane
    }

    var spotlightHeadlinePromptText: String? {
        // Headline shows the initial prompt (session topic), not the latest.
        // The latest prompt is shown separately in the "You:" line.
        initialPromptText ?? latestPromptText
    }

    var spotlightPromptText: String? {
        latestPromptText
    }

    var spotlightPromptLineText: String? {
        guard spotlightShowsDetailLines,
              let prompt = spotlightPromptText else {
            return nil
        }

        return "You: \(prompt)"
    }

    var notificationHeaderPromptLineText: String? {
        guard phase != .completed else {
            return nil
        }

        return spotlightPromptLineText
    }

    var spotlightActivityLineText: String? {
        guard spotlightShowsDetailLines else {
            return nil
        }

        if let request = permissionRequest?.summary.trimmedForSurface,
           !request.isEmpty {
            return request
        }

        if let prompt = questionPrompt?.title.trimmedForSurface,
           !prompt.isEmpty {
            return prompt
        }

        switch phase {
        case .running:
            if let activity = spotlightRunningActivityText {
                return activity
            }
            return spotlightPromptLineText == nil ? "Running" : "Input"
        case .waitingForApproval:
            return permissionRequest?.summary.trimmedForSurface ?? "Approval needed"
        case .waitingForAnswer:
            return questionPrompt?.title.trimmedForSurface ?? "Answer needed"
        case .completed:
            if let assistantMessage = lastAssistantMessageText?.trimmedForSurface,
               !assistantMessage.isEmpty {
                return assistantMessage
            }

            return jumpTarget != nil ? "Ready" : "Completed"
        }
    }

    var spotlightActivityTone: SpotlightActivityTone {
        if phase.requiresAttention {
            return .attention
        }

        switch phase {
        case .running:
            return .live
        case .completed:
            if lastAssistantMessageText?.trimmedForSurface.isEmpty == false {
                return .idle
            }
            return .ready
        case .waitingForApproval, .waitingForAnswer:
            return .attention
        }
    }

    var spotlightShowsDetailLines: Bool {
        spotlightShowsDetailLines(at: .now)
    }

    func spotlightShowsDetailLines(at referenceDate: Date) -> Bool {
        if phase == .running || phase.requiresAttention {
            return true
        }

        if referenceDate.timeIntervalSince(islandActivityDate) >= Self.collapsedDetailAgeThreshold {
            return false
        }

        return spotlightPromptText != nil || lastAssistantMessageText?.trimmedForSurface.isEmpty == false
    }

    var spotlightAgeBadge: String {
        let age = max(0, Int(Date.now.timeIntervalSince(islandActivityDate)))

        if age < 60 {
            return "<1m"
        }

        if age < 3_600 {
            return "\(max(1, age / 60))m"
        }

        if age < 86_400 {
            return "\(max(1, age / 3_600))h"
        }

        return "\(max(1, age / 86_400))d"
    }

    func islandPresence(at referenceDate: Date) -> IslandSessionPresence {
        if phase == .running {
            return .running
        }

        if phase.requiresAttention {
            return .active
        }

        if referenceDate.timeIntervalSince(islandActivityDate) <= Self.islandActivityThreshold {
            return .active
        }

        return .inactive
    }

    private var spotlightRunningActivityText: String? {
        guard let currentTool = currentToolName?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        let label = currentToolDisplayName(for: currentTool)
        guard let preview = currentCommandPreviewText?.trimmedForSurface,
              !preview.isEmpty else {
            return label
        }

        return "\(label) \(preview)"
    }

    private func currentToolDisplayName(for toolName: String) -> String {
        switch toolName {
        case "exec_command":
            return "Bash"
        case "Bash":
            return "Bash"
        case "AskUserQuestion":
            return "Question"
        case "ExitPlanMode":
            return "Plan"
        case "apply_patch":
            return "Patch"
        case "write_stdin":
            return "Input"
        default:
            return toolName
        }
    }

    private var initialPromptText: String? {
        let prompt = initialUserPromptText?.trimmedForSurface
        guard let prompt, !prompt.isEmpty else {
            return nil
        }

        return prompt
    }

    private var latestPromptText: String? {
        let prompt = latestUserPromptText?.trimmedForSurface
        guard let prompt, !prompt.isEmpty else {
            return nil
        }

        return prompt
    }

    private var prefersLivePromptHeadline: Bool {
        isProcessAlive || phase == .running || phase.requiresAttention
    }
}

private extension String {
    var trimmedForSurface: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
