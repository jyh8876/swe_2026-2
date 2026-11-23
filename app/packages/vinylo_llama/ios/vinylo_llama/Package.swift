// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vinylo_llama",
    platforms: [.iOS("16.4")],
    products: [.library(name: "vinylo-llama", targets: ["vinylo_llama"])],
    targets: [
        // Official llama.cpp b11913 build (Metal), the same release as the Android build.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11913/llama-b11913-xcframework.zip",
            checksum: "4daf8f536aeec4f6fac98ef823f31c8c5e79978a83b55a47199076cbfdfe7eb5"
        ),
        // Shared with Android (android/app/src/main/cpp/CMakeLists.txt builds the same file).
        .target(
            name: "VinyloLlmCore",
            dependencies: ["llama"]
        ),
        .target(name: "vinylo_llama", dependencies: ["VinyloLlmCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
