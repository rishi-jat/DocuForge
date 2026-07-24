import SwiftUI
import DocuForgeCore

struct SidebarView: View {
    @Binding var selection: ToolKind

    var body: some View {
        List(selection: $selection) {
            ForEach(ToolSection.allCases) { section in
                Section(section.title) {
                    ForEach(ToolKind.allCases.filter { $0.section == section }) { tool in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title)
                                Text(tool.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: tool.systemImage)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(tool)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start with Edit")
                    .font(.caption.weight(.semibold))
                Text("Open a file to change text, pages, or screenshots. Convert uses Pages/Keynote when installed so layouts stay intact.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }
}
