import Darwin
import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct ClaudeSessionLifecycleIntegrationTests {
    @Test
    func hookManagedClaudeSessionsSurviveEmptyProcessDiscoveryCycles() async throws {
        var processes: [Process] = []
        defer { processes.forEach { $0.ensureExited() } }

        var fixtures: [SessionFixture] = []
        let originalUpdatedAt = Date().addingTimeInterval(-600)

        for index in 1...4 {
            let process = try spawnSleep(duration: 30)
            processes.append(process)
            fixtures.append(
                SessionFixture(
                    id: "integration-session-\(index)",
                    pid: process.processIdentifier,
                    workspaceName: "integration-proj-\(index)",
                    workingDirectory: "/tmp/integration-proj-\(index)",
                    paneTitle: "claude-\(index)",
                    summary: "session \(index) summary",
                    initialUserPrompt: "session \(index) initial prompt",
                    lastUserPrompt: "session \(index) latest",
                    updatedAt: originalUpdatedAt
                )
            )
        }

        let model = AppModel()
        model.state = SessionState(sessions: fixtures.map { $0.makeSession() })

        for fixture in fixtures {
            model.bridgeServer.adoptClaudeSessionProcess(sessionID: fixture.id, pid: fixture.pid)
        }

        for fixture in fixtures {
            #expect(
                waitForCondition { model.bridgeServer.hasClaudeMonitorForSession(fixture.id) },
                "Monitor should be tracking \(fixture.id) after adoption"
            )
        }

        for _ in 0..<10 {
            model.monitoring.reconcileSessionAttachments(activeProcesses: [])
        }

        for fixture in fixtures {
            let restored = model.state.session(id: fixture.id)
            #expect(restored != nil)
            #expect(restored?.phase == .running)
            #expect(restored?.isSessionEnded == false)
            #expect(restored?.claudeMetadata?.initialUserPrompt == fixture.initialUserPrompt)
            #expect(restored?.claudeMetadata?.lastUserPrompt == fixture.lastUserPrompt)
            #expect(restored?.claudeMetadata?.agentPID == fixture.pid)
            if let updated = restored?.updatedAt {
                #expect(abs(updated.timeIntervalSince(originalUpdatedAt)) < 0.01)
            }
        }
    }

    @Test
    func killingOneClaudeProcessFlipsOnlyThatSessionToCompleted() async throws {
        var processes: [Process] = []
        defer { processes.forEach { $0.ensureExited() } }

        var fixtures: [SessionFixture] = []
        let originalUpdatedAt = Date().addingTimeInterval(-600)

        for index in 1...4 {
            let process = try spawnSleep(duration: 30)
            processes.append(process)
            fixtures.append(
                SessionFixture(
                    id: "kill-session-\(index)",
                    pid: process.processIdentifier,
                    workspaceName: "kill-proj-\(index)",
                    workingDirectory: "/tmp/kill-proj-\(index)",
                    paneTitle: "claude-\(index)",
                    summary: "session \(index) summary",
                    initialUserPrompt: "session \(index) initial prompt",
                    lastUserPrompt: "session \(index) latest",
                    updatedAt: originalUpdatedAt
                )
            )
        }

        let model = AppModel()
        model.state = SessionState(sessions: fixtures.map { $0.makeSession() })

        for fixture in fixtures {
            model.bridgeServer.adoptClaudeSessionProcess(sessionID: fixture.id, pid: fixture.pid)
        }

        for fixture in fixtures {
            #expect(
                waitForCondition { model.bridgeServer.hasClaudeMonitorForSession(fixture.id) },
                "Monitor should be tracking \(fixture.id) after adoption"
            )
        }

        let targetIndex = 1
        let target = fixtures[targetIndex]
        let targetProcess = processes[targetIndex]

        targetProcess.terminate()
        targetProcess.waitUntilExit()

        // AppModel's BridgeServer is constructed with the default 5s grace;
        // wait for the kernel exit + grace period to elapse and the server's
        // internal handler to untrack the monitor.
        #expect(
            waitForCondition(timeout: 12.0) {
                model.bridgeServer.hasClaudeMonitorForSession(target.id) == false
            },
            "Monitor for killed session should untrack after grace period"
        )

        // AppModel's bridge observer only connects when startApp(startBridge: true)
        // runs; this isolated test has no listener on the server's emit, so
        // drive the reducer directly with the same event the bridge would have
        // emitted. Using .rollout ingress avoids the attachment/liveness side
        // effects that the bridge ingress path applies (attached/processAlive),
        // which would otherwise fight the reducer's isProcessAlive = false.
        model.applyTrackedEvent(
            .claudeProcessExited(ClaudeProcessExited(
                sessionID: target.id,
                pid: target.pid,
                timestamp: .now
            )),
            updateLastActionMessage: false,
            ingress: .rollout
        )

        let killed = model.state.session(id: target.id)
        #expect(killed?.phase == .completed)
        #expect(killed?.isSessionEnded == true)
        #expect(killed?.isProcessAlive == false)

        for (index, fixture) in fixtures.enumerated() where index != targetIndex {
            let survivor = model.state.session(id: fixture.id)
            #expect(survivor?.phase == .running)
            #expect(survivor?.isSessionEnded == false)
            #expect(model.bridgeServer.hasClaudeMonitorForSession(fixture.id) == true)
        }

        #expect(model.bridgeServer.hasClaudeMonitorForSession(target.id) == false)
    }
}

// MARK: - Helpers

private struct SessionFixture {
    let id: String
    let pid: Int32
    let workspaceName: String
    let workingDirectory: String
    let paneTitle: String
    let summary: String
    let initialUserPrompt: String
    let lastUserPrompt: String
    let updatedAt: Date

    func makeSession() -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · \(workspaceName)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: summary,
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: workspaceName,
                paneTitle: paneTitle,
                workingDirectory: workingDirectory
            ),
            claudeMetadata: ClaudeSessionMetadata(
                initialUserPrompt: initialUserPrompt,
                lastUserPrompt: lastUserPrompt,
                agentPID: pid
            )
        )
        session.isHookManaged = true
        session.isProcessAlive = true
        return session
    }
}

private func spawnSleep(duration: Double) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [String(duration)]
    try process.run()
    return process
}

private extension Process {
    func ensureExited() {
        if isRunning {
            terminate()
            waitUntilExit()
        }
    }
}

@MainActor
private func waitForCondition(
    timeout: TimeInterval = 4.0,
    _ check: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if check() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return check()
}
