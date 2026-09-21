import AppKit
import SwiftUI

/// The guided permission flow — one screen per grant, and it moves on by itself.
///
/// The old first run was a LIST: two rows, two "Allow…" buttons, and a sentence
/// admitting that macOS might ask you to quit and reopen. Everything on it was
/// true, and people still got stuck, because a list asks the user to hold the
/// whole procedure in their head: which one am I on, did that one work, is the
/// switch I just flipped the right switch, why is it still grey.
///
/// A wizard answers all four. One thing at a time, a picture of the exact switch
/// to flip, and — the part that actually matters — **it watches**. Both grants
/// are readable live (`CGPreflightPostEventAccess`, `CGPreflightScreenCaptureAccess`),
/// so the step turns green the instant the real toggle moves and advances on its
/// own. Nobody has to come back and press Recheck.
///
/// The illustration is DRAWN, not a screen recording of System Settings. A
/// recording would be wrong for every non-English user (their Settings is in
/// their language, ours would not be), wrong in the other appearance, and stale
/// the next time Apple moves that pane — which is every year or two. A drawing
/// costs nothing to keep true.
@MainActor
enum PermissionWizard {
    private static var window: NSWindow?

    /// Set right before a wizard-initiated relaunch; read (and cleared) at the
    /// next launch, which re-presents the wizard so the flow lands where it
    /// left off. Without it, "Restart and finish" restarts and finishes nothing
    /// — the new process comes up bare and the user is left hunting the menu
    /// bar for the thing that was mid-sentence a second ago.
    static let resumeAfterRelaunchKey = "remotype.resumeWizardAfterRelaunch"

    static func relaunchAndResume(server: Server) {
        UserDefaults.standard.set(true, forKey: resumeAfterRelaunchKey)
        server.relaunch()
    }

    static func present(server: Server) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 712),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Set up Remotype Host"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: PermissionWizardView(server: server))
        window = w
        DockPresence.enterWindowMode()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
        DockPresence.leaveWindowModeIfIdle()
    }
}

// MARK: - The steps

/// One grant. `isGranted` is read on a timer while its step is showing, which is
/// what lets the wizard advance without being told.
struct PermissionStep: Identifiable {
    let id: String
    let title: String
    /// One line, in the user's terms, about what this buys them.
    let why: String
    /// The fuller, layman explanation — what macOS calls it, what we use it for,
    /// and what it does NOT touch. Shown right under `why` in the step.
    let detail: String
    /// What the pane is called in System Settings, so the words on our screen
    /// match the words on theirs.
    let paneName: String
    /// The last segment of `paneName` — what the mock window's title bar says.
    var paneTitle: String {
        paneName.components(separatedBy: "▸").last?
            .trimmingCharacters(in: .whitespaces) ?? paneName
    }
    /// Optional steps can be skipped; the wizard still says they are unfinished.
    let required: Bool
    /// What the status line says when the grant is in but only a restart makes
    /// this process able to use it.
    let restartLine: String
    /// The TCC truth — refreshed through the fresh-process probe, so it turns
    /// true the moment the user flips the switch even though this process's own
    /// view is cached. This is what the wizard's green state keys off.
    let isGranted: (Server) -> Bool
    /// What THIS process can do right now. granted && !live means one thing:
    /// allowed, restart to apply.
    let isLive: (Server) -> Bool
    let request: (Server) -> Void

    static let all: [PermissionStep] = [
        PermissionStep(
            id: "accessibility",
            title: "Accessibility",
            why: "Lets your phone type and move the pointer on this Mac. Without it, nothing your phone sends can reach the screen.",
            detail: HostTrust.accessibilityDetail,
            paneName: "Privacy & Security ▸ Accessibility",
            required: true,
            restartLine: "Allowed. One restart and your phone can type.",
            isGranted: { $0.accessibilityGranted },
            isLive: { $0.accessibilityTrusted },
            request: { $0.requestAccessibility() }),
        PermissionStep(
            id: "screen",
            title: "Screen Recording",
            why: "Only for seeing this Mac’s screen on your phone, and hearing its sound. Skip it if you just want a keyboard and trackpad.",
            detail: HostTrust.screenRecordingDetail,
            paneName: "Privacy & Security ▸ Screen & System Audio Recording",
            required: false,
            restartLine: "Allowed. One restart and the screen will come through.",
            isGranted: { $0.screenGranted },
            isLive: { $0.screenRecordingTrusted },
            request: { $0.requestScreenRecording() }),
    ]
}

