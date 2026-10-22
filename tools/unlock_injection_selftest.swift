// Real POCController, with fixtures for the OS lock state and keystroke sink.
// No credentials are read and no keyboard events are emitted by this test.
import Foundation

private final class Fixture: @unchecked Sendable {
    enum Outcome { case unlock, stayLocked, unknown, fail }
    private let lock = NSLock()
    private var screen: Bool? = true
    private var trusted = true
    private var session = true
    private var outcome: Outcome = .unlock
    private var sends = 0
    func configure(screen: Bool? = true, trusted: Bool = true, session: Bool = true, outcome: Outcome = .unlock) {
        lock.lock(); defer { lock.unlock() }
        self.screen = screen; self.trusted = trusted; self.session = session; self.outcome = outcome; sends = 0
    }
    func state() -> (Bool?, Bool, Bool, Int) {
        lock.lock(); defer { lock.unlock() }
        return (screen, trusted, session, sends)
    }
    func setSession(_ value: Bool) { lock.lock(); defer { lock.unlock() }; session = value }
    func send() throws {
        lock.lock(); defer { lock.unlock() }
        sends += 1
        switch outcome {
        case .unlock: screen = false
        case .stayLocked: break
        case .unknown: screen = nil
        case .fail: throw KeystrokeError.eventCreationFailed
        }
    }
}
private let fixture = Fixture()
enum SecureCredentialError: Error { case emptyPassword }
enum KeystrokeError: Error { case eventCreationFailed, screenNotLocked }
enum SecureCredentialManager {
    static var isSessionUnlocked: Bool { fixture.state().2 }
    static func hasStoredPassword() -> Bool { true }
    static func unlockSession(reason: String) async throws { fixture.setSession(true) }
    static func lockSession() { fixture.setSession(false) }
    static func savePassword(_ bytes: Data) throws { }
    static func readPassword() throws -> Data { Data("public dummy password".utf8) }
}
enum KeystrokeInjector {
    static func isAccessibilityTrusted() -> Bool { fixture.state().1 }
    static func promptForAccessibility() { }
    static func typeAndReturn(_ bytes: Data) throws { try fixture.send() }
}
enum LockMonitor {
    static func isScreenActuallyLocked() -> Bool { fixture.state().0 == true }
    static func screenLockState() -> Bool? { fixture.state().0 }
}

@main struct UnlockInjectionSelftest {
    @MainActor static func main() async {
        let controller = POCController()
        fixture.configure(screen: false)
        let unlockedInput = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!unlockedInput && fixture.state().3 == 0)
        print("PASS: no password input outside confirmed lock screen")
        fixture.configure(trusted: false)
        let untrusted = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!untrusted && fixture.state().3 == 0)
        print("PASS: Accessibility is required")
        fixture.configure(session: false)
        let lockedSession = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!lockedSession && fixture.state().3 == 0)
        print("PASS: unlocked credential session is required")
        fixture.configure()
        let success = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(success && fixture.state().3 == 1)
        print("PASS: success requires observed lock-screen exit")
        fixture.configure(outcome: .fail)
        let failure = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!failure && fixture.state().3 == 1)
        print("PASS: keystroke error is not reported as success")
        fixture.configure(outcome: .stayLocked)
        let stillLocked = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!stillLocked && fixture.state().3 == 1)
        print("PASS: unconfirmed input fails without submitting twice")
        fixture.configure(outcome: .unknown)
        let unknown = await controller.injectStoredPassword(requireAuthoritativeLock: true)
        precondition(!unknown && fixture.state().3 == 1)
        print("PASS: unavailable lock state never counts as success")
        print("All injection control-flow self-tests passed.")
    }
}
