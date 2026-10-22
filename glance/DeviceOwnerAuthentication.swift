import Foundation
import LocalAuthentication

enum DeviceOwnerAuthentication {
    /// App-enforced session gate; not a keychain userPresence constraint.
    nonisolated static func authenticate(reason: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? KeychainError.authenticationFailed as NSError
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw KeychainError.authenticationFailed
        }
    }
}
