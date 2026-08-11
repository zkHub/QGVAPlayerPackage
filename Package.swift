// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QGVAPlayer",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(
            name: "QGVAPlayer",
            targets: ["QGVAPlayer"]
        )
    ],
    targets: [
        .target(
            name: "QGVAPlayer",
            path: "Sources/QGVAPlayer",
            sources: [
                "Classes"
            ],
            resources: [
                .process("Shaders/QGHWDShaders.metal")
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GLES_SILENCE_DEPRECATION"),
                .headerSearchPath("Classes"),
                .headerSearchPath("Classes/Controllers"),
                .headerSearchPath("Classes/Controllers/Decoders"),
                .headerSearchPath("Classes/MP4Parser"),
                .headerSearchPath("Classes/Models"),
                .headerSearchPath("Classes/Utils"),
                .headerSearchPath("Classes/Utils/Categorys"),
                .headerSearchPath("Classes/Utils/Logger"),
                .headerSearchPath("Classes/Views"),
                .headerSearchPath("Classes/Views/Metal"),
                .headerSearchPath("Classes/Views/Metal/Vapx"),
                .headerSearchPath("Classes/Views/OpenGL"),
                .headerSearchPath("Shaders")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("GLKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit"),
                .linkedFramework("VideoToolbox")
            ]
        )
    ]
)
