// swift-tools-version:6.0
import PackageDescription

let grammarNames = [
    "bash", "css", "go", "html", "javascript", "json",
    "python", "rust", "swift", "tsx", "typescript", "yaml",
]

func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

var targets: [Target] = [
    .target(
        name: "CTreeSitter",
        publicHeadersPath: "include",
        cSettings: [.headerSearchPath(".")]
    ),
]

for g in grammarNames {
    targets.append(
        .target(
            name: "CGrammar\(cap(g))",
            path: "Sources/CGrammars/\(g)",
            exclude: g == "yaml" ? ["src/schema.core.c"] : [],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        )
    )
}

targets += [
    .target(
        name: "SwctxCore",
        dependencies: ["CTreeSitter"]
            + grammarNames.map { .target(name: "CGrammar\(cap($0))") }
            + [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
    ),
    .executableTarget(
        name: "swctx",
        dependencies: [
            "SwctxCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(name: "SwctxCoreTests", dependencies: ["SwctxCore"]),
]

let package = Package(
    name: "swctx",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "swctx", targets: ["swctx"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.10.0"),
    ],
    targets: targets,
    cLanguageStandard: .c11
)
