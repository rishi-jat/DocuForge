import SwiftUI
import DocuForgeCore

struct BatchView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "hammer",
            description: Text("BatchView will be wired to DocuForgeCore services.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
