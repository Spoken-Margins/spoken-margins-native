import SessionKit
import SwiftUI

// One real App Attest attestation and assertion for #1593, saved as `device-capture.json` and offered in the share
// sheet. Phone builds only: `SM_APP_ATTEST_CAPTURE` is one of `SM_PHONE_BUILD_CONDITIONS_YES` in project.yml, so an
// upload (SM_PHONE_BUILD=NO) never compiles this file's contents, and it needs SM_SHARE_LINK_CREATION because it
// uses the sender check's `AppAttestDeviceProvider`.
//
// The rules are SessionKit's `AppAttestDeviceCaptureRunner` and its tests: it asks Apple for nothing before the
// listener's agreement is on record, sends nothing to any server, and keeps no key id. This file reads the build's
// own description of itself (App ID and environment, written into Info.plist from the same build settings that
// write the entitlement), runs the runner, writes one JSON file and hands it to the share sheet.

#if SM_APP_ATTEST_CAPTURE && SM_SHARE_LINK_CREATION && canImport(UIKit)

struct AppAttestCaptureRow: View {
    @State private var isCapturing = false
    @State private var message: String?

    var body: some View {
        Button {
            isCapturing = true
            message = nil
            Task {
                defer { isCapturing = false }
                switch await AppAttestCaptureFile.make() {
                case .file(let url): ShareFilePresenter.present(fileURL: url)
                case .failed(let words): message = words
                }
            }
        } label: {
            Group {
                if isCapturing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Asking Apple…")
                    }
                } else {
                    Label("Capture App Attest for the Server Test", systemImage: "checkmark.shield")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isCapturing)
        .accessibilityIdentifier("settings.appAttestCapture.button")
        Text("Phone builds only. Makes a new key, has Apple attest a random local challenge, signs once, and shares the result as device-capture.json for the server's verifier test. It sends nothing to any server and keeps no key. You need to have agreed to the sender check once, by making a share link.")
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("settings.appAttestCapture.message")
        }
    }
}

enum AppAttestCaptureFile {
    enum Outcome {
        case file(URL)
        case failed(String)
    }

    /// Runs the capture and writes `device-capture.json` into a fresh temporary folder. The file holds public values
    /// Apple returned, no secret and nothing from the Library, so a leftover in the temporary folder is harmless.
    static func make(bundle: Bundle = .main) async -> Outcome {
        let runner = AppAttestDeviceCaptureRunner(
            provider: AppAttestDeviceProvider(),
            consent: { ServerSendConsent.hasConsented(to: .shareLinks) },
            appID: bundle.object(forInfoDictionaryKey: "SMAppAttestAppID") as? String ?? "",
            environment: bundle.object(forInfoDictionaryKey: "SMAppAttestEnvironment") as? String ?? "")
        do {
            let capture = try await runner.capture()
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "appattest-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: AppAttestDeviceCapture.fileName)
            try capture.jsonData().write(to: url, options: .atomic)
            return .file(url)
        } catch {
            return .failed(AppAttestDeviceCaptureRunner.failureMessage(for: error))
        }
    }
}

#endif
