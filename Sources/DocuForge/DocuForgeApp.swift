import SwiftUI
import DocuForgeCore

@main
struct DocuForgeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 48))
                    .symbolRenderingMode(.hierarchical)
                Text("DocuForge")
                    .font(.largeTitle.weight(.bold))
                Text("Core \(DocuForgeCore.version)")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 480, minHeight: 320)
            .padding()
        }
        .defaultSize(width: 720, height: 480)
    }
}
