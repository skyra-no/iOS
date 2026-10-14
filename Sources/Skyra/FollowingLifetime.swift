// Keeps one installation-owned request attached to its explicit, original host.
#if canImport(UIKit)
import UIKit

@MainActor
final class FollowingLifetime {
    private weak var sdk: Skyra?
    private var sceneActive: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var delayContinuation: CheckedContinuation<Void, Error>?
    private var delayTask: Task<Void, Never>?
    private var remaining: TimeInterval = 0
    private var lastEligibleTime: TimeInterval
    private let now: () -> TimeInterval
    private let waitForDelay: (UInt64) async throws -> Void
    private var host: FollowingHost?
    private var hostIdentity: ObjectIdentifier?
    private(set) var available = false
    private(set) var invalidated = false
    var onInvalidate: (() -> Void)?

    init(sdk: Skyra, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sdk = sdk
        self.now = now
        waitForDelay = sdk.waitForDelay
        sceneActive = sdk.sceneActive
        lastEligibleTime = now()
    }

    func start() {
        guard let sdk else {
            return
        }

        sdk.followingLifetime = self
        host = sdk.followingHost
        hostIdentity = host.map(ObjectIdentifier.init)
        host?.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func setActive(_ active: Bool) {
        accountElapsedTime()
        sceneActive = active
        refresh()
    }

    func refresh() {
        guard !invalidated, let sdk else {
            return
        }

        let nextHost = sdk.followingHost
        if let host, !host.isValid {
            invalidate()
            return
        }
        if let priorIdentity = hostIdentity, nextHost.map(ObjectIdentifier.init) != priorIdentity {
            invalidate()
            return
        }
        if host == nil, let nextHost {
            host = nextHost
            hostIdentity = ObjectIdentifier(nextHost)
            nextHost.onChange = { [weak self] in self?.refresh() }
        }

        accountElapsedTime()
        let hostReady = host?.isAvailable ?? false
        let nextAvailable = sceneActive && sdk.sceneActive && hostReady
        guard nextAvailable != available else {
            if nextAvailable {
                resumeWaitersIfReady()
            }
            return
        }

        available = nextAvailable
        if let controller = sdk.active, controller.ownershipRole == .installationFollowing {
            controller.setSuspended(!available)
        }
        if available {
            resumeWaitersIfReady()
            scheduleDelayIfNeeded()
        } else {
            // Make the canceled sleeper obsolete before cancellation can reach its catch block.
            delayGeneration = nil
            delayTask?.cancel()
            delayTask = nil
        }
    }

    private func accountElapsedTime() {
        let current = now()
        if available, delayContinuation != nil {
            remaining = max(0, remaining - max(0, current - lastEligibleTime))
        }
        lastEligibleTime = current
        if available, remaining <= 0 {
            finishDelay()
        }
    }

    private func resumeWaitersIfReady() {
        let waiting = waiters
        waiters.removeAll()
        waiting.values.forEach { $0.resume() }
        scheduleDelayIfNeeded()
    }

    func waitUntilAvailable() async throws {
        while true {
            try Task.checkCancellation()
            refresh()
            if invalidated {
                throw CancellationError()
            }
            if available {
                return
            }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = continuation
                    if Task.isCancelled {
                        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }
    }

    func wait(milliseconds: Double) async throws {
        try await waitUntilAvailable()
        guard milliseconds > 0 else {
            return
        }

        remaining = milliseconds / 1_000
        lastEligibleTime = now()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delayContinuation = continuation
                scheduleDelayIfNeeded()
                if Task.isCancelled {
                    cancelDelay()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDelay() }
        }
        try await waitUntilAvailable()
    }

    private func scheduleDelayIfNeeded() {
        guard available, delayContinuation != nil, delayTask == nil else {
            return
        }

        if remaining <= 0 {
            finishDelay()
            return
        }
        let generation = UUID()
        delayGeneration = generation
        let nanos = UInt64(min(remaining, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        let wait = waitForDelay
        delayTask = Task { [weak self, wait] in
            do {
                try await wait(nanos)
            } catch {
                guard let self, self.delayGeneration == generation, self.available else {
                    return
                }

                self.delayTask = nil
                self.delayGeneration = nil
                let continuation = self.delayContinuation
                self.delayContinuation = nil
                continuation?.resume(throwing: error)
                return
            }
            guard let self, self.delayGeneration == generation, self.available else {
                return
            }

            self.accountElapsedTime()
            if self.remaining > 0 {
                self.delayTask = nil
                self.scheduleDelayIfNeeded()
            } else {
                self.finishDelay()
            }
        }
    }

    private var delayGeneration: UUID?

    private func finishDelay() {
        guard delayContinuation != nil, remaining <= 0 else {
            return
        }

        delayTask?.cancel()
        delayTask = nil
        delayGeneration = nil
        let continuation = delayContinuation
        delayContinuation = nil
        continuation?.resume()
    }

    private func cancelDelay() {
        delayTask?.cancel()
        delayTask = nil
        delayGeneration = nil
        let continuation = delayContinuation
        delayContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func invalidate() {
        guard !invalidated else {
            return
        }

        let callback = onInvalidate
        onInvalidate = nil
        stop()
        callback?()
    }

    func stop() {
        guard !invalidated else {
            return
        }

        invalidated = true
        available = false
        if let host, host.onChange != nil {
            host.onChange = nil
        }
        host = nil
        hostIdentity = nil
        delayTask?.cancel()
        delayTask = nil
        delayGeneration = nil
        let waiting = waiters
        waiters.removeAll()
        waiting.values.forEach { $0.resume(throwing: CancellationError()) }
        let delay = delayContinuation
        delayContinuation = nil
        delay?.resume(throwing: CancellationError())
    }
}
#endif
