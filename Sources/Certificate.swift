import CryptoKit
import Foundation
import Security

enum Certificate {
    static let name = "GTPS Hosts Private CA 49415744"
    static let keychainPath = "/Library/Keychains/System.keychain"

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ data: Data) throws -> SecCertificate {
        var der = data
        if let pem = String(data: data, encoding: .utf8),
           pem.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----BEGIN CERTIFICATE-----") {
            let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            guard blocks.count == 2 else { throw SetupError("Expected one certificate.") }
            let end = blocks[1].components(separatedBy: "-----END CERTIFICATE-----")
            guard end.count == 2, end[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let decoded = Data(base64Encoded: end[0].components(separatedBy: .whitespacesAndNewlines).joined())
            else { throw SetupError("Invalid PEM certificate.") }
            der = decoded
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw SetupError("Expected a DER or PEM certificate. The download link may have returned a web page.")
        }
        return certificate
    }

    static func pinned(_ data: Data) throws -> SecCertificate {
        guard !BuildPin.sha256.isEmpty else {
            throw SetupError("Install is disabled pending the independently confirmed certificate fingerprint.")
        }
        let certificate = try parse(data)
        guard fingerprint(SecCertificateCopyData(certificate) as Data) == BuildPin.sha256 else {
            throw SetupError("The certificate SHA-256 fingerprint does not match the confirmed fingerprint.")
        }
        guard SecCertificateCopySubjectSummary(certificate) as String? == name else {
            throw SetupError("The certificate display name does not match.")
        }
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate), subject == issuer else {
            throw SetupError("The pinned certificate is not a self-issued root.")
        }
        return certificate
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw SetupError("\(action) failed. \(detail)")
        }
    }
}

struct SystemCertificate {
    let certificate: SecCertificate
    let keychain: SecKeychain
    let sslPolicy = SecPolicyCreateSSL(true, nil)

    init(_ certificate: SecCertificate) throws {
        self.certificate = certificate
        var keychain: SecKeychain?
        try Certificate.check(SecKeychainOpen(Certificate.keychainPath, &keychain), "Opening the System keychain")
        guard let keychain else { throw SetupError("System keychain is unavailable.") }
        self.keychain = keychain
    }

    func item() throws -> SecCertificate? {
        let der = SecCertificateCopyData(certificate) as Data
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchSearchList as String: [keychain],
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Certificate.check(status, "Reading the System keychain")
        guard let certificates = result as? [SecCertificate] else {
            throw SetupError("Unexpected System keychain query result.")
        }
        return certificates.first { (SecCertificateCopyData($0) as Data) == der }
    }

    func trust() throws -> [[String: Any]]? {
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, .admin, &settings)
        if status == errSecItemNotFound || status == errSecNoTrustSettings { return nil }
        try Certificate.check(status, "Reading administrator certificate trust")
        guard let entries = settings as? [[String: Any]] else {
            throw SetupError("Unexpected certificate trust settings.")
        }
        return entries
    }

    func isSetupTrust(_ settings: [[String: Any]]) -> Bool {
        guard settings.count == 1, var entry = settings.first else { return false }
        guard entry.removeValue(forKey: kSecTrustSettingsResult as String) as? Int
                == Int(SecTrustSettingsResult.trustRoot.rawValue) else { return false }
        return isUnrestrictedSSLPolicy(entry)
    }

    func acceptsExistingSSLTrust(_ settings: [[String: Any]]) -> Bool {
        // Keychain Access can express Always Trust as separate SSL records with allowed errors.
        // Reuse those records as-is, but never treat them as trust settings created by this app.
        !settings.isEmpty && settings.allSatisfy { settings in
            var entry = settings
            if let result = entry.removeValue(forKey: kSecTrustSettingsResult as String),
               result as? Int != Int(SecTrustSettingsResult.trustRoot.rawValue) { return false }
            if let allowedError = entry.removeValue(forKey: kSecTrustSettingsAllowedError as String),
               !(allowedError is NSNumber) { return false }
            return isUnrestrictedSSLPolicy(entry)
        }
    }

    private func isUnrestrictedSSLPolicy(_ settings: [String: Any]) -> Bool {
        // macOS may return the policy's internal name alongside its public reference.
        let policyNameKey = "kSecTrustSettingsPolicyName"
        var entry = settings
        if let name = entry.removeValue(forKey: policyNameKey), name as? String != "sslServer" { return false }
        guard entry.count == 1,
              let policy = entry[kSecTrustSettingsPolicy as String],
              CFGetTypeID(policy as CFTypeRef) == SecPolicyGetTypeID()
        else { return false }
        let installedPolicy = policy as! SecPolicy
        guard let properties = SecPolicyCopyProperties(installedPolicy),
              let expected = SecPolicyCopyProperties(sslPolicy) else { return false }
        return CFEqual(properties, expected)
    }

    func add() throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecUseKeychain as String: keychain
        ]
        try Certificate.check(SecItemAdd(attributes as CFDictionary, nil), "Adding the certificate")
    }

    func setTrust() throws {
        let entry: [String: Any] = [
            kSecTrustSettingsPolicy as String: sslPolicy,
            kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue
        ]
        try Certificate.check(SecTrustSettingsSetTrustSettings(certificate, .admin, [entry] as CFArray),
                              "Setting SSL trust")
    }

    func removeTrust() throws {
        try Certificate.check(SecTrustSettingsRemoveTrustSettings(certificate, .admin), "Removing SSL trust")
    }

    func remove(_ item: SecCertificate) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchItemList as String: [item],
            kSecMatchSearchList as String: [keychain]
        ]
        try Certificate.check(SecItemDelete(query as CFDictionary), "Removing the certificate")
    }

    func verify() throws {
        guard try item() != nil, let settings = try trust(), acceptsExistingSSLTrust(settings) else {
            throw SetupError("Could not verify the certificate and its SSL trust in the System keychain.")
        }
    }
}
