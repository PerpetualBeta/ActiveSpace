import AppKit

/// Classification of a drift event. `relative` triggers need a prior fingerprint
/// to diff against and are subject to the startup grace window. `absolute`
/// triggers evaluate the current state alone and fire from t=0.
enum RestartTrigger: String {
    // Relative
    case spaceSetChanged     = "space-set-changed"
    case spaceOrderChanged   = "space-order-changed"
    case displayConfigChanged = "display-config-changed"
    // Absolute
    case dockOnVirtual       = "dock-on-virtual"

    var isAbsolute: Bool { self == .dockOnVirtual }
}

/// Subscribes to ReconfigurationObserver, classifies each event against
/// the self-restart criteria defined in the plan, and terminates the app
/// when a qualifying trigger fires. launchd respawns under the keep-alive
/// agent with a clean slate.
@MainActor
final class RestartCoordinator {

    // Tuning
    private let relativeTriggerGrace: TimeInterval = 5.0
    private let dockOnVirtualCooldown: TimeInterval = 30.0

    // UserDefaults keys
    private static let kLastRestartReason = "ActiveSpace.lastRestartReason"
    private static let kLastRestartTime   = "ActiveSpace.lastRestartTime"
    static let kDryRunMode                = "ActiveSpace.restartDryRun"

    private let launchDate: Date
    private let observer: ReconfigurationObserver
    private var dockOnVirtualSuppressedUntil: Date?

    init(observer: ReconfigurationObserver) {
        self.observer = observer
        self.launchDate = Date()

        // If we restarted for dock-on-virtual within the last 30s, hold off
        // on re-firing that trigger — macOS either sorts itself out in this
        // window or we log-only and diagnose from the trail.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.kLastRestartReason) == RestartTrigger.dockOnVirtual.rawValue,
           let lastTime = defaults.object(forKey: Self.kLastRestartTime) as? Date,
           Date().timeIntervalSince(lastTime) < dockOnVirtualCooldown {
            dockOnVirtualSuppressedUntil = lastTime.addingTimeInterval(dockOnVirtualCooldown)
            ActiveSpaceLogger.log("Post-restart cooldown active for dock-on-virtual until \(dockOnVirtualSuppressedUntil!)")
        }
    }

    func start() {
        // Evaluate absolute triggers on the initial fingerprint right away —
        // dock-on-virtual often manifests at/near launch, before any event fires.
        evaluateAbsoluteTriggers(on: observer.currentFingerprint)
    }

    /// Called by AppDelegate wiring: forward each ReconfigurationObserver event here.
    func handle(event: ReconfigurationEvent) {
        var triggers: [RestartTrigger] = []

        // Relative triggers — only count after startup grace has elapsed.
        let withinGrace = Date().timeIntervalSince(launchDate) < relativeTriggerGrace
        if event.changed {
            if Set(event.before.allSpaceUUIDsOrdered) != Set(event.after.allSpaceUUIDsOrdered) {
                triggers.append(.spaceSetChanged)
            } else if event.before.allSpaceUUIDsOrdered != event.after.allSpaceUUIDsOrdered {
                triggers.append(.spaceOrderChanged)
            }
            if event.before.mainDisplayID != event.after.mainDisplayID
                || Set(event.before.displays.map(\.uuid)) != Set(event.after.displays.map(\.uuid)) {
                triggers.append(.displayConfigChanged)
            }
        }

        if withinGrace, !triggers.isEmpty {
            ActiveSpaceLogger.log("  (startup grace — ignored, relative triggers: \(triggers.map(\.rawValue).joined(separator: ",")))")
            triggers.removeAll()
        }

        // Absolute triggers — always live.
        evaluateAbsoluteTriggers(on: event.after, appending: &triggers)

        guard !triggers.isEmpty else { return }
        requestRestart(reason: triggers)
    }

    // MARK: - Absolute trigger evaluation

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint) {
        var triggers: [RestartTrigger] = []
        evaluateAbsoluteTriggers(on: fingerprint, appending: &triggers)
        guard !triggers.isEmpty else { return }
        requestRestart(reason: triggers)
    }

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint, appending triggers: inout [RestartTrigger]) {
        if fingerprint.mainIsSmall {
            if let until = dockOnVirtualSuppressedUntil, Date() < until {
                ActiveSpaceLogger.log("  dock-on-virtual observed but suppressed by post-restart cooldown")
            } else {
                triggers.append(.dockOnVirtual)
            }
        }
    }

    // MARK: - Restart

    private func requestRestart(reason triggers: [RestartTrigger]) {
        let reasonList = triggers.map(\.rawValue).sorted().joined(separator: ",")
        let dryRun = UserDefaults.standard.bool(forKey: Self.kDryRunMode)

        if dryRun {
            ActiveSpaceLogger.log("  verdict=RESTART(\(reasonList)) — DRY RUN, not terminating")
            return
        }

        // Persist for post-restart cooldown decisioning on next launch.
        let defaults = UserDefaults.standard
        defaults.set(reasonList, forKey: Self.kLastRestartReason)
        defaults.set(Date(), forKey: Self.kLastRestartTime)

        ActiveSpaceLogger.log("  verdict=RESTART(\(reasonList))")
        ActiveSpaceLogger.log("Terminating for restart.")
        NSApp.terminate(nil)
    }
}