// MARK: - The view

struct PermissionWizardView: View {
    @ObservedObject var server: Server

    /// Seeded in `init`, not in `onAppear`: `ImageRenderer` never runs the
    /// appear lifecycle, so a snapshot of "step 2" quietly rendered step 1.
    @State private var index: Int
    @State private var skipped: Set<String> = []

    private let steps = PermissionStep.all
    private let watch = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    /// Opens on the first grant that is still missing — or straight on the
    /// summary when nothing is. Someone reopening this to check on a machine
    /// that is already set up should see the answer, not be walked through two
    /// screens that are already green.
    ///
    /// `startAt` overrides that, and is the snapshot/testing seam.
    init(server: Server, startAt: Int? = nil) {
        self.server = server
        let steps = PermissionStep.all
        let first = steps.firstIndex { !$0.isGranted(server) } ?? steps.count
        _index = State(initialValue: startAt ?? first)
    }

    private var step: PermissionStep { steps[min(index, steps.count - 1)] }
    private var isDone: Bool { index >= steps.count }
    /// Every REQUIRED grant is in. The optional ones do not gate this.
    private var readyToUse: Bool {
        steps.filter(\.required).allSatisfy { $0.isGranted(server) }
    }
    /// Something is allowed that this process cannot use yet — the summary must
    /// end in a restart, not a Done that dismisses a half-applied setup.
    private var restartPending: Bool {
        steps.contains { $0.isGranted(server) && !$0.isLive(server) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(HostDeck.hairline)
            if isDone { summary } else { stepBody }
        }
        .frame(width: 560)
        .background(HostFlowBackground())
        .onReceive(watch) { _ in tick() }
        .onAppear { tick() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            HostBrandMark(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                // Never claim "set up" while something required is missing.
                // A summary that congratulates you on a Mac that cannot type is
                // the same lie the old checklist told, in a nicer font.
                Text(isDone ? (readyToUse && !restartPending ? "You’re set up" : "Almost there")
                            : "Set up Remotype Host")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HostDeck.legend)
                Text(isDone
                     ? (readyToUse
                        ? (restartPending
                           ? "Everything is allowed — one restart makes it live."
                           : "Your phone can talk to this Mac.")
                        : "One permission is still missing — your phone can connect, but it cannot type yet.")
                     : "Step \(index + 1) of \(steps.count) — \(step.title)")
                    .font(.system(size: 13))
                    .foregroundStyle(HostDeck.sublegend)
            }
            Spacer(minLength: 0)
            progressDots
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                Circle()
                    .fill(dotColor(for: i, step: s))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private func dotColor(for i: Int, step s: PermissionStep) -> Color {
        if s.isGranted(server) { return HostDeck.statusGreen }
        if skipped.contains(s.id) { return HostDeck.sublegend.opacity(0.5) }
        return i == index ? HostDeck.accent : HostDeck.hairline
    }

    // MARK: a step

    private var stepBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsToggleIllustration(appName: "Remotype Host",
                                       paneTitle: step.paneTitle,
                                       granted: step.isGranted(server))
                .frame(height: 188)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(step.why)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(HostDeck.legend)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(HostDeck.sublegend)
                    .fixedSize(horizontal: false, vertical: true)

                Text(HostTrust.revokeNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(HostDeck.sublegend.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                Label(step.paneName, systemImage: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(HostDeck.sublegend)
            }

            Spacer(minLength: 8)

            statusStrip

            LANFootnote()

            HStack(spacing: 10) {
                if step.isGranted(server) {
                    Button(advanceTitle) { advance() }
                        .buttonStyle(HostPrimaryButton())
                        .frame(width: 200)
                } else {
                    Button("Open System Settings") { step.request(server) }
                        .buttonStyle(HostPrimaryButton())
                        .frame(width: 200)
                }
                if !step.required && !step.isGranted(server) {
                    Button("Skip for now") {
                        skipped.insert(step.id)
                        advance()
                    }
                    .buttonStyle(HostSecondaryButton())
                }
                Spacer(minLength: 0)
                Button("Close") { PermissionWizard.close() }
                    .buttonStyle(HostSecondaryButton())
            }

            // The "I already turned it on but this still says waiting" recovery.
            // The probe should make this unnecessary; it stays as the escape
            // hatch for the failure we haven't met yet, and it resumes the
            // wizard on the other side.
            if !step.isGranted(server) {
                Button("Turned it on already? Restart to apply") {
                    PermissionWizard.relaunchAndResume(server: server)
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(HostDeck.accent)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 26)
        .frame(height: 612, alignment: .top)
    }

    /// The live line. It is the difference between a wizard and a checklist:
    /// while the user is in System Settings this says we are watching, and it
    /// changes by itself the moment the switch moves.
    private var statusStrip: some View {
        HStack(spacing: 10) {
            if step.isGranted(server) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(HostDeck.statusGreen)
                Text(relaunchNeeded ? step.restartLine : "Allowed — nothing else to do here.")
                    .foregroundStyle(HostDeck.legend)
            } else {
                WatchingDot()
                Text("Waiting for the switch — this turns green on its own.")
                    .foregroundStyle(HostDeck.sublegend)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(HostDeck.well))
    }

    /// TCC grants apply to a PROCESS at launch. When the probe says allowed but
    /// this process still can't do the thing, the one remedy is a restart — and
    /// we own it, rather than shipping the user a host that looks healthy and
    /// types nothing. No "did we watch it flip" heuristic: a grant that predates
    /// this window (a reinstall over a live grant, a toggle made while the app
    /// was closed mid-wizard) needs the restart just the same.
    private var relaunchNeeded: Bool {
        step.isGranted(server) && !step.isLive(server)
    }

    private var advanceTitle: String {
        if relaunchNeeded { return "Restart and finish" }
        return index == steps.count - 1 ? "Finish" : "Next"
    }

    // MARK: done

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(steps) { s in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: s.isGranted(server) ? "checkmark.seal.fill" : "circle.dashed")
                        .font(.system(size: 16))
                        .foregroundStyle(s.isGranted(server) ? HostDeck.statusGreen : HostDeck.statusAmber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(HostDeck.legend)
                        Text(summaryLine(for: s))
                            .font(.system(size: 13))
                            .foregroundStyle(HostDeck.sublegend)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !s.isGranted(server) {
                        Button("Set up") {
                            skipped.remove(s.id)
                            index = steps.firstIndex(where: { $0.id == s.id }) ?? 0
                        }
                        .buttonStyle(HostSecondaryButton())
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HostDeck.accent)
                Text("Remotype Host lives in the menu bar, at the top-right of your screen. Open it any time for status, pairing, and settings.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(HostDeck.legend)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HostDeck.well))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if restartPending {
                    Button("Restart and finish") {
                        PermissionWizard.relaunchAndResume(server: server)
                    }
                    .buttonStyle(HostPrimaryButton())
                    .frame(width: 200)
                } else {
                    Button("Done") { PermissionWizard.close() }
                        .buttonStyle(HostPrimaryButton())
                        .frame(width: 160)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 26)
        .frame(height: 612, alignment: .top)
    }

    private func summaryLine(for s: PermissionStep) -> String {
        if s.isGranted(server) {
            return s.isLive(server) ? "Allowed." : "Allowed — takes effect after the restart."
        }
        if s.required { return "Not allowed yet — your phone cannot type until it is." }
        if skipped.contains(s.id) { return "Skipped. Screen and sound stay off until you allow it." }
        return "Not allowed — screen and sound stay off until you do."
    }

    // MARK: driving it

    /// Re-read the real grants. The in-process reads are cheap but can be stale
    /// forever on a fresh grant (they cache at first ask), so while anything on
    /// screen still reads as missing or not-yet-live, the fresh-process probe
    /// runs too — it is what actually turns a step green under the user's
    /// finger. Runs on the summary as well: its rows and the restart button are
    /// live state, not a snapshot.
    private func tick() {
        server.refreshAccessibility()
        server.refreshScreenRecording()
        if steps.contains(where: { !$0.isGranted(server) || !$0.isLive(server) }) {
            server.refreshFreshGrants()
        }
        guard !isDone else { return }
        // Advance on its own ONLY when there is nothing left for the user to do
        // here: granted AND already usable in this process. When only a restart
        // remains the wizard stays put — sailing past the one instruction that
        // matters is how hosts end up looking healthy and typing nothing.
        if step.isGranted(server), step.isLive(server) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if !isDone, steps[index].id == step.id,
                   step.isGranted(server), step.isLive(server) { advance() }
            }
        }
    }

    private func advance() {
        if relaunchNeeded {
            PermissionWizard.relaunchAndResume(server: server)
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { index += 1 }
    }
}

// MARK: - The illustration

/// A drawn System Settings row with a switch that turns itself on, once every
/// few seconds, with a pointer arriving to do it.
///
/// Deliberately a STYLISED mock, not a facsimile: the other rows are blank bars,
/// there is no attempt to match Apple's exact metrics, and the only real name on
/// it is ours. It has to say "find the row with our name and flip its switch" —
/// it does not have to pass for a screenshot, and trying to would make it wrong
/// the moment that pane is redesigned.
struct SettingsToggleIllustration: View {
    let appName: String
    /// The pane being mimed. It MUST track the step — a drawing that says
    /// "Accessibility" while the button below sends you to Screen Recording is
    /// worse than no drawing at all.
    var paneTitle: String = "Accessibility"
    /// Once the real grant is in, the drawing stops moving and shows the end
    /// state. A loop that keeps miming the action after it is done reads as
    /// "still waiting for you".
    var granted: Bool

    @State private var on = false
    @State private var pointerAtSwitch = false
    @State private var cardOpacity: Double = 1

    private let cycle = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HostDeck.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HostDeck.hairline, lineWidth: 1))

