import Foundation
import SwiftUI

/// The live pairing code, and the rules that keep a 60-bit secret a secret.
///
/// One code at a time, one ceremony at a time, ten-minute window, three attempts
/// then it burns. The three-attempt rule is safe *only* because the code is 60
/// bits — a guess is 3/2^60. Shortening the code would not be a UX improvement;
/// it would silently invalidate this rule and reintroduce the offline dictionary
/// attack the design review rejected. See `docs/RT1.md` §2.1.
@MainActor
final class PairingCode: ObservableObject {
    static let shared = PairingCode()

    @Published private(set) var code: String?
    @Published private(set) var expiresAt: Date?
    /// Set when a ceremony completes, so the panel can say who paired.
    @Published private(set) var lastPaired: String?
    /// Replaces the code on screen when the ceremony ended without a pairing —
    /// the phone cancelled, or dropped — so the window says what happened
    /// instead of showing a code that is no longer valid.
    @Published private(set) var status: String?
    /// The phone whose RT1 session is OPEN, which is the only state that
    /// honestly means "connected". Pairing succeeding is a moment earlier and
    /// is not the same thing: the ceremony can finish and the session that
    /// follows on the same socket can still fail.
    @Published private(set) var connected: String?

    func noteConnected(_ name: String) { connected = name }
    func noteDisconnected() { connected = nil }

    private var attempts = 0
    private var timer: Timer?

    private static let window: TimeInterval = 600      // 10 minutes
    private static let maxAttempts = 3

    /// The code the handshake should use, or nil when none is live. Reading it
    /// does not consume it — `burn()` does.
    var live: String? { Self.box.live() }

    /// A nonisolated, lock-guarded mirror of the live code.
    ///
    /// The handshake reads this from the **network queue**, in the middle of
    /// answering `pair.begin`. Hopping to the main actor for it would make the
    /// read asynchronous, and the reply would have to be sent from a completion
    /// block — which is exactly how a handshake ends up racing a second
    /// `pair.begin` from a retrying phone. A lock and a snapshot keep the whole
    /// ceremony on one queue.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var code: String?
        private var expiresAt: Date?

        func set(code: String?, expiresAt: Date?) {
            lock.lock(); defer { lock.unlock() }
            self.code = code; self.expiresAt = expiresAt
        }

        func live() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let code, let expiresAt, Date() < expiresAt else { return nil }
            return code
        }
    }

    nonisolated static let box = Box()

    /// What `Server` calls. Nonisolated on purpose — see `Box`.
    nonisolated static var live: String? { box.live() }

    /// Mint a code for a `pair.begin` that arrived with none showing, and return
    /// it — synchronously, from the network queue, so the `pair.hi` reply can
    /// carry a real code on the FIRST tap. Only the lock-guarded Box and the
    /// test-hook file are touched here; the on-screen panel, the @Published
    /// mirror and the expiry timer are all main-actor state and are brought into
    /// line by `adoptMinted()`, hopped to `main` right after. Calling
    /// `MainActor`-isolated `show()` from this queue is what regressed pairing —
    /// the receive runs OFF the main actor (see `Box`), so `assumeIsolated`
    /// there traps.
    nonisolated static func mintForHandshake() -> String {
        let fresh = RT1.generateCode()
        box.set(code: fresh, expiresAt: Date().addingTimeInterval(window))
        HostLog.write("RT1: pairing code shown (minted on pair.begin), valid for 10 minutes")
        writeTestCode(fresh)
        return fresh
    }

    /// Pull the just-minted code out of the Box and into the main-actor state the
    /// panel draws from, and arm the expiry timer. Idempotent: if the Box code
    /// has already been adopted (same value), it does nothing.
    func adoptMinted() {
        guard let live = Self.box.live(), live != code else { return }
        code = live
        expiresAt = Date().addingTimeInterval(Self.window)
        attempts = 0
        lastPaired = nil
        status = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.window, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }

    func show() {
        let fresh = RT1.generateCode()
        code = fresh
        expiresAt = Date().addingTimeInterval(Self.window)
        attempts = 0
        lastPaired = nil
        status = nil
        Self.box.set(code: code, expiresAt: expiresAt)
        HostLog.write("RT1: pairing code shown, valid for 10 minutes")
        Self.writeTestCode(fresh)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.window, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }

    /// A failed attempt. Three of them burn the code — the user has to ask for a
    /// new one, which is cheap for them and fatal for a guessing attacker.
    func noteFailure() {
        attempts += 1
        HostLog.write("RT1: pairing attempt failed (\(attempts)/\(Self.maxAttempts))")
        if attempts >= Self.maxAttempts { burn(reason: "too many failed attempts") }
    }

    func noteSuccess(deviceName: String) {
        lastPaired = deviceName
        status = nil
        burn(reason: "paired with \(deviceName)")
    }

    func burn(reason: String) {
        guard code != nil else { return }
        code = nil
        expiresAt = nil
        Self.box.set(code: nil, expiresAt: nil)
        attempts = 0
        timer?.invalidate(); timer = nil
        HostLog.write("RT1: pairing code retired — \(reason)")
    }

    private func expire() { burn(reason: "expired") }

    /// The PHONE ended the ceremony — Cancel tapped (pair.cancel), or the
    /// connection that began pairing dropped first. Retire the code and show
    /// [message] in its place: a code nobody is typing must not stay on screen
    /// looking valid.
    func endedByPhone(message: String, reason: String) {
        burn(reason: reason)
        status = message
    }

    /// TEST HOOK. When `REMOTYPE_RT1_TEST_CODE_FILE` names a path, the live code
    /// is written there as well as shown.
    ///
    /// This exists so the happy path of the ceremony can be driven by
    /// `spec/rt1/interop_host.py` against a RELEASE build — which is the only
    /// build where a signing or entitlement difference would show up. It is
    /// deliberately NOT `#if DEBUG` for that reason, and deliberately not a
    /// preference or a menu item: it takes an environment variable set before
    /// launch, so nothing a running app can be talked into doing turns it on.
    /// Anyone able to set this process's environment and read the file it names
    /// can already read `identity.bin` next to it.
    /// Reflect the code the host would verify against into the test-hook file,
    /// on EVERY pair.begin that ends in pair.hi — not only when a code is freshly
    /// minted. A begin that reuses an already-live code otherwise left the hook
    /// file stale (or empty, if a test had cleared it), and a black-box test
    /// could not read the code it now has to type. No-op unless the launch-time
    /// env var names a file, so it is inert in every shipped run.
    nonisolated static func writeTestHook(_ code: String) { writeTestCode(code) }

    nonisolated private static func writeTestCode(_ code: String) {
        guard let path = ProcessInfo.processInfo.environment["REMOTYPE_RT1_TEST_CODE_FILE"],
              !path.isEmpty else { return }
        HostLog.write("RT1: TEST HOOK ACTIVE — writing the pairing code to \(path)")
        try? Data(code.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Seconds left, for the panel's countdown.
    var secondsRemaining: Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSinceNow))
    }
}
