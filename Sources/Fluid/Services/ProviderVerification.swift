import CryptoKit
import Foundation

/// The one rule for whether a provider counts as verified. AI settings stores a fingerprint of the
/// address and key when the connection test passes; a provider stays verified while its current
/// address and key give the same fingerprint. Dictation, Edit Mode, Command Mode and the settings
/// store all ask this.
nonisolated enum ProviderVerification {
    /// SHA-256 of the trimmed address and key, or nil when there is no address.
    static func fingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }

        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A provider that passed the connection test without a key stays verified (Ali, 2026-10-21).
    /// A remote address must use https, so dictated text never crosses the internet unencrypted;
    /// local and LAN addresses may use plain http.
    static func isVerified(storedFingerprint: String?, baseURL: String, apiKey: String) -> Bool {
        guard let storedFingerprint else { return false }
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelRepository.isLocalEndpoint(trimmedBase) || trimmedBase.lowercased().hasPrefix("https://") else {
            return false
        }
        return self.fingerprint(baseURL: trimmedBase, apiKey: apiKey) == storedFingerprint
    }
}
