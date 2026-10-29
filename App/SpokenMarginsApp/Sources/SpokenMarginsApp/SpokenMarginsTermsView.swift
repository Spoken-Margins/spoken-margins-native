import SwiftUI
import SessionKit

struct SpokenMarginsTermsView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let allowsAcceptance: Bool

    /// Fixed when the sheet appears: accepting clears the waiting play and flips the Terms to accepted while the
    /// sheet is still closing, and the screen must not turn into the long text on the way out.
    @State private var openedAs: PlaybackTermsGate.Presentation?

    var body: some View {
        let presentation = openedAs ?? PlaybackTermsGate.presentation(
            playbackIsWaiting: model.pendingPlaybackAfterTerms != nil, termsAccepted: model.hasAcceptedCurrentTerms
        )
        Group {
            if allowsAcceptance, presentation == .summary {
                TermsSummaryView()
            } else {
                completeTerms
            }
        }
        .onAppear { if openedAs == nil { openedAs = presentation } }
    }

    private var completeTerms: some View {
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

/// The Terms at a first Play (#2853): one screen with a short summary, a link to the complete Terms, and both
/// actions in view without scrolling. Accepting starts the play; so does choosing the iOS voice. "Read the complete
/// Terms" opens the whole text to read, and Back returns here; Settings shows the whole text, with the actions at its
/// end, for a voice the listener picks.
private struct TermsSummaryView: View {
    @EnvironmentObject private var model: Gate1AppModel

    /// The whole screen when it fits; a scrolling copy at accessibility text sizes or in landscape, so the buttons
    /// can always be reached on a sheet that can't be swiped away.
    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxHeight: .infinity, alignment: .topLeading)
            ScrollView { content }
        }
        .padding()
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("terms.screen")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Before you listen")
                .font(.title2.bold())
                .screenTitle()
            Text("Spoken Margins can read to you in a voice that runs on your phone. Using it means agreeing to the Terms of Use, which include the voice model's license and its use restrictions. Until you agree, your iPhone's own voice reads.")
                .font(.body)
            NavigationLink("Read the complete Terms") {
                SpokenMarginsTermsView(allowsAcceptance: false)
            }
            .accessibilityIdentifier("terms.readComplete.link")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Text("By tapping Agree, you agree to the Spoken Margins Terms of Use, version \(SpokenMarginsTerms.currentVersion).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    model.acceptCurrentTermsAndEnableOnDeviceVoice()
                } label: {
                    Text("Agree and Enable On-Device Voice").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!SpokenMarginsTerms.hasBundledText())
                .accessibilityIdentifier("terms.accept.button")
                if !SpokenMarginsTerms.hasBundledText() {
                    FailureMessageLabel("The bundled Terms are unavailable, so the on-device voice cannot be enabled in this build.")
                        .font(.footnote)
                        .accessibilityIdentifier("terms.unavailable.error")
                }
                Button(role: .cancel) {
                    model.declineCurrentTerms()
                } label: {
                    Text("Use iOS Voice").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("terms.decline.button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