            VStack(spacing: 0) {
                windowChrome
                VStack(spacing: 10) {
                    placeholderRow
                    ourRow
                    placeholderRow
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .opacity(cardOpacity)
        }
        .padding(.horizontal, 40)
        .onAppear { restart() }
        .onReceive(cycle) { _ in if !granted { runOnce() } }
        .onChange(of: granted) { _ in restart() }
    }

    private var windowChrome: some View {
        HStack(spacing: 6) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                     Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.24, green: 0.78, blue: 0.29)], id: \.self) { c in
                Circle().fill(c).frame(width: 8, height: 8)
            }
            Text(paneTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HostDeck.sublegend)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: 34, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HostDeck.capTop)
    }

    /// Another app, unnamed. Naming real software here would be both wrong on
    /// most Macs and rude on the rest.
    private var placeholderRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(HostDeck.hairline)
                .frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 3).fill(HostDeck.hairline)
                .frame(width: 78, height: 8)
            Spacer(minLength: 0)
            switchShape(on: false, dim: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(HostDeck.well.opacity(0.6)))
    }

    private var ourRow: some View {
        HStack(spacing: 10) {
            HostBrandMark(size: 20)
            Text(appName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HostDeck.legend)
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                switchShape(on: granted || on, dim: false)
                if !granted {
                    pointer
                        .offset(x: pointerAtSwitch ? 2 : -78, y: pointerAtSwitch ? 11 : 24)
                        .opacity(pointerAtSwitch ? 1 : 0.5)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(HostDeck.accent.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(HostDeck.accent.opacity(0.45), lineWidth: 1))
        )
    }

    private func switchShape(on: Bool, dim: Bool) -> some View {
        Capsule()
            .fill(on ? HostDeck.statusGreen : HostDeck.hairline)
            .frame(width: 34, height: 20)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .frame(maxWidth: .infinity, alignment: on ? .trailing : .leading)
            )
            .opacity(dim ? 0.45 : 1)
    }

    private var pointer: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    private func restart() {
        on = granted
        pointerAtSwitch = false
        cardOpacity = 1
        if !granted { runOnce() }
    }

    /// One pass: the pointer travels, the switch flips, the card settles, then
    /// fades out and resets — a fade rather than flipping the switch back, which
    /// would read as "and then turn it off again".
    private func runOnce() {
        pointerAtSwitch = false
        on = false
        cardOpacity = 1
        withAnimation(.easeInOut(duration: 0.85)) { pointerAtSwitch = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) { on = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.45)) { cardOpacity = 0.15 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            on = false
            pointerAtSwitch = false
            withAnimation(.easeInOut(duration: 0.3)) { cardOpacity = 1 }
        }
    }
}


/// A slow pulse, standing in for a spinner.
///
/// Two reasons it is drawn rather than a `ProgressView`: a spinner says "work
/// is happening here", and nothing is — the work is the user's, in another
/// window; and `ProgressView` does not render through `ImageRenderer`, which is
/// how this app's windows get looked at at all.
struct WatchingDot: View {
    @State private var wide = false

    var body: some View {
        Circle()
            .fill(HostDeck.accent)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .stroke(HostDeck.accent.opacity(wide ? 0 : 0.55), lineWidth: 2)
                    .scaleEffect(wide ? 2.4 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    wide = true
                }
            }
            .accessibilityHidden(true)
    }
}
