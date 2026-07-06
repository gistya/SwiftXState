#if SWIFTXSTATE_GRAPH_UI
import Testing
import Foundation
@testable import SwiftXStateGraph

/// The 3D `defaultNodeSpacing` curve and the localized "Spacing:" toolbar label.
@Suite("3D spacing")
struct SpacingTests {
    @Test("defaultNodeSpacing stays 1 for small graphs, grows logarithmically, and clamps")
    func defaultSpacingCurve() {
        // At or under the comfortable threshold (6 elements) → no extra spread.
        #expect(GraphRenderModel.defaultNodeSpacing(nodeCount: 2, edgeCount: 1) == 1)
        #expect(GraphRenderModel.defaultNodeSpacing(nodeCount: 3, edgeCount: 3) == 1)

        // A busy machine (swiftbuilder-ish: ~6 nodes, ~14 edges) spreads out moderately.
        let mid = GraphRenderModel.defaultNodeSpacing(nodeCount: 6, edgeCount: 14)
        #expect(mid > 1 && mid < 3)

        // Non-decreasing in complexity.
        #expect(GraphRenderModel.defaultNodeSpacing(nodeCount: 40, edgeCount: 40)
                > GraphRenderModel.defaultNodeSpacing(nodeCount: 10, edgeCount: 10))

        // Logarithmic: each *doubling* of complexity adds the same increment (not proportional growth).
        let s20 = GraphRenderModel.defaultNodeSpacing(nodeCount: 10, edgeCount: 10)  // 20 elements
        let s40 = GraphRenderModel.defaultNodeSpacing(nodeCount: 20, edgeCount: 20)  // 40
        let s80 = GraphRenderModel.defaultNodeSpacing(nodeCount: 40, edgeCount: 40)  // 80
        #expect(abs((s40 - s20) - (s80 - s40)) < 0.001)

        // Clamped at the ceiling for very large graphs.
        #expect(GraphRenderModel.defaultNodeSpacing(nodeCount: 5000, edgeCount: 5000) == 5)
    }

    @Test("The Spacing label ships translated in the module's String Catalog")
    func spacingLabelLocalized() throws {
        // The `.xcstrings` is bundled with the module (Xcode compiles it to .lproj when it builds the
        // package for the app; command-line SwiftPM only copies it, so we validate the catalog content
        // — the source of truth — rather than a runtime lookup).
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
                               "Localizable.xcstrings is not bundled with SwiftXStateGraph")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let locs = try #require((strings["Spacing:"] as? [String: Any])?["localizations"] as? [String: Any],
                                "no localized 'Spacing:' entry")
        func value(_ lang: String) -> String? {
            ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(value("en") == "Spacing:")
        #expect(value("de") == "Abstand:")
        #expect(value("ja") == "間隔:")
        // We ship a real set of translations, and none is left blank.
        #expect(locs.count >= 8)
        for (lang, _) in locs { #expect(value(lang)?.isEmpty == false, "blank translation for \(lang)") }
    }
}
#endif
