import ShitsuraeCore
import SwiftUI

struct DiagnosticsView: View {
    let diagnostics: DiagnosticsJSON?
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let diagnostics {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(icon: "waveform.path.ecg", title: "Runtime Summary")
                            HStack(spacing: 10) {
                                LabeledValueBadge(label: "Configured Mode", value: diagnostics.configuredSpaceMode.rawValue)
                                LabeledValueBadge(label: "Effective Mode", value: diagnostics.effectiveSpaceMode.rawValue)
                                if let layout = diagnostics.activeLayoutName {
                                    LabeledValueBadge(label: "Active Layout", value: layout)
                                }
                                if let spaceID = diagnostics.activeVirtualSpaceID {
                                    LabeledValueBadge(label: "Active Space", value: "Space \(spaceID)")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }
}
