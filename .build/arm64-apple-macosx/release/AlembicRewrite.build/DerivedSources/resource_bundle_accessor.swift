import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("AlembicRewrite_AlembicRewrite.bundle").path
        let buildPath = "/Users/jean-lucalder/Desktop/Claude/prompt-rewriter/.build/arm64-apple-macosx/release/AlembicRewrite_AlembicRewrite.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}