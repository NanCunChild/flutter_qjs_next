// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_qjs_next",
    platforms: [
        .iOS("12.0"),
    ],
    products: [
        .library(name: "flutter-qjs-next", targets: ["flutter_qjs_next"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "flutter_qjs_next",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/flutter_qjs_next",
            exclude: [
                "quickjs/VERSION",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("quickjs"),
                .define("CONFIG_VERSION", to: "\"2026-06-04\""),
                .define("DUMP_LEAKS", to: "1", .when(configuration: .debug)),
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("quickjs"),
                .define("CONFIG_VERSION", to: "\"2026-06-04\""),
                .define("DUMP_LEAKS", to: "1", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        )
    ]
)
