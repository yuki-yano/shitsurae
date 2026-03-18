import SwiftUI

struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}
