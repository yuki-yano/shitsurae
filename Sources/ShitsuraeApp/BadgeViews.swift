import SwiftUI

struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

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
