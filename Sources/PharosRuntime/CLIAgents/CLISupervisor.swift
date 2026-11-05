import Foundation
import PharosMeshCore

public struct CLISupervisor: Sendable {
    public struct Attempt: Codable, Equatable, Sendable {
        public var lastAttempt: Date
        public var failures: Int
        public var lastError: String?

        public init(lastAttempt: Date, failures: Int, lastError: String? = nil) {
            self.lastAttempt = lastAttempt
            self.failures = failures
            self.lastError = lastError
        }
    }

    public var lifecycle: CLIAgentLifecycle
    public var node: String
    public var stateStore: URL
    public var reviveBackoff: TimeInterval
    public var maxReviveFailures: Int
    public var now: @Sendable () -> Date

    public init(
        lifecycle: CLIAgentLifecycle,
        node: String,
        stateStore: URL,
        reviveBackoff: TimeInterval = 120,
        maxReviveFailures: Int = 3,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lifecycle = lifecycle
        self.node = node
        self.stateStore = stateStore
        self.reviveBackoff = reviveBackoff
        self.maxReviveFailures = maxReviveFailures
        self.now = now
    }

    public func pass(members: [LightMember]) -> [LightMemberRuntimeReport] {
        var attempts = loadAttempts()
        var reports: [LightMemberRuntimeReport] = []
        let moment = now()
        var stateChanged = false

        for member in members where CLIAgentDriver.handles(member) {
            guard var currentBinding = member.tmux else { continue }

            var memberAttempt = attempts[member.name]
            // A manual revive/launch (binding.launchedAt newer than lastAttempt) resets failures.
            if let att = memberAttempt, let launched = currentBinding.launchedAt, launched > att.lastAttempt {
                memberAttempt = Attempt(lastAttempt: att.lastAttempt, failures: 0, lastError: nil)
                attempts[member.name] = memberAttempt
                stateChanged = true
            }

            let st = lifecycle.status(member: member)
            let isAlive = (st.live == "alive")

            var newlyEndedBinding: LightTmuxBinding? = nil

            if !isAlive && currentBinding.endedAt == nil {
                var updated = currentBinding
                updated.endedAt = moment
                if updated.endedReason == nil {
                    updated.endedReason = "exited"
                }
                currentBinding = updated
                newlyEndedBinding = updated
            }

            let notAliveLiveStr: String = (currentBinding.endedReason == "stopped") ? "stopped" : "ended"

            // Auto-revive (opt-in):
            // binding.autoRevive == true, endedReason != "stopped", not alive, failures < max and now - lastAttempt >= backoff
            if currentBinding.autoRevive == true &&
                currentBinding.endedReason != "stopped" &&
                !isAlive {

                let currentFailures = memberAttempt?.failures ?? 0
                let canTryBackoff: Bool = {
                    guard let lastAttempt = memberAttempt?.lastAttempt else { return true }
                    return moment.timeIntervalSince(lastAttempt) >= reviveBackoff
                }()

                if currentFailures < maxReviveFailures && canTryBackoff {
                    var att = memberAttempt ?? Attempt(lastAttempt: moment, failures: currentFailures, lastError: nil)
                    att.lastAttempt = moment

                    var memberToRevive = member
                    memberToRevive.tmux = currentBinding

                    do {
                        let revivedBinding = try lifecycle.revive(member: memberToRevive)
                        att.failures = 0
                        att.lastError = nil
                        attempts[member.name] = att
                        stateChanged = true

                        reports.append(LightMemberRuntimeReport(
                            member: member.name,
                            node: node,
                            tmux: revivedBinding.session,
                            live: "alive",
                            activity: "idle",
                            detail: "auto-revived",
                            at: moment,
                            binding: revivedBinding
                        ))
                        continue
                    } catch {
                        att.failures += 1
                        att.lastError = error.localizedDescription
                        attempts[member.name] = att
                        stateChanged = true

                        let detail: String
                        if att.failures >= maxReviveFailures {
                            detail = "auto-revive gave up after \(maxReviveFailures) failures; run pharos member revive \(member.name)"
                        } else {
                            detail = "auto-revive failed (\(att.failures)/\(maxReviveFailures)): \(error.localizedDescription)"
                        }

                        reports.append(LightMemberRuntimeReport(
                            member: member.name,
                            node: node,
                            tmux: currentBinding.session,
                            live: notAliveLiveStr,
                            activity: "unknown",
                            detail: String(detail.prefix(160)),
                            at: moment,
                            binding: newlyEndedBinding
                        ))
                        continue
                    }
                }
            }

            // Otherwise report st
            let live = isAlive ? st.live : notAliveLiveStr
            let activity = isAlive ? st.activity.rawValue : "unknown"
            let detail: String
            if let att = memberAttempt, att.failures >= maxReviveFailures, !isAlive {
                detail = "auto-revive gave up after \(maxReviveFailures) failures; run pharos member revive \(member.name)"
            } else if isAlive {
                detail = st.detail
            } else {
                detail = st.detail.isEmpty ? live : st.detail
            }

            reports.append(LightMemberRuntimeReport(
                member: member.name,
                node: node,
                tmux: currentBinding.session,
                live: live,
                activity: activity,
                detail: String(detail.prefix(160)),
                at: moment,
                binding: newlyEndedBinding
            ))
        }

        if stateChanged {
            saveAttempts(attempts)
        }

        return reports
    }

    private func loadAttempts() -> [String: Attempt] {
        guard FileManager.default.fileExists(atPath: stateStore.path),
              let data = try? Data(contentsOf: stateStore) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: Attempt].self, from: data)) ?? [:]
    }

    private func saveAttempts(_ attempts: [String: Attempt]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(attempts) else { return }
        try? FileManager.default.createDirectory(at: stateStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateStore, options: .atomic)
    }
}
