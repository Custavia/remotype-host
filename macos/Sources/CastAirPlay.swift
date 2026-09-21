import AppKit
import ApplicationServices
import CoreGraphics

/// The NATIVE AirPlay mechanics (CASTING.md §9.2): AX-scripts Control Center →
/// Screen Mirroring → <target>, watches for the AirPlay passcode dialog, and
/// detects mirror start/stop via display topology. This is greenfield AX
/// scripting, so every step is defensive — bounded polls with per-step
/// timeouts, and ANY failure reports back so the session can fall to the
/// guided path. On failure the UI is deliberately left open: the guided
/// sheet's step 1 is "Open Control Center — we did this for you".
final class CastAirPlay {
    /// The passcode dialog appeared (stage → pin_required).
    var onPinRequired: (() -> Void)?
    /// The scripted trigger gave up (→ nomirror / guided; watchers stay armed).
    var onTriggerFailed: (() -> Void)?
    /// The target row was pressed (stage → connecting).
    var onPicked: (() -> Void)?
    /// Display topology crossed into (true) / out of (false) a mirror set.
    var onMirrorChange: ((Bool) -> Void)?

    private var stepTimer: DispatchSourceTimer?
    private var pinTimer: DispatchSourceTimer?
    private var topoTimer: DispatchSourceTimer?
    private var pinField: AXUIElement?
    private var pinReported = false
    private var lastMirror = false

    /// Processes that can own the AirPlay passcode dialog.
    private static let pinBundles = ["com.apple.controlcenter", "com.apple.AirPlayUIAgent",
                                     "com.apple.coreautha", "com.apple.CoreAuthUI"]

    init() {
        lastMirror = mirrorActiveNow
        CGDisplayRegisterReconfigurationCallback(castDisplayReconfigCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(castDisplayReconfigCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Trigger

    func startTrigger(targetName: String) {
        cancelTrigger()
        startPinWatcher()
        startTopologyWatcher()
        step(timeout: 3, code: "cc", find: { [weak self] in self?.controlCenterExtra() },
             onFail: { [weak self] in self?.triggerFailed("cc") }) { [weak self] extra in
            guard let self else { return }
            self.press(extra)
            self.step(timeout: 5, code: "mirroring", find: { [weak self] in self?.mirroringToggle() },
                      onFail: { [weak self] in self?.triggerFailed("mirroring") }) { [weak self] toggle in
                guard let self else { return }
                self.press(toggle)
                self.step(timeout: 8, code: "target",
                          find: { [weak self] in self?.deviceRow(named: targetName) },
                          onFail: { [weak self] in self?.triggerFailed("target") }) { [weak self] row in
                    guard let self else { return }
                    self.press(row)
                    self.onPicked?()
                }
            }
        }
    }

    /// Stop the scripted sequence (leaves whatever UI is open). The PIN and
    /// topology watchers are NOT touched — a manual completion during the
    /// guided window must still be detected.
    func cancelTrigger() {
        stepTimer?.cancel()
        stepTimer = nil
    }

    /// Stop everything (session teardown).
    func stopWatchers() {
        cancelTrigger()
        pinTimer?.cancel()
        pinTimer = nil
        topoTimer?.cancel()
        topoTimer = nil
        pinField = nil
        pinReported = false
    }

    private func triggerFailed(_ code: String) {
        HostLog.write("cast trigger fail \(code)")   // step code only, never a sink name
        onTriggerFailed?()
    }

    /// Scripted mirror-off on cast.stop — same AX path; the toggled row ends
    /// the mirror. Failure is logged (code only) and otherwise ignored: the
    /// session already reported stopped.
    func teardownMirror(targetName: String) {
        let logFail: (String) -> Void = { HostLog.write("cast teardown fail \($0)") }
        step(timeout: 3, code: "td-cc", find: { [weak self] in self?.controlCenterExtra() },
             onFail: { logFail("cc") }) { [weak self] extra in
            guard let self else { return }
            self.press(extra)
            self.step(timeout: 5, code: "td-mirroring", find: { [weak self] in self?.mirroringToggle() },
                      onFail: { logFail("mirroring") }) { [weak self] toggle in
                guard let self else { return }
                self.press(toggle)
                self.step(timeout: 6, code: "td-target",
                          find: { [weak self] in self?.deviceRow(named: targetName) },
                          onFail: { logFail("target") }) { [weak self] row in
                    self?.press(row)
                }
            }
        }
    }

    /// One defensive scripting step: poll `find` every 0.3 s until it yields
    /// an element (→ `then`) or `timeout` elapses (→ `onFail`).
    private func step(timeout: TimeInterval, code: String,
                      find: @escaping () -> AXUIElement?,
                      onFail: @escaping () -> Void,
                      then: @escaping (AXUIElement) -> Void) {
        stepTimer?.cancel()
        let deadline = Date().addingTimeInterval(timeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let el = find() {
                self.stepTimer?.cancel()
                self.stepTimer = nil
                then(el)
            } else if Date() >= deadline {
                self.stepTimer?.cancel()
                self.stepTimer = nil
                onFail()
            }
        }
        timer.resume()
        stepTimer = timer
    }

    // MARK: PIN dialog

    private func startPinWatcher() {
        pinReported = false
        pinField = nil
        pinTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.scanForPinField() }
        timer.resume()
        pinTimer = timer
    }

    /// Stop just the PIN watcher — a passcode dialog can only appear during the
    /// launching/connecting trigger window, never in steady-state CASTING. Called
    /// on mirror-up so the 0.5 s cross-process AX scan doesn't run for the whole
    /// session; the topology watcher stays armed to catch an external mirror-stop,
    /// and a fresh start() re-arms via startTrigger()→startPinWatcher().
    func stopPinWatcher() {
        pinTimer?.cancel()
        pinTimer = nil
        pinField = nil
        pinReported = false
    }

    var pinFieldPresent: Bool { pinField != nil }

    private func scanForPinField() {
        for bundle in Self.pinBundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                for window in windows(of: ax) {
                    if let field = findFirst(in: window, depth: 8, where: { [weak self] el in
                        self?.str(el, kAXSubroleAttribute) == "AXSecureTextField"
                    }) {
                        pinField = field
                        if !pinReported {
                            pinReported = true
                            HostLog.write("cast pin dialog")
                            onPinRequired?()
                        }
                        return
                    }
                }
            }
        }
        // Dialog gone. Re-arm reporting: a wrong code re-shows the dialog and
        // must re-surface pin_required on the phone.
        if pinField != nil {
            pinField = nil
            pinReported = false
        }
    }

