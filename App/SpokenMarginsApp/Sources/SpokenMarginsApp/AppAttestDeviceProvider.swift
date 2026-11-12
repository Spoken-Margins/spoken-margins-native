import DeviceCheck
import Foundation
import SessionKit

// Apple's App Attest calls for the sender check before a share link (#2239). The rules live in SessionKit
// (`AttestedServerClient`): it asks for the listener's agreement before any of this runs, makes the key only on the
// first attested request, and keeps the key id in UserDefaults so a reinstall gets a fresh key (Apple agreement
// 3.3.3B). This file is only the thin layer over `DCAppAttestService`, and it checks the agreement itself too, so no
// future caller can make a key without it (#2842; `scripts/tests/test_server_contact_consent.py` fails if a file that
// uses App Attest stops checking, or reaches for the system's secret store).
//
// App Attest does not run in the Simulator, where `isSupported` is false; the sender check is then skipped and the
// link is made without a permit, as before. Whether the server accepts a real phone's attestation is the one thing
// only a device can show (#1593).

#if SM_SHARE_LINK_CREATION

struct AppAttestDeviceProvider: AppAttestKeyProvider {
    var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        guard ServerSendConsent.hasConsented(to: .shareLinks) else { throw AppAttestFailure.needsConsent }
        return try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard ServerSendConsent.hasConsented(to: .shareLinks) else { throw AppAttestFailure.needsConsent }
        return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard ServerSendConsent.hasConsented(to: .shareLinks) else { throw AppAttestFailure.needsConsent }
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            // The key id is saved in UserDefaults and came back without its Secure Enclave key: make a new one.
            throw AppAttestFailure.keyUnusable
        }
    }
}

#endif
