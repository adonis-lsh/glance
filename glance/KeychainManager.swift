import Foundation

/// The application always uses its login keychain and its independent service.
enum KeychainManager {
    nonisolated static let service = GlanceCompatibility.keychainService

    private nonisolated static func store() throws -> LoginKeychainStore {
        try .default(service: service)
    }

    nonisolated static func itemExists(account: String) throws -> Bool {
        try store().contains(account: account)
    }

    /// Conservative UI state; unlock uses itemExists to surface actual errors.
    nonisolated static func exists(account: String) -> Bool {
        (try? itemExists(account: account)) ?? true
    }

    nonisolated static func read(account: String) throws -> Data {
        try store().read(account: account)
    }

    nonisolated static func create(account: String, data: Data) throws {
        try store().create(account: account, data: data)
    }

    nonisolated static func save(account: String, data: Data) throws {
        try store().save(account: account, data: data)
    }

    nonisolated static func delete(account: String) throws {
        try store().delete(account: account)
    }
}
