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

    /// The listen a summary or transcription failure is about. While that listen is on the Now screen,
    /// the event is a tag under its title instead of this banner (#430).
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
    let feedback: UserFeedbackEvent

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(feedback.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(feedback.kind == .error ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("app.feedback.banner")
            if let action = feedback.action {
                Button(action.title) {
                    model.dismissFeedback(id: feedback.id)
                    action.perform()
                }
                .filledActionButton()
                .frame(minHeight: 44)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityIdentifier(action.identifier)
            }
            if feedback.kind == .error {
                if let retry = feedback.retry {
                    Button("Retry") {
                        model.dismissFeedback(id: feedback.id)
                        retry.action()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.evergreen)
                    .accessibilityIdentifier("app.feedback.retry")
                }
                Button {
                    model.dismissFeedback(id: feedback.id)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("app.feedback.dismiss")
            }
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .padding(.top, 44)
        .allowsHitTesting(feedback.kind == .error || feedback.action != nil)

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
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
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
