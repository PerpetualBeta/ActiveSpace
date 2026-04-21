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
/// the drift criteria, and logs what it sees. Purely diagnostic — does
/// not terminate the app.
///
/// An earlier design called for self-restart on drift via a launchd
/// keep-alive agent. Two days of dry-run dogfooding across display
/// plug/unplug, sleep/wake, space add/remove/reorder and screensaver
/// cycles produced seven restart-worthy classifications and zero
/// user-visible problems. ActiveSpace's in-memory state doesn't
/// actually become unrecoverably stale under drift: SpaceObserver
/// re-queries CGS from scratch on every refresh, VirtualDisplay's
/// reconcile + enforceVirtualPosition + cursor fence handle the
/// display-layer concerns, and the menu bar icon re-renders via
/// @Published bindings on each refresh. The restart was a sledgehammer
/// for a problem the finer-grained mitigations already solve.
///
/// This monitor is kept for its diagnostic value — future edge cases
/// will show up here first, and the launchd keep-alive agent
/// registered by AppDelegate still provides crash-resilience respawn
/// even though drift-observed events no longer terminate.
@MainActor
final class DriftMonitor {

    private let relativeTriggerGrace: TimeInterval = 5.0

    private let launchDate: Date
    private let observer: ReconfigurationObserver

    init(observer: ReconfigurationObserver) {
        self.observer = observer
        self.launchDate = Date()
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
            ActiveSpaceLogger.log("  (startup grace — ignored, relative triggers: \(triggers.map(\.rawValue).joined(separator: ",")))")
            triggers.removeAll()
        }

        evaluateAbsoluteTriggers(on: event.after, appending: &triggers)

        guard !triggers.isEmpty else { return }
        logDrift(triggers)
    }

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint) {
        var triggers: [DriftTrigger] = []
        evaluateAbsoluteTriggers(on: fingerprint, appending: &triggers)
        guard !triggers.isEmpty else { return }
        logDrift(triggers)
    }

    private func evaluateAbsoluteTriggers(on fingerprint: ActiveSpaceFingerprint, appending triggers: inout [DriftTrigger]) {
        if fingerprint.mainIsSmall {
            triggers.append(.dockOnVirtual)
        }
    }

    private func logDrift(_ triggers: [DriftTrigger]) {
        let list = triggers.map(\.rawValue).sorted().joined(separator: ",")
        ActiveSpaceLogger.log("  drift-observed(\(list))")
    }
}
