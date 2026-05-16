import AppKit

/// Classification of a drift event. `relative` triggers need a prior
/// fingerprint to diff against and are suppressed during the startup
/// grace window (ActiveSpace's own virtual-display creation causes a
/// displayConfigChanged event at launch that isn't real drift).
/// `absolute` triggers evaluate the current state alone and fire from t=0.
enum DriftTrigger: String {
    case spaceSetChanged      = "space-set-changed"
    case spaceOrderChanged    = "space-order-changed"
    case displayConfigChanged = "display-config-changed"
    case dockOnVirtual        = "dock-on-virtual"

    var isAbsolute: Bool { self == .dockOnVirtual }
}

/// Subscribes to ReconfigurationObserver, classifies each event against
/// the drift criteria, and **terminates the app on qualifying drift** so
/// the launchd keep-alive agent can respawn it with a clean slate. Also
/// logs before/after fingerprints for diagnostic value.
///
/// Restart was demoted to diagnostic-only in commit 041de05 on the theory
/// that finer-grained mitigations (reconcile + enforceVirtualPosition +
/// cursor fence) were sufficient. Restored 2026-05-16 after the
/// mitigations turned out *not* to fully cover the cases users see in
/// practice (single-display window drift, lingering virtual after
/// ungraceful exit). Process respawn is the sledgehammer that brings the
/// app back to known-good state without trying to patch every edge case
/// in-place.
///
/// **Cooldown:** a dock-on-virtual restart suppresses the same trigger
/// for 30s post-respawn (persisted via UserDefaults) so a stuck virtual
/// doesn't loop us. **Dry-run mode:** set
/// `defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.restartDryRun -bool YES`
/// to log "verdict=RESTART" without terminating — useful when bisecting
/// trigger thresholds.
@MainActor
final class DriftMonitor {

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
        // window or we keep the surface around for diagnosis.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.kLastRestartReason) == DriftTrigger.dockOnVirtual.rawValue,
           let lastTime = defaults.object(forKey: Self.kLastRestartTime) as? Date,
           Date().timeIntervalSince(lastTime) < dockOnVirtualCooldown {
            dockOnVirtualSuppressedUntil = lastTime.addingTimeInterval(dockOnVirtualCooldown)
            aslog("Post-restart cooldown active for dock-on-virtual until \(dockOnVirtualSuppressedUntil!)")
        }
    }

    func start() {
        evaluateAbsoluteTriggers(on: observer.currentFingerprint)
    }

    /// Called by AppDelegate wiring: forward each ReconfigurationObserver event here.
    func handle(event: ReconfigurationEvent) {
        var triggers: [DriftTrigger] = []

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
            aslog("  (startup grace — ignored, relative triggers: \(triggers.map(\.rawValue).joined(separator: ",")))")
            triggers.removeAll()
        }

        evaluateAbsoluteTriggers(on: event.after, appending: &triggers)

        guard !triggers.isEmpty else { return }
        logDrift(triggers, before: event.before, after: event.after)
    }

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint) {
        var triggers: [DriftTrigger] = []
        evaluateAbsoluteTriggers(on: fingerprint, appending: &triggers)
        guard !triggers.isEmpty else { return }
        logDrift(triggers, before: nil, after: fingerprint)
    }

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint, appending triggers: inout [DriftTrigger]) {
        if fingerprint.mainIsSmall {
            if let until = dockOnVirtualSuppressedUntil, Date() < until {
                aslog("  dock-on-virtual observed but suppressed by post-restart cooldown")
            } else {
                triggers.append(.dockOnVirtual)
            }
        }
    }

    /// Emit a drift verdict with full before/after context, persist the
    /// restart reason for next-launch cooldown decisioning, and terminate
    /// (unless dry-run is set). launchd respawns the process via the
    /// keep-alive agent registered in AppDelegate.
    ///
    /// `before` is nil for startup absolute-trigger evaluations where
    /// there's no prior fingerprint to diff against.
    private func logDrift(_ triggers: [DriftTrigger], before: ActiveSpaceFingerprint?, after: ActiveSpaceFingerprint) {
        if let before {
            aslog("  before: \(before)")
            aslog("  after:  \(after)")
        } else {
            aslog("  state:  \(after)")
        }
        let list = triggers.map(\.rawValue).sorted().joined(separator: ",")

        if UserDefaults.standard.bool(forKey: Self.kDryRunMode) {
            aslog("  verdict=RESTART(\(list)) — DRY RUN, not terminating")
            return
        }

        // Persist for post-restart cooldown decisioning on next launch.
        let defaults = UserDefaults.standard
        defaults.set(list, forKey: Self.kLastRestartReason)
        defaults.set(Date(), forKey: Self.kLastRestartTime)

        aslog("  verdict=RESTART(\(list))")
        aslog("Terminating for restart.")
        NSApp.terminate(nil)
    }
}
