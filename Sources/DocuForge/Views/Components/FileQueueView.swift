import SwiftUI
import DocuForgeCore

struct FileQueueView: View {
    @Binding var items: [DocumentItem]
    var emptyMessage: String = "No files yet"
    var showsPageCount: Bool = false

    var body: some View {
        Group {
            if items.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item.format))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(item.format.displayName)
                                    Text("·")
                                    Text(item.formattedSize)
                                    if showsPageCount, let pages = item.pageCount {
                                        Text("·")
                                        Text("\(pages) pages")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { indices, newOffset in
                        items.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func icon(for format: DocumentFormat) -> String {
        if format.isPDF { return "doc.richtext" }
        if format.isImage { return "photo" }
        if format.isOfficeOpenXML { return "doc.text" }
        return "doc"
    }
}
