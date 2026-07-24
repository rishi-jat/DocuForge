// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocuForge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DocuForge", targets: ["DocuForge"]),
        .executable(name: "DocuForgeVerify", targets: ["DocuForgeVerify"]),
        .library(name: "DocuForgeCore", targets: ["DocuForgeCore"])
    ],
    targets: [
        .target(
            name: "DocuForgeCore",
            path: "Sources/DocuForgeCore"
        ),
        .executableTarget(
            name: "DocuForge",
            dependencies: ["DocuForgeCore"],
            path: "Sources/DocuForge"
        ),
        .executableTarget(
            name: "DocuForgeVerify",
            dependencies: ["DocuForgeCore"],
            path: "Sources/DocuForgeVerify"
        )
    ]
)
