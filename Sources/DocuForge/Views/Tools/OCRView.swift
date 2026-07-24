import SwiftUI
import DocuForgeCore

struct OCRView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "hammer",
            description: Text("OCRView will be wired to DocuForgeCore services.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
