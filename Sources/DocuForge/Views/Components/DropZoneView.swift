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
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(isTargeted ? Color.accentColor : (colorScheme == .dark ? Color.white : Color.black.opacity(0.75)))

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.25))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

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
        .padding(36)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : borderStroke,
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [9, 6])
                )
        )
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
    }

    private var surfaceFill: Color {
        if isTargeted {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.12)
        }
        // Explicit RGB so dark mode never blends into the window.
        return colorScheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color(red: 0.93, green: 0.93, blue: 0.95)
    }

    private var borderStroke: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
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
                           let u = URL(string: path) {
                            cont.resume(returning: u)
                        } else if let u = item as? URL {
                            cont.resume(returning: u)
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
