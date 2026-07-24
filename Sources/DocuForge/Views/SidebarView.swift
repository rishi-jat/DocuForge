import SwiftUI
import DocuForgeCore

struct SidebarView: View {
    @Binding var selection: ToolKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text("Tools")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

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
                            }
                            .tag(tool)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Text("Offline-first · local processing")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colorScheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color(nsColor: .windowBackgroundColor))
    }
}
