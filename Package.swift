// swift-tools-version:6.0
import PackageDescription

// Every C++/ObjC++ target must agree on NDEBUG: CEF's refcount and thread-checker
// classes change layout when DCHECK_IS_ON(), so a mix breaks the ABI.
let cefDefines: [CXXSetting] = [
  .define("NDEBUG"),
  .define("WRAPPING_CEF_SHARED"),
  .define("__STDC_CONSTANT_MACROS"),
  .define("__STDC_FORMAT_MACROS"),
]
// Warnings from upstream CEF template code are noise we cannot fix.
let wrapperCxx: [CXXSetting] =
  [.headerSearchPath("cef"), .unsafeFlags(["-Wno-undefined-var-template"])] + cefDefines
let clientCxx: [CXXSetting] = [.headerSearchPath("../CEFWrapper/cef")] + cefDefines

let package = Package(
  name: "Barestate",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Barestate", targets: ["Barestate"]),
    .executable(name: "BarestateHelper", targets: ["BarestateHelper"]),
    .executable(name: "barestate-mcp", targets: ["barestate-mcp"]),
    .executable(name: "barestate-gateway", targets: ["barestate-gateway"]),
  ],
  targets: [
    // libcef_dll_wrapper. cef/include and cef/libcef_dll are symlinks into Vendor/.
    .target(
      name: "CEFWrapper",
      path: "Sources/CEFWrapper",
      sources: [
        "cef/libcef_dll/shutdown_checker.cc",
        "cef/libcef_dll/transfer_util.cc",
        "cef/libcef_dll/base",
        "cef/libcef_dll/cpptoc",
        "cef/libcef_dll/ctocpp",
        "cef/libcef_dll/wrapper",
        "keep.cc",
      ],
      publicHeadersPath: "public",
      cxxSettings: wrapperCxx
    ),
    .target(
      name: "CEFBridge",
      dependencies: ["CEFWrapper"],
      cxxSettings: clientCxx,
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOSurface"),
      ]
    ),
    .executableTarget(
      name: "BarestateHelper",
      dependencies: ["CEFWrapper"],
      cxxSettings: clientCxx
    ),
    .target(name: "BarestateCore"),
    .executableTarget(
      name: "Barestate",
      dependencies: ["CEFBridge", "BarestateCore"]
    ),
    .executableTarget(name: "barestate-mcp"),
    .executableTarget(name: "barestate-gateway", dependencies: ["BarestateCore"]),
    .testTarget(
      name: "BarestateCoreTests",
      dependencies: ["BarestateCore"],
      resources: [.copy("Fixtures")]
    ),
  ],
  cxxLanguageStandard: .cxx20
)