    /// Put keyboard focus on the passcode field so injected digits land in it.
    func focusPinField() {
        guard let field = pinField else { return }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: Display topology (success / external-stop detection)

    private func startTopologyWatcher() {
        lastMirror = mirrorActiveNow
        topoTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkTopology() }
        timer.resume()
        topoTimer = timer
    }

    /// True while any online display mirrors another (the AirPlay display
    /// joins a mirror set with the built-in one when the OS mirror starts).
    var mirrorActiveNow: Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        for i in 0..<Int(count) where CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay {
            return true
        }
        return false
    }

    fileprivate func checkTopology() {
        let active = mirrorActiveNow
        guard active != lastMirror else { return }
        lastMirror = active
        HostLog.write("cast mirror \(active ? "up" : "down")")
        onMirrorChange?(active)
    }

    // MARK: AX helpers

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func findFirst(in root: AXUIElement, depth: Int,
                           where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(root) { return root }
        guard depth > 0 else { return nil }
        for child in children(root) {
            if let hit = findFirst(in: child, depth: depth - 1, where: match) { return hit }
        }
        return nil
    }

    private func supportsPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(kAXPressAction)
    }

    /// The matched element or its nearest pressable ancestor.
    private func actionable(_ el: AXUIElement) -> AXUIElement? {
        var current = el
        for _ in 0..<4 {
            if supportsPress(current) { return current }
            guard let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func press(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    private func norm(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func ccApp() -> AXUIElement? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func controlCenterExtra() -> AXUIElement? {
        guard let app = ccApp() else { return nil }
        let hit = findFirst(in: app, depth: 3) { [weak self] el in
            guard let self, self.str(el, kAXRoleAttribute) == "AXMenuBarItem" else { return false }
            if self.str(el, "AXIdentifier")?.hasSuffix("controlcenter") == true { return true }
            return self.norm(self.str(el, kAXDescriptionAttribute)) == "control center"
        }
        return hit.flatMap { actionable($0) }
    }

    private func mirroringToggle() -> AXUIElement? {
        guard let app = ccApp() else { return nil }
        for window in windows(of: app) {
            if let hit = findFirst(in: window, depth: 8, where: { [weak self] el in
                guard let self else { return false }
                if self.str(el, "AXIdentifier")?.lowercased().contains("mirror") == true { return true }
                return [self.str(el, kAXTitleAttribute), self.str(el, kAXDescriptionAttribute)]
                    .contains { self.norm($0).contains("screen mirroring") }
            }) {
                return actionable(hit)
            }
        }
        return nil
    }

    private func deviceRow(named name: String) -> AXUIElement? {
        guard let app = ccApp() else { return nil }
        let want = norm(name)
        guard !want.isEmpty else { return nil }
        for window in windows(of: app) {
            if let hit = findFirst(in: window, depth: 10, where: { [weak self] el in
                guard let self else { return false }
                guard let role = self.str(el, kAXRoleAttribute),
                      ["AXCheckBox", "AXButton", "AXCell", "AXRow"].contains(role) else { return false }
                let title = self.norm(self.str(el, kAXTitleAttribute))
                let desc = self.norm(self.str(el, kAXDescriptionAttribute))
                if title == want || desc == want { return true }
                return want.count >= 3 && (title.contains(want) || desc.contains(want))
            }) {
                return actionable(hit)
            }
        }
        return nil
    }
}

/// C-convention trampoline for CGDisplayRegisterReconfigurationCallback.
private func castDisplayReconfigCallback(_ display: CGDirectDisplayID,
                                         _ flags: CGDisplayChangeSummaryFlags,
                                         _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let airplay = Unmanaged<CastAirPlay>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { airplay.checkTopology() }
}
