import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WDSession

/// Hardware-backed ECDSA P-256 key in the iPad Secure Enclave gated by Touch ID or Face ID.
///
/// The private key never leaves the Secure Enclave and cannot sign without live hardware
/// biometry verification (`.biometryCurrentSet`). Adding or changing Touch ID / Face ID
/// enrollment on the iPad automatically invalidates the key.
enum BiometricAuthKey {
    private static let keyTag = Data("dev.wireddisplay.client.pam.p256".utf8)

    enum BiometryKind {
        case faceID
        case touchID
        case unavailable

        var label: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .unavailable: return "Biometric Auth"
            }
        }

        var symbol: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .unavailable: return "lock.shield"
            }
        }
    }

    static var biometryKind: BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .unavailable
        }
    }

    static var isEnrolled: Bool { publicKey() != nil }

    /// Short 16-hex-char fingerprint of the 65-byte X9.63 public key for human verification.
    static func fingerprint(of publicKey: [UInt8]) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the existing 65-byte uncompressed X9.63 ECDSA P-256 public key without prompting biometry.
    static func publicKey() -> [UInt8]? {
        guard let privateKey = copyPrivateKey(context: nil),
              let pubKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pubKey, &error) as Data?,
              data.count == BiometricAuthMessage.p256PublicKeyLength else { return nil }
        return [UInt8](data)
    }

    /// Creates a new Secure Enclave P-256 key gated by `.biometryCurrentSet` (replacing any old one)
    /// and returns its 65-byte X9.63 public key.
    @discardableResult
    static func enroll() throws -> [UInt8] {
        delete()
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessError
        ) else {
            throw accessError?.takeRetainedValue() ?? NSError(domain: "WiredDisplay.Biometric", code: -1)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw createError?.takeRetainedValue() ?? NSError(domain: "WiredDisplay.Biometric", code: -2)
        }
        guard let pubKey = SecKeyCopyPublicKey(privateKey),
              let data = SecKeyCopyExternalRepresentation(pubKey, &createError) as Data?,
              data.count == BiometricAuthMessage.p256PublicKeyLength else {
            delete()
            throw createError?.takeRetainedValue() ?? NSError(domain: "WiredDisplay.Biometric", code: -3)
        }
        return [UInt8](data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Signs a PAM challenge inside the Secure Enclave, triggering Touch ID or Face ID.
    /// Status codes: 0 = ok, 1 = cancelled, 2 = unavailable/failed, 3 = notEnrolled.
    static func sign(service: String, username: String, reason: String, nonce: [UInt8]) async -> (status: UInt8, signature: [UInt8]) {
        guard nonce.count == BiometricAuthMessage.nonceLength else { return (2, []) }
        guard isEnrolled else { return (3, []) }

        let context = LAContext()
        // Strictly require hardware Touch ID / Face ID; never fall back to the iPad passcode.
        context.localizedFallbackTitle = ""
        let promptReason = reason.isEmpty ? "Approve \(service) for \(username) on Mac" : reason

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: promptReason)
            guard ok else { return (1, []) }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return (1, [])
            default:
                ClientLog.write("biometric auth failed: \(error.localizedDescription)")
                return (2, [])
            }
        } catch {
            ClientLog.write("biometric auth error: \(error.localizedDescription)")
            return (2, [])
        }

        guard let privateKey = copyPrivateKey(context: context) else {
            return (3, [])
        }
        let message = Data(BiometricAuthMessage.canonical(service: service, username: username, nonce: nonce))
        var signError: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, &signError) as Data? else {
            let errDesc = signError?.takeRetainedValue().localizedDescription ?? "unknown"
            ClientLog.write("biometric Secure Enclave sign failed: \(errDesc)")
            return (2, [])
        }
        return (0, [UInt8](sig))
    }

    private static func copyPrivateKey(context: LAContext?) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }
}
