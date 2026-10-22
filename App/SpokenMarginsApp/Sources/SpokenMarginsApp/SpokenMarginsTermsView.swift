import SwiftUI

struct SpokenMarginsTermsView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let allowsAcceptance: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spoken Margins Terms of Use")
                        .font(.title2.bold())
                        .screenTitle()
                    Text("Version \(SpokenMarginsTerms.currentVersion) · Effective \(SpokenMarginsTerms.effectiveDate)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(SpokenMarginsTerms.bundledText())
                    .font(.body)
                    .textSelection(.enabled)

                Link("Read Apple’s Standard EULA", destination: SpokenMarginsTerms.appleStandardEULAURL)
                Link("Read the public copy of these Terms", destination: SpokenMarginsTerms.publicURL)

                NavigationLink("Read the complete OpenRAIL-M license") {
                    SupertonicLegalView()
                        .miniPlayerKeepOut()
                }

                if model.hasAcceptedCurrentTerms {
                    Label("Accepted version \(SpokenMarginsTerms.currentVersion)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(AppColors.green)
                        .accessibilityIdentifier("terms.accepted.status")
                } else if allowsAcceptance {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By continuing, you agree to these Terms and enable the bundled Supertonic on-device voice. The iOS system voice remains available if you do not agree.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Agree and Enable On-Device Voice") {
                            model.acceptCurrentTermsAndEnableOnDeviceVoice()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!SpokenMarginsTerms.hasBundledText())
                        .accessibilityIdentifier("terms.accept.button")

                        if !SpokenMarginsTerms.hasBundledText() {
                            FailureMessageLabel("The bundled Terms are unavailable, so the on-device voice cannot be enabled in this build.")
                                .font(.footnote)
                                .accessibilityIdentifier("terms.unavailable.error")
                        }

                        Button("Use iOS Voice", role: .cancel) {
                            model.declineCurrentTerms()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("terms.decline.button")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("terms.screen")
    }
}
