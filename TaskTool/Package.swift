// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskToolCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TaskToolCore", targets: ["TaskToolCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.4.0"),
        .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2")
    ],
    targets: [
        .target(
            name: "TaskToolCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "libgit2", package: "libgit2")
            ],
            path: "TaskTool",
            exclude: [
                "Assets.xcassets", "ContentView.swift", "Item.swift",
                "MarkdownPreview.swift", "OutlookEmailDrop.swift", "OverviewView.swift",
                "Readability.swift", "SettingsView.swift", "GitSyncSettingsTab.swift", "TaskStore.swift",
                "TaskTool.entitlements", "TaskToolApp.swift"
            ],
            sources: [
                "Task.swift", "Plan.swift", "Settings.swift",
                "MarkdownParser.swift", "TaskSyncMerge.swift", "RepositorySyncMerge.swift",
                "GitHubCredentials.swift", "GitSyncFiles.swift", "EmbeddedGitRepository.swift", "GitSyncClient.swift"
            ]
        ),
        .testTarget(
            name: "TaskToolSyncTests",
            dependencies: ["TaskToolCore"],
            path: "TaskToolSyncTests"
        )
    ]
)
