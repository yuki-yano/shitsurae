import ShitsuraeCore
import SwiftUI

struct LabeledValueBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct BooleanStatusBadge: View {
    let value: Bool

    var body: some View {
        Text(value ? "ON" : "OFF")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                value ? Color.green.opacity(0.15) : Color.gray.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(value ? .green : .secondary)
    }
}

struct SpaceMoveMethodBadge: View {
    let method: SpaceMoveMethod

    var body: some View {
        Text(method.rawValue)
            .font(.system(.caption, design: .monospaced).bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                method == .drag ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(method == .drag ? .blue : .orange)
    }
}
