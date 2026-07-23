import SwiftUI

struct SupertonicLegalView: View {
    private let licenseText = Self.bundledText(named: "SUPERTONIC_MODEL_OPENRAIL-M", extension: "txt")
    private let noticesText = Self.bundledText(named: "THIRD_PARTY_NOTICES", extension: "txt")

    var body: some View {
        List {
            Section("On-Device Voice") {
                Text("Voice synthesized on-device. Spoken text comes from your selected source.")
                Text("Spoken Margins bundles the Supertonic 3 model and official preset styles. Voice synthesis runs locally and does not send spoken text to Supertone.")
            }

            Section("OpenRAIL-M paragraph 5") {
                Text("Use is limited to lawful purposes. The model and its output must not be used to harm or exploit minors; spread harmful falsehoods or harmful personal information; defame, harass, discriminate, or impersonate without consent; make adverse automated legal decisions; provide medical advice; or support the prohibited justice, law-enforcement, immigration, or asylum uses in Attachment A.")
                Text("Machine-generated content must be disclosed intelligibly when it is distributed. You remain responsible for the source text and synthesized output.")
            }

            Section("Complete OpenRAIL-M model license") {
                Text(licenseText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("Third-party notices") {
                Text(noticesText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                NavigationLink("Supertone code · MIT") {
                    BundledLicenseDocumentView(
                        title: "Supertone MIT License",
                        resourceName: "SUPERTONIC_CODE_MIT"
                    )
                }
                NavigationLink("ONNX Runtime · MIT") {
                    BundledLicenseDocumentView(
                        title: "ONNX Runtime MIT License",
                        resourceName: "ONNXRUNTIME_MIT"
                    )
                }
                NavigationLink("ONNX Runtime · Third-Party Notices") {
                    BundledLicenseDocumentView(
                        title: "ONNX Runtime Notices",
                        resourceName: "ONNXRUNTIME_THIRD_PARTY_NOTICES"
                    )
                }
                NavigationLink("sherpa-onnx · Apache 2.0") {
                    BundledLicenseDocumentView(
                        title: "sherpa-onnx License",
                        resourceName: "SHERPA_ONNX_APACHE-2.0"
                    )
                }
            }
        }
        .navigationTitle("On-Device Voice")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal.supertonic.screen")
    }

    static func bundledText(named name: String, extension fileExtension: String) -> String {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Supertonic/licenses"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "Bundled notice unavailable."
        }
        return contents
    }
}

private struct BundledLicenseDocumentView: View {
    let title: String
    let resourceName: String

    var body: some View {
        ScrollView {
            Text(SupertonicLegalView.bundledText(named: resourceName, extension: "txt"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
