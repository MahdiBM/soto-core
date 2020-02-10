// swift-tools-version:4.1
import PackageDescription

let package = Package(
    name: "AWSSDKSwiftCore",
    products: [
        .library(name: "AWSSDKSwiftCore", targets: ["AWSSDKSwiftCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.14.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "1.3.2"),
        .package(url: "https://github.com/swift-aws/HypertextApplicationLanguage.git", .upToNextMajor(from: "1.1.0")),
        .package(url: "https://github.com/swift-aws/Perfect-INIParser.git", .upToNextMajor(from: "3.0.0")),
    ],
    targets: [
        .target(
            name: "AWSSDKSwiftCore",
            dependencies: [
                "HypertextApplicationLanguage",
                "NIO",
                "NIOHTTP1",
                "NIOOpenSSL",
                "NIOFoundationCompat",
                "INIParser"
            ]),
        .testTarget(name: "AWSSDKSwiftCoreTests", dependencies: ["AWSSDKSwiftCore"])
    ]
)

// switch for whether to use CAWSSDKOpenSSL to shim between OpenSSL versions
#if os(Linux)
let useAWSSDKOpenSSLShim = true
#else
let useAWSSDKOpenSSLShim = false
#endif

// AWSSDKSwiftCore target
let awsSdkSwiftCoreTarget = package.targets.first(where: {$0.name == "AWSSDKSwiftCore"})

// Decide on where we get our SSL support from. Linux usses NIOSSL to provide SSL. Linux also needs CAWSSDKOpenSSL to shim across different OpenSSL versions for the HMAC functions.
if useAWSSDKOpenSSLShim {
    package.targets.append(.target(name: "CAWSSDKOpenSSL"))
    awsSdkSwiftCoreTarget?.dependencies.append("CAWSSDKOpenSSL")
    package.dependencies.append(.package(url: "https://github.com/apple/swift-nio-ssl-support.git", from: "1.0.0"))
}
