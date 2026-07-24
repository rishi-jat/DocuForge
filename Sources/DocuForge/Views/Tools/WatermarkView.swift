import SwiftUI
import DocuForgeCore

struct WatermarkView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "hammer",
            description: Text("WatermarkView will be wired to DocuForgeCore services.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
