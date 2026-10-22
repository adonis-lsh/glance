//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "待机"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try await SecureCredentialManager.unlockSession(reason: "验证身份以设置或使用 Glance")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "请先输入密码。"
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "密码已加密保存。"
            hasStoredPassword = true
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "尚未获得辅助功能权限，请在系统设置中为 Glance 启用此权限。"
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "会话已锁定，请先通过系统身份验证。"
            return false
        }
        if requireAuthoritativeLock, !LockMonitor.isScreenActuallyLocked() {
            statusMessage = "锁屏状态未确认，已取消输入密码。"
            return false
        }
        statusMessage = "正在输入密码…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                // Check again after the potentially blocking keychain read.
                if requireAuthoritativeLock, !LockMonitor.isScreenActuallyLocked() {
                    throw KeystrokeError.screenNotLocked
                }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            if requireAuthoritativeLock {
                let deadline = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < deadline, !Task.isCancelled {
                    if LockMonitor.screenLockState() == false {
                        statusMessage = "已确认屏幕解锁。"
                        return true
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                statusMessage = "已发送解锁输入，但屏幕仍锁定或状态无法确认。请检查登录密码和锁屏输入框。"
                return false
            }
            statusMessage = "已输入保存的密码并按回车。"
            return true
        } catch {
            statusMessage = "输入密码失败：\(error.localizedDescription)"
            return false
        }
    }

}
