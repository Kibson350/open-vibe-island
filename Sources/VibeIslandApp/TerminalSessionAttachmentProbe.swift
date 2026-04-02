import AppKit
import Foundation
import VibeIslandCore

struct TerminalSessionAttachmentProbe {
    struct GhosttyTerminalSnapshot {
        var sessionID: String
        var workingDirectory: String
        var title: String
    }

    struct TerminalTabSnapshot {
        var tty: String
        var customTitle: String
    }

    enum SnapshotAvailability<Snapshot> {
        case unavailable(appIsRunning: Bool)
        case available([Snapshot], appIsRunning: Bool)

        var appIsRunning: Bool {
            switch self {
            case let .unavailable(appIsRunning):
                appIsRunning
            case let .available(_, appIsRunning):
                appIsRunning
            }
        }

        var hasExplicitSnapshotData: Bool {
            if case .available = self {
                return true
            }

            return false
        }

        var snapshots: [Snapshot]? {
            if case let .available(snapshots, _) = self {
                return snapshots
            }

            return nil
        }
    }

    private static let liveGraceWindow: TimeInterval = 120
    private static let staleGraceWindow: TimeInterval = 15 * 60
    private static let fieldSeparator = "\u{1f}"
    private static let recordSeparator = "\u{1e}"

    func attachmentStates(for sessions: [AgentSession], now: Date = .now) -> [String: SessionAttachmentState] {
        attachmentStates(
            for: sessions,
            ghosttyAvailability: ghosttySnapshotAvailability(),
            terminalAvailability: terminalSnapshotAvailability(),
            now: now
        )
    }

    func attachmentStates(
        for sessions: [AgentSession],
        ghosttyAvailability: SnapshotAvailability<GhosttyTerminalSnapshot>,
        terminalAvailability: SnapshotAvailability<TerminalTabSnapshot>,
        now: Date = .now
    ) -> [String: SessionAttachmentState] {
        guard !sessions.isEmpty else {
            return [:]
        }

        let ghosttySessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty" }
        let terminalSessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "terminal" }
        let attachedGhosttySessionIDs = attachedGhosttySessionIDs(
            for: ghosttySessions,
            availability: ghosttyAvailability
        )
        let attachedTerminalSessionIDs = attachedTerminalSessionIDs(
            for: terminalSessions,
            availability: terminalAvailability
        )

        var updates: [String: SessionAttachmentState] = [:]

        for session in sessions {
            if ghosttySessions.contains(where: { $0.id == session.id }) {
                updates[session.id] = resolveAttachmentState(
                    for: session,
                    isMatched: attachedGhosttySessionIDs.contains(session.id),
                    availability: ghosttyAvailability,
                    now: now
                )
                continue
            }

            if terminalSessions.contains(where: { $0.id == session.id }) {
                updates[session.id] = resolveAttachmentState(
                    for: session,
                    isMatched: attachedTerminalSessionIDs.contains(session.id),
                    availability: terminalAvailability,
                    now: now
                )
                continue
            }

            updates[session.id] = fallbackAttachmentState(
                for: session,
                appIsRunning: nil,
                allowRecentAttachmentGrace: true,
                now: now
            )
        }

