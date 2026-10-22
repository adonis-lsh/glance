// Compiled with the real LoginKeychainStore and SecureCredentialManager.
// Only system authentication and face-store presence are fixtures. The random
// service never touches production credentials. No auth fixture ships in Glance.
import Foundation
import Security

private let testService = "local.GlanceCredentialSelftest." + UUID().uuidString
private let testStore = try! LoginKeychainStore.default(service: testService)

enum KeychainManager {
    static func itemExists(account: String) throws -> Bool { try testStore.contains(account: account) }
    static func exists(account: String) -> Bool { (try? itemExists(account: account)) ?? true }
    static func read(account: String) throws -> Data { try testStore.read(account: account) }
    static func create(account: String, data: Data) throws { try testStore.create(account: account, data: data) }
    static func save(account: String, data: Data) throws { try testStore.save(account: account, data: data) }
    static func delete(account: String) throws { try testStore.delete(account: account) }
}

enum SecureFaceStore { static let exists = false }

private actor AuthenticationFixture {
    var denied = true
    var delay: UInt64 = 0
    var calls = 0
    func configure(denied: Bool, delay: UInt64 = 0) { self.denied = denied; self.delay = delay }
    func count() -> Int { calls }
    func authenticate() async throws {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if denied { throw KeychainError.authenticationFailed }
    }
}
private let authentication = AuthenticationFixture()
enum DeviceOwnerAuthentication {
    static func authenticate(reason: String) async throws { try await authentication.authenticate() }
}

@main struct CredentialSelftest {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "CredentialSelftest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS:", message)
    }

    static func main() async throws {
        defer {
            try? KeychainManager.delete(account: "encryptedPassword")
            try? KeychainManager.delete(account: "sessionKey")
            SecureCredentialManager.lockSession()
        }
        do {
            _ = try SecureCredentialManager.readPassword()
            fatalError("locked read succeeded")
        } catch SecureCredentialError.sessionLocked { print("PASS: locked read rejected") }

        do {
            try await SecureCredentialManager.unlockSession(reason: "test denied authentication")
            fatalError("denied authentication succeeded")
        } catch KeychainError.authenticationFailed { }
        try require(!SecureCredentialManager.isSessionUnlocked, "denied authentication leaves session locked")
        try require(!KeychainManager.itemExists(account: "sessionKey"), "denied authentication creates no key")

        await authentication.configure(denied: false)
        try await SecureCredentialManager.unlockSession(reason: "test successful authentication")
        let dummy = Data(" public dummy 密码 😀 with leading and trailing spaces ".utf8)
        try SecureCredentialManager.savePassword(dummy)
        let ciphertext = try KeychainManager.read(account: "encryptedPassword")
        try require(ciphertext != dummy, "password is encrypted in login keychain")
        try require(SecureCredentialManager.readPassword() == dummy, "Unicode and spaces round-trip")
        let originalKey = try KeychainManager.read(account: "sessionKey")
        do {
            try KeychainManager.create(account: "sessionKey", data: Data(repeating: 0, count: 32))
            fatalError("duplicate key replaced the original")
        } catch KeychainError.osStatus(let status) where status == errSecDuplicateItem { }
        try require(KeychainManager.read(account: "sessionKey") == originalKey, "add-only key creation cannot overwrite key")

        SecureCredentialManager.lockSession()
        try await SecureCredentialManager.unlockSession(reason: "test reopen existing session")
        try require(SecureCredentialManager.readPassword() == dummy, "locked session reopens with persisted key")
        try KeychainManager.save(account: "encryptedPassword", data: Data("corrupt ciphertext".utf8))
        do {
            _ = try SecureCredentialManager.readPassword()
            fatalError("corrupted ciphertext accepted")
        } catch SecureCredentialError.decryptionFailed { print("PASS: corrupted ciphertext rejected") }
        try KeychainManager.save(account: "encryptedPassword", data: ciphertext)

        SecureCredentialManager.lockSession()
        await authentication.configure(denied: false, delay: 150_000_000)
        let before = await authentication.count()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await SecureCredentialManager.unlockSession(reason: "concurrent test") }
            }
            try await group.waitForAll()
        }
        let after = await authentication.count()
        try require(after - before == 1, "concurrent requests share one authentication")
        try require(SecureCredentialManager.readPassword() == dummy, "concurrent unlock preserves encryption key")

        SecureCredentialManager.lockSession()
        let prior = await authentication.count()
        let pending = Task { try await SecureCredentialManager.unlockSession(reason: "cancel by locking test") }
        while await authentication.count() == prior { try await Task.sleep(nanoseconds: 1_000_000) }
        SecureCredentialManager.lockSession()
        do {
            try await pending.value
            fatalError("late authentication reopened locked session")
        } catch SecureCredentialError.sessionChanged { }
        try require(!SecureCredentialManager.isSessionUnlocked, "late authentication cannot override manual lock")

        try SecureCredentialManager.deletePassword()
        try require(!KeychainManager.itemExists(account: "encryptedPassword"), "encrypted password deletion works")
        try require(!KeychainManager.itemExists(account: "sessionKey"), "session key deletion works")
        print("All credential self-tests passed; random-service items cleaned up.")
    }
}
