import SwiftUI
import DocuForgeCore

struct PageManageView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "hammer",
            description: Text("PageManageView will be wired to DocuForgeCore services.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
