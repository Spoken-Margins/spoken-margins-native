import SessionKit
import SwiftUI

struct HelpScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Getting Started") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Learn the core loop")
                                .font(.headline)
                            Spacer()
                            Text("\(model.onboardingCoreCompletedCount) of \(OnboardingStep.core.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        ProgressView(
                            value: Double(model.onboardingCoreCompletedCount),
                            total: Double(OnboardingStep.core.count)
                        )
                        .tint(AppColors.primaryAction)
                    }
                    .padding(.vertical, 4)
                    OnboardingChecklistRow(
                        title: "Make your first Margin",
                        isComplete: model.isOnboardingStepComplete(.firstInterjection)
                    )
                    OnboardingChecklistRow(
                        title: "Find it in the timeline",
                        isComplete: model.isOnboardingStepComplete(.reviewedTimeline)
                    )
                    OnboardingChecklistRow(
                        title: "Export or copy a session",
                        isComplete: model.isOnboardingStepComplete(.exportedSession)
                    )
                    Button(
                        model.hasCompletedCoreOnboarding ? "Replay Guided Tour" : "Start or Resume Guided Tour",
                        action: model.startGuidedOnboarding
                    )
                    .accessibilityIdentifier("help.onboarding.start.button")
                    if model.isOnboardingCardDismissed && !model.hasCompletedCoreOnboarding {
                        Button("Show Progress in the Library", action: model.restoreOnboardingCard)
                            .accessibilityIdentifier("help.onboarding.restoreCard.button")
                    }
                }
                Section("Bring In Your Content") {
                    Text("These are optional ways to build your library. You do not need to try every source type to finish onboarding.")
                        .foregroundStyle(AppColors.secondaryText)
                    OnboardingChecklistRow(
                        title: "Add one source of your own",
                        isComplete: model.isOnboardingStepComplete(.addedOwnSource)
                    )
                    OnboardingChecklistRow(
                        title: "Add something from Safari",
                        isComplete: model.isOnboardingStepComplete(.addedFromSafari)
                    )
                    OnboardingChecklistRow(
                        title: "Add something from Files",
                        isComplete: model.isOnboardingStepComplete(.addedFromFiles)
                    )
                    OnboardingChecklistRow(
                        title: "Add a podcast",
                        isComplete: model.isOnboardingStepComplete(.addedPodcast)
                    )
                }
                Section("Listening Sessions") {
                    Text("Continue Listening resumes your most recent unfinished session. Start New Session creates a separate listening pass with its own notes.")
                    Text("The X in the mini-player saves your place, stops playback, and hides the mini-player. It does not delete the session.")
                }
                Section("Margins") {
                    Text("Tap the record button on the mini player, or Add a Margin on Now Playing, speak your note, then tap Save & resume. The Margin stays attached to the point you were hearing.")
                    Text("Playback restarts before transcription runs in the background. A short pause can still occur while the app saves the recording and switches the audio session back to playback.")
                    Text("Open the Margins tab and tap a Margin to hear its recording or read its transcript.")
                }
                Section("Optional AI") {
                    Text("Summarize Notes uses Apple’s on-device Foundation Model when available. Listening Maps use publisher chapters for podcasts and deterministic structure for native text.")
                    Text("AI-generated Listening Maps are reserved for a future server-hosted option and are not included in this release.")
                    Text("Discuss and third-party API settings are disabled. Copy your Margins to another chatbot and paste its response into the Conversation section if you want that workflow.")
                    LabeledContent("Availability", value: model.localFoundationModelAvailabilityDescription)
                }
                Section("Safari Articles") {
                    Text("In Safari, open Manage Extensions and enable Spoken Margins Text. Tap the extension once to send the readable page to Spoken Margins.")
                    Text("For Safari’s Share menu, run the Add Article to Spoken Margins Shortcut. In the app, the Link field takes podcast episodes, RSS feeds, audio files, web articles and PDF links.")
                }
                Section("Files and PDFs") {
                    Text("In the Library, tap Add, then Document or Book. You can also share a PDF, Markdown file, or text file to Spoken Margins from another app.")
                    Text("PDFs must contain extractable text. Image-only or scanned PDFs need OCR before Spoken Margins can import them.")
                }
                Section("Podcast Links") {
                    Text("Paste a podcast episode, RSS, or direct audio URL into Add Source. For Spotify, share the specific episode; a show or podcast-page link does not identify one episode.")
                }
                Section("Share and Export") {
                    Text("Choose the listening session, format, and included material. Share Session opens the iOS share sheet; Copy puts the generated Markdown or JSON on the clipboard.")
                    Text("From Margins, tap Export Sessions to select multiple listening sessions and share one Markdown file per session. The share sheet lets you choose AirDrop, Save to Files or another app each time.")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.isHelpPresented = false }
                        .accessibilityIdentifier("help.done.button")
                }
            }
            .accessibilityIdentifier("help.screen")
        }
    }
}

private struct OnboardingChecklistRow: View {
    let title: String
    let isComplete: Bool

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isComplete ? AppColors.secondaryText : AppColors.text)
        } icon: {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? AppColors.green : AppColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Complete" : "Not complete")
    }
}