        return updates
    }

    private func resolveAttachmentState<Snapshot>(
        for session: AgentSession,
        isMatched: Bool,
        availability: SnapshotAvailability<Snapshot>,
        now: Date
    ) -> SessionAttachmentState {
        if isMatched {
            return .attached
        }

        return fallbackAttachmentState(
            for: session,
            appIsRunning: availability.appIsRunning,
            allowRecentAttachmentGrace: !availability.hasExplicitSnapshotData,
            now: now
        )
    }

    private func attachedGhosttySessionIDs(
        for sessions: [AgentSession],
        availability: SnapshotAvailability<GhosttyTerminalSnapshot>
    ) -> Set<String> {
        guard let snapshots = availability.snapshots else {
            return []
        }

        return Set(snapshots.compactMap { snapshot in
            preferredSession(
                from: sessions.filter { ghosttySnapshot(snapshot, matches: $0) }
            )?.id
        })
    }

    private func attachedTerminalSessionIDs(
        for sessions: [AgentSession],
        availability: SnapshotAvailability<TerminalTabSnapshot>
    ) -> Set<String> {
        guard let snapshots = availability.snapshots else {
            return []
        }

        return Set(snapshots.compactMap { snapshot in
            preferredSession(
                from: sessions.filter { terminalSnapshot(snapshot, matches: $0) }
            )?.id
        })
    }

    private func ghosttySnapshot(_ snapshot: GhosttyTerminalSnapshot, matches session: AgentSession) -> Bool {
        guard let jumpTarget = session.jumpTarget else {
            return false
        }

        if let sessionID = nonEmptyValue(jumpTarget.terminalSessionID) {
            return snapshot.sessionID == sessionID
        }

        if let workingDirectory = nonEmptyValue(jumpTarget.workingDirectory) {
            return snapshot.workingDirectory == workingDirectory
        }

        guard let paneTitle = nonEmptyValue(jumpTarget.paneTitle) else {
            return false
        }

        return snapshot.title.contains(paneTitle)
    }

    private func terminalSnapshot(_ snapshot: TerminalTabSnapshot, matches session: AgentSession) -> Bool {
        guard let jumpTarget = session.jumpTarget else {
            return false
        }

        if let tty = nonEmptyValue(jumpTarget.terminalTTY) {
            return snapshot.tty == tty
        }

        guard let paneTitle = nonEmptyValue(jumpTarget.paneTitle) else {
            return false
        }

        return snapshot.customTitle.contains(paneTitle)
    }

    private func preferredSession(from sessions: [AgentSession]) -> AgentSession? {
        sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }

            if phasePriority(lhs.phase) != phasePriority(rhs.phase) {
                return phasePriority(lhs.phase) > phasePriority(rhs.phase)
            }

            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }.first
    }

    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval:
            4
        case .waitingForAnswer:
            3
        case .running:
            2
        case .completed:
            1
        }
    }

    private func fallbackAttachmentState(
        for session: AgentSession,
        appIsRunning: Bool?,
        allowRecentAttachmentGrace: Bool,
        now: Date
    ) -> SessionAttachmentState {
        let age = now.timeIntervalSince(session.updatedAt)

        if session.phase.requiresAttention {
            return .attached
        }

        if allowRecentAttachmentGrace {
            if session.attachmentState == .attached && age <= Self.liveGraceWindow {
                return .attached
            }

            if session.codexMetadata?.currentTool?.isEmpty == false && age <= Self.liveGraceWindow {
                return .attached
            }
        }

        if let appIsRunning, appIsRunning == false {
            return age <= Self.staleGraceWindow ? .stale : .detached
        }

        return age <= Self.staleGraceWindow ? .stale : .detached
    }

    private func ghosttySnapshotAvailability() -> SnapshotAvailability<GhosttyTerminalSnapshot> {
        let appIsRunning = isRunning(bundleIdentifier: "com.mitchellh.ghostty")
        guard appIsRunning else {
            return .available([], appIsRunning: false)
        }

        do {
            return .available(try ghosttySnapshots(), appIsRunning: true)
        } catch {
            return .unavailable(appIsRunning: true)
        }
    }

    private func terminalSnapshotAvailability() -> SnapshotAvailability<TerminalTabSnapshot> {
        let appIsRunning = isRunning(bundleIdentifier: "com.apple.Terminal")
        guard appIsRunning else {
            return .available([], appIsRunning: false)
        }

        do {
            return .available(try terminalSnapshots(), appIsRunning: true)
        } catch {
            return .unavailable(appIsRunning: true)
        }
    }

    private func nonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func ghosttySnapshots() throws -> [GhosttyTerminalSnapshot] {
        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Ghostty"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aTerminal in terminals
                set terminalID to ""
                set terminalDirectory to ""
                set terminalTitle to ""
                try
                    set terminalID to (id of aTerminal as text)
                end try
                try
                    set terminalDirectory to (working directory of aTerminal as text)
                end try
                try
                    set terminalTitle to (name of aTerminal as text)
                end try
                set end of outputLines to terminalID & fieldSeparator & terminalDirectory & fieldSeparator & terminalTitle
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        let output = try runAppleScript(script)
        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 3 else {
                    return nil
                }

                return GhosttyTerminalSnapshot(
                    sessionID: values[0],
                    workingDirectory: values[1],
                    title: values[2]
                )
            }
    }

    private func terminalSnapshots() throws -> [TerminalTabSnapshot] {
        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Terminal"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    set tabTTY to ""
                    set tabTitle to ""
                    try
                        set tabTTY to (tty of aTab as text)
                    end try
                    try
                        set tabTitle to (custom title of aTab as text)
                    end try
                    set end of outputLines to tabTTY & fieldSeparator & tabTitle
                end repeat
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        let output = try runAppleScript(script)
        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 2 else {
                    return nil
                }

                return TerminalTabSnapshot(
                    tty: values[0],
                    customTitle: values[1]
                )
            }
    }

    private func normalizedTerminalName(for value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
    }

    private func runAppleScript(_ script: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard task.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "TerminalSessionAttachmentProbe", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: stderr.isEmpty ? "AppleScript probe failed." : stderr,
            ])
        }

        return output
    }
}
