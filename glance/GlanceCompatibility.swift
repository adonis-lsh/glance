import Foundation

/// Keep this profile separate from the author's signed application.
enum GlanceCompatibility {
    nonisolated static let keychainService = "com.adonis-lsh.glance.compatibility.v1"
    nonisolated static let preferencesSuite = "com.adonis-lsh.glance.compatibility.v1"
    nonisolated static let faceStoreFilename = "face-identities.compat-v1.enc"
}
