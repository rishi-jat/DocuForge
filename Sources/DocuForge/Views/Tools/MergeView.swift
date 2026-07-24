import SwiftUI
import DocuForgeCore

struct MergeView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "hammer",
            description: Text("MergeView will be wired to DocuForgeCore services.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
