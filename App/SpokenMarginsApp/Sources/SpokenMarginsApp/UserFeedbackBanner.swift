import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

struct UserFeedbackEvent: Identifiable, Equatable {
    typealias Kind = FeedbackBannerPolicy.Kind

    let id = UUID()
    let kind: Kind
    let message: String
    /// Repeats the failed action. Only an error offers it, and the banner then shows Retry. The key names
    /// the action, so trying it again another way can withdraw a stale offer.
    struct Retry {
        let key: String
        let action: @MainActor () -> Void
    }

    var retry: Retry? = nil

    /// One button on a confirmation, such as Play now after an add (#784).
    struct Action {
        let title: String
        let accessibilityLabel: String
        let identifier: String
        let perform: @MainActor () -> Void
    }

    var action: Action? = nil

    /// The listen a summary or transcription failure is about. While that listen's playback screen shows,
    /// the event is a one-line tag at its top instead of this banner (#430).
    var origin: FeedbackOrigin? = nil

    /// Each event is new, so its id decides equality; the retry action can't be compared.
    static func == (lhs: UserFeedbackEvent, rhs: UserFeedbackEvent) -> Bool {
        lhs.id == rhs.id
    }

    func mayBeReplaced(by newer: UserFeedbackEvent) -> Bool {
        FeedbackBannerPolicy.mayReplace(currentKind: kind, currentOffersRetry: retry != nil, with: newer.kind)
    }
}

extension Gate1AppModel {
    /// URLError's default description is a raw domain/code string, which is not useful to a listener.
    nonisolated static func userFacingMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "The request timed out. Please try again."
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "You appear to be offline. Check your connection and try again."
        case .badServerResponse, .fileDoesNotExist, .resourceUnavailable, .zeroByteResource:
            return "The server couldn’t provide anything at that address. Check the link and try again."
        case .badURL, .unsupportedURL, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "That address couldn’t be reached. Check the link and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "A secure connection to that site couldn’t be made."
        default:
            return "The network request failed. Please try again."
        }
    }
}

/// The app's top banner. Confirmations and warnings dismiss themselves and let taps through. An error
/// stays until the listener closes it or retries (#310), so it takes taps, as does a confirmation
/// with an action (#784).
struct UserFeedbackBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.feedbackDeliveryEffects) private var effects
    @Environment(\.feedbackBannerHold) private var hold
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusedPart: Part?
    let feedback: UserFeedbackEvent

    private enum Part: Hashable { case message, action }

    /// Only the listener dismisses it, or a newer banner replaces it. An error always has been so; with
    /// VoiceOver or Switch Control a banner that offers an action is too (#1927).
    private var staysUntilDismissed: Bool {
        FeedbackBannerPolicy.autoDismissSeconds(
            for: feedback.kind,
            offersAction: feedback.action != nil,
            assistiveTechnologyRunning: effects.assistiveTechnologyRunning()
        ) == nil
    }

    /// At accessibility sizes the message gets the full width and the buttons move to their own row (#1935).
    private var largeText: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        bannerLayout
            .padding(12)
            .foregroundStyle(AppColors.text)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
            .padding(.top, 44)
            .allowsHitTesting(feedback.kind == .error || feedback.action != nil || staysUntilDismissed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in hold?.setTouched(true) }
                    .onEnded { _ in hold?.setTouched(false) }
            )
            .onChange(of: focusedPart) { _, part in hold?.setFocused(part != nil) }
            .onDisappear { hold?.reset() }
    }

    @ViewBuilder
    private var bannerLayout: some View {
        if largeText {
            VStack(alignment: .leading, spacing: 8) {
                messageRow
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(alignment: .leading, spacing: 4) { buttons }
                }
            }
        } else {
            HStack(spacing: 10) {
                messageRow
                buttons
            }
        }
    }

    private var messageRow: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(feedback.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(largeText ? nil : (feedback.kind == .error ? 6 : 3))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($focusedPart, equals: .message)
        .accessibilityIdentifier("app.feedback.banner")
    }

    @ViewBuilder
    private var buttons: some View {
        if let action = feedback.action {
            Button(action.title) {
                model.dismissFeedback(id: feedback.id)
                action.perform()
            }
            .filledActionButton()
            .frame(minHeight: 44)
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityFocused($focusedPart, equals: .action)
            .accessibilityIdentifier(action.identifier)
        }
        if feedback.kind == .error, let retry = feedback.retry {
            Button("Retry") {
                model.dismissFeedback(id: feedback.id)
                retry.action()
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .frame(minHeight: largeText ? 44 : nil)
            .accessibilityIdentifier("app.feedback.retry")
        }
        if feedback.kind == .error || staysUntilDismissed {
            Button {
                model.dismissFeedback(id: feedback.id)
            } label: {
                TapTargetIcon(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("app.feedback.dismiss")
        }
    }

    private var iconName: String {
        switch feedback.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch feedback.kind {
        case .success: .green
        case .warning: .orange
        case .error: AppColors.dangerText // octagon, not triangle: must differ from warnings by shape (#308)
        }
    }
}

/// The last failure on an item, readable after its banner has gone (#310).
struct ItemLastFailureCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    let itemId: String

    var body: some View {
        if let failure = model.itemFailures.lastFailure(itemId: itemId) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(AppColors.dangerText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last problem, \(failure.occurredAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                    Text(failure.message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    model.clearLastFailure(itemId: itemId)
                } label: {
                    TapTargetIcon(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear last problem")
                .accessibilityIdentifier("item.lastFailure.clear")
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("item.lastFailure")
        }
    }
}
