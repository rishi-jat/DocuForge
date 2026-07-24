import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DocuForgeCore

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let allowedTypes: [UTType]
    let allowsMultiple: Bool
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary.opacity(0.75))

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Choose Files…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = allowsMultiple
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = allowedTypes.isEmpty ? [.item] : allowedTypes
                if panel.runModal() == .OK {
                    onDrop(panel.urls)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : borderColor,
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: isTargeted ? [] : [10, 7])
                )
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 12, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                let urls = await Self.resolveURLs(from: providers)
                let filtered = urls.filter { url in
                    guard !allowedTypes.isEmpty else { return true }
                    let type = UTType(filenameExtension: url.pathExtension) ?? .data
                    return allowedTypes.contains { type.conforms(to: $0) || $0.conforms(to: type) }
                        || allowedTypes.contains(.item)
                        || allowedTypes.contains(.data)
                }
                if !filtered.isEmpty {
                    await MainActor.run {
                        onDrop(allowsMultiple ? filtered : Array(filtered.prefix(1)))
                    }
                }
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private var fillColor: Color {
        if isTargeted {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
        }
        // Elevated surface so drop zones never blend into the window in dark mode.
        return colorScheme == .dark
            ? Color(nsColor: .alternatingContentBackgroundColors.last ?? .controlBackgroundColor)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.28)
            : Color.primary.opacity(0.18)
    }

    private static func resolveURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await withCheckedContinuation({ (cont: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    cont.resume(returning: object)
                }
            }) {
                urls.append(url)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { cont in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data,
                           let path = String(data: data, encoding: .utf8),
                           let url = URL(string: path) {
                            cont.resume(returning: url)
                        } else if let url = item as? URL {
                            cont.resume(returning: url)
                        } else {
                            cont.resume(returning: nil)
                        }
                    }
                }
                if let url { urls.append(url) }
            }
        }
        return urls
    }
}
