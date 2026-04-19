import AppKit
import CoreGraphics

/// Mechanisms that can fire a reconfiguration event.
enum ReconfigurationSource: String {
    case didChangeScreenParameters = "NSApp.didChangeScreenParametersNotification"
    case didWake                   = "NSWorkspace.didWakeNotification"
    case cgDisplayReconfig         = "CGDisplayRegisterReconfigurationCallback"
    case activeSpaceDidChange      = "NSWorkspace.activeSpaceDidChangeNotification"
    case poll                      = "Poll (5s)"
}

/// A single observed reconfiguration event — the coalesced set of sources that
/// fired within the burst window, plus before/after fingerprints.
struct ReconfigurationEvent {
    let date: Date
    let sources: [ReconfigurationSource]
    let before: ActiveSpaceFingerprint
    let after: ActiveSpaceFingerprint

    var changed: Bool { before != after }
}

/// Subscribes to five drift-detection mechanisms and forwards coalesced events
/// to `onEvent`. Bursts within 200ms are merged into one ReconfigurationEvent
/// whose `sources` array lists every mechanism that fired. Ported from
/// DisplayProbe.EventDetector with the 5th source (activeSpaceDidChange) added.
@MainActor
final class ReconfigurationObserver {

    private var lastFingerprint: ActiveSpaceFingerprint
    private let onEvent: (ReconfigurationEvent) -> Void

    private var pendingSources: [ReconfigurationSource] = []
    private var burstWorkItem: DispatchWorkItem?
    private let burstWindow: TimeInterval = 0.2

    private var pollTimer: DispatchSourceTimer?
    private var cgCallbackInstalled = false

    init(onEvent: @escaping (ReconfigurationEvent) -> Void) {
        self.lastFingerprint = ActiveSpaceFingerprint.current()
        self.onEvent = onEvent
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        installCGCallback()
        startPollTimer()

        ActiveSpaceLogger.log("Started. Initial fingerprint: \(lastFingerprint)")
    }

    /// Current fingerprint used as the diff baseline. Exposed so RestartCoordinator
    /// can evaluate absolute triggers (e.g. dock-on-virtual) without waiting for
    /// the first notification-driven event.
    var currentFingerprint: ActiveSpaceFingerprint { lastFingerprint }

    // MARK: - Notification callbacks

    @objc private func screenParamsChanged() { record(.didChangeScreenParameters) }
    @objc private func didWake()             { record(.didWake) }
    @objc private func activeSpaceChanged()  { record(.activeSpaceDidChange) }

    // MARK: - CG low-level callback

    private static let callback: CGDisplayReconfigurationCallBack = { _, _, ctx in
        guard let ctx = ctx else { return }
        let observer = Unmanaged<ReconfigurationObserver>.fromOpaque(ctx).takeUnretainedValue()
        DispatchQueue.main.async {
            observer.record(.cgDisplayReconfig)
        }
    }

    private func installCGCallback() {
        guard !cgCallbackInstalled else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(Self.callback, ctx)
        cgCallbackInstalled = true
    }

    // MARK: - Poll

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.pollTick()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollTick() {
        let now = ActiveSpaceFingerprint.current()
        if now != lastFingerprint {
            record(.poll)
        }
    }

    // MARK: - Event coalescing

    private func record(_ source: ReconfigurationSource) {
        pendingSources.append(source)
        burstWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushBurst()
        }
        burstWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + burstWindow, execute: work)
    }

    private func flushBurst() {
        let sources = Array(Set(pendingSources)).sorted { $0.rawValue < $1.rawValue }
        pendingSources.removeAll()
        burstWorkItem = nil

        let now = ActiveSpaceFingerprint.current()
        let event = ReconfigurationEvent(date: Date(), sources: sources, before: lastFingerprint, after: now)
        lastFingerprint = now

        ActiveSpaceLogger.log("EVENT sources=[\(sources.map { $0.rawValue }.joined(separator: ", "))] changed=\(event.changed)")
        if event.changed {
            ActiveSpaceLogger.log("  before: \(event.before)")
            ActiveSpaceLogger.log("  after:  \(event.after)")
        }

        onEvent(event)
    }
}
