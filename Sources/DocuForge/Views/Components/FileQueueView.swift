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
                // Avoid List-in-ScrollView layout collapse on macOS.
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                            Spacer(minLength: 0)
                            if index > 0 {
                                Button {
                                    items.swapAt(index, index - 1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .help("Move up")
                            }
                            if index < items.count - 1 {
                                Button {
                                    items.swapAt(index, index + 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .help("Move down")
                            }
                            Button(role: .destructive) {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if index < items.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func icon(for format: DocumentFormat) -> String {
        if format.isPDF { return "doc.richtext" }
        if format.isImage { return "photo" }
        if format.isOfficeOpenXML { return "doc.text" }
        return "doc"
    }
}
