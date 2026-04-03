import AppKit
import Foundation
import VibeIslandCore

struct TerminalSessionAttachmentProbe {
    struct SessionResolution {
        var attachmentState: SessionAttachmentState
        var correctedJumpTarget: JumpTarget?
    }

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
        sessionResolutions(
            for: sessions,
            ghosttyAvailability: ghosttySnapshotAvailability(),
            terminalAvailability: terminalSnapshotAvailability(),
            now: now
        ).mapValues(\.attachmentState)
    }

    func sessionResolutions(for sessions: [AgentSession], now: Date = .now) -> [String: SessionResolution] {
        sessionResolutions(
            for: sessions,
            ghosttyAvailability: ghosttySnapshotAvailability(),
            terminalAvailability: terminalSnapshotAvailability(),
            now: now
        )
    }

    func sessionResolutions(
        for sessions: [AgentSession],
        ghosttyAvailability: SnapshotAvailability<GhosttyTerminalSnapshot>,
        terminalAvailability: SnapshotAvailability<TerminalTabSnapshot>,
        now: Date = .now
    ) -> [String: SessionResolution] {
        guard !sessions.isEmpty else {
            return [:]
        }

        let ghosttySessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty" }
        let terminalSessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "terminal" }
        let attachedGhosttySessions = attachedGhosttySessions(
            for: ghosttySessions,
            availability: ghosttyAvailability
        )
        let attachedTerminalSessionIDs = attachedTerminalSessionIDs(
            for: terminalSessions,
            availability: terminalAvailability
        )

        var resolutions: [String: SessionResolution] = [:]

        for session in sessions {
            if ghosttySessions.contains(where: { $0.id == session.id }) {
                let matchedSnapshot = attachedGhosttySessions[session.id]
                resolutions[session.id] = SessionResolution(
                    attachmentState: resolveAttachmentState(
                        for: session,
                        isMatched: matchedSnapshot != nil,
                        availability: ghosttyAvailability,
                        now: now
                    ),
                    correctedJumpTarget: matchedSnapshot.flatMap { correctedGhosttyJumpTarget(for: session, snapshot: $0) }
                )
                continue
            }

            if terminalSessions.contains(where: { $0.id == session.id }) {
                resolutions[session.id] = SessionResolution(
                    attachmentState: resolveAttachmentState(
                        for: session,
                        isMatched: attachedTerminalSessionIDs.contains(session.id),
                        availability: terminalAvailability,
                        now: now
                    ),
                    correctedJumpTarget: nil
                )
                continue
            }

            resolutions[session.id] = SessionResolution(
                attachmentState: fallbackAttachmentState(
                    for: session,
                    appIsRunning: nil,
                    allowRecentAttachmentGrace: true,
                    now: now
                ),
                correctedJumpTarget: nil
            )
        }

        return resolutions
    }

    func attachmentStates(
        for sessions: [AgentSession],
        ghosttyAvailability: SnapshotAvailability<GhosttyTerminalSnapshot>,
        terminalAvailability: SnapshotAvailability<TerminalTabSnapshot>,
        now: Date = .now
    ) -> [String: SessionAttachmentState] {
        sessionResolutions(
            for: sessions,
            ghosttyAvailability: ghosttyAvailability,
            terminalAvailability: terminalAvailability,
            now: now
        ).mapValues(\.attachmentState)
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

    private func attachedGhosttySessions(
        for sessions: [AgentSession],
        availability: SnapshotAvailability<GhosttyTerminalSnapshot>
    ) -> [String: GhosttyTerminalSnapshot] {
        guard let snapshots = availability.snapshots else {
            return [:]
        }

        var assignments: [String: GhosttyTerminalSnapshot] = [:]
        var claimedSessionIDs: Set<String> = []
        var claimedSnapshotIDs: Set<String> = []

        for snapshot in snapshots {
            let matches = sessions.filter { session in
                nonEmptyValue(session.jumpTarget?.terminalSessionID) == snapshot.sessionID
            }

            guard let preferred = preferredSession(from: matches) else {
                continue
            }

            assignments[preferred.id] = snapshot
            claimedSessionIDs.insert(preferred.id)
            claimedSnapshotIDs.insert(snapshot.sessionID)
        }

        for snapshot in snapshots where !claimedSnapshotIDs.contains(snapshot.sessionID) {
            let matches = sessions.filter { session in
                guard !claimedSessionIDs.contains(session.id),
                      let jumpTarget = session.jumpTarget,
                      canFallbackFromRecordedGhosttySessionID(jumpTarget, claimedSnapshotIDs: claimedSnapshotIDs) else {
                    return false
                }

                if nonEmptyValue(jumpTarget.workingDirectory) == snapshot.workingDirectory {
                    return true
                }

                return sessionWorkspaceNameCandidates(for: session).contains(snapshotWorkspaceName(for: snapshot))
            }

            guard let preferred = preferredSession(from: matches) else {
                continue
            }

            assignments[preferred.id] = snapshot
            claimedSessionIDs.insert(preferred.id)
            claimedSnapshotIDs.insert(snapshot.sessionID)
        }

        return assignments
    }

    private func canFallbackFromRecordedGhosttySessionID(
        _ jumpTarget: JumpTarget,
        claimedSnapshotIDs: Set<String>
    ) -> Bool {
        guard let recordedSessionID = nonEmptyValue(jumpTarget.terminalSessionID) else {
            return true
        }

        return claimedSnapshotIDs.contains(recordedSessionID)
    }

    private func sessionWorkspaceNameCandidates(for session: AgentSession) -> Set<String> {
        var candidates: Set<String> = []

        if let workspaceName = nonEmptyValue(session.jumpTarget?.workspaceName) {
            candidates.insert(workspaceName)
        }

        if let workingDirectory = nonEmptyValue(session.jumpTarget?.workingDirectory) {
            let derivedWorkspace = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !derivedWorkspace.isEmpty {
                candidates.insert(derivedWorkspace)
            }
        }

        let titlePieces = session.title
            .split(separator: "·", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if titlePieces.count == 2, !titlePieces[1].isEmpty {
            candidates.insert(titlePieces[1])
        }

        return candidates
    }

    private func snapshotWorkspaceName(for snapshot: GhosttyTerminalSnapshot) -> String {
        URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent
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

    private func correctedGhosttyJumpTarget(
        for session: AgentSession,
        snapshot: GhosttyTerminalSnapshot
    ) -> JumpTarget? {
        guard var jumpTarget = session.jumpTarget else {
            return nil
        }

        var changed = false

        if nonEmptyValue(jumpTarget.terminalSessionID) != snapshot.sessionID {
            jumpTarget.terminalSessionID = snapshot.sessionID
            changed = true
        }

        if nonEmptyValue(jumpTarget.workingDirectory) != snapshot.workingDirectory {
            jumpTarget.workingDirectory = snapshot.workingDirectory
            changed = true
        }

        if let title = nonEmptyValue(snapshot.title), title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        let workspaceName = URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent
        if !workspaceName.isEmpty, workspaceName != jumpTarget.workspaceName {
            jumpTarget.workspaceName = workspaceName
            changed = true
        }

        return changed ? jumpTarget : nil
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

            if session.currentToolName?.isEmpty == false && age <= Self.liveGraceWindow {
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
