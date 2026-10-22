//
//  SecureCredentialManager.swift
//  glance
//
//  Compatibility profile: an app-authenticated, login-keychain session key wraps an encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "密码不能为空。"
        case .sessionLocked:
            return "会话已锁定。请先使用 Touch ID 验证身份，再保存或使用密码。"
        case .encryptionFailed:
            return "加密失败。"
        case .decryptionFailed:
            return "解密失败，已保存的凭据可能已损坏。"
        case .sessionChanged:
            return "会话状态已改变，请重新验证身份。"
        case .sessionKeyUnavailable:
            return "会话密钥丢失，但仅能由该密钥解密的数据仍然存在。现有数据未被删除。可在“密码”页移除已保存的密码，以清除密码和人脸数据后重新设置。"
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    nonisolated(unsafe) private static var sessionGeneration: UInt64 = 0
    private static let sessionUnlocker = SessionUnlockCoordinator()
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    @discardableResult
    nonisolated private static func setCachedKey(_ key: SymmetricKey?, expectedGeneration: UInt64? = nil) -> Bool {
        sessionLock.lock()
        if let expectedGeneration, expectedGeneration != sessionGeneration {
            sessionLock.unlock()
            return false
        }
        if key == nil { sessionGeneration &+= 1 }
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        if changed {
            NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
        }
        return true
    }

    nonisolated private static func currentGeneration() -> UInt64 {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessionGeneration
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        KeychainManager.exists(account: passwordBlobAccount)
    }

    /// System authentication is enforced by this app before accessing its
    /// login-keychain key. This is not a keychain userPresence ACL.
    nonisolated static func unlockSession(reason: String) async throws {
        if cachedKey() != nil { return }
        try await sessionUnlocker.unlock(reason: reason)
    }

    nonisolated fileprivate static func performUnlock(reason: String) async throws {
        if cachedKey() != nil { return }
        let generation = currentGeneration()
        try await DeviceOwnerAuthentication.authenticate(reason: reason)
        try Task.checkCancellation()
        guard currentGeneration() == generation else { throw SecureCredentialError.sessionChanged }

        if try !KeychainManager.itemExists(account: sessionKeyAccount) {
            // Independent compatibility namespace: never replace the author's
            // key, and never replace a missing key while ciphertext exists.
            guard !hasSessionEncryptedData else { throw SecureCredentialError.sessionKeyUnavailable }
            let key = SymmetricKey(size: .bits256)
            var bytes = key.withUnsafeBytes { Data($0) }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            do {
                try KeychainManager.create(account: sessionKeyAccount, data: bytes)
            } catch KeychainError.osStatus(let status) where status == -25299 {
                // A competing instance created it; read its key instead.
            }
        }
        var data = try KeychainManager.read(account: sessionKeyAccount)
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count == 32 else { throw KeychainError.unexpectedData }
        guard setCachedKey(SymmetricKey(data: data), expectedGeneration: generation) else {
            throw SecureCredentialError.sessionChanged
        }
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// No separate Touch ID prompt — only the session key was gated, at unlock time. Caller MUST zero the returned bytes via
    /// `.resetBytes(in:)` after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        lockSession()
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
    }
}

/// Concurrent UI requests share one authentication and key-creation operation.
private actor SessionUnlockCoordinator {
    private var pending: Task<Void, Error>?

    func unlock(reason: String) async throws {
        if let pending { return try await pending.value }
        let task = Task { try await SecureCredentialManager.performUnlock(reason: reason) }
        pending = task
        defer { pending = nil }
        try await task.value
    }
}
