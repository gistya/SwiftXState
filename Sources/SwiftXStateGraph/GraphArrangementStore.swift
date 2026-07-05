#if SWIFTXSTATE_GRAPH_UI
import CoreGraphics
import Foundation

/// Persists a graph's manual node/edge arrangement (drag offsets) across inspector reopens, keyed by
/// the machine id. The inspector rebuilds a fresh `GraphRenderModel` every time it's opened or a
/// different actor is selected, which used to drop any hand-arrangement; this remembers it.
///
/// Stored in `UserDefaults` (small JSON blob per machine) — the natural zero-dependency persistent
/// store for a library. Keyed by machine id so it survives across runs; a machine seen only under a
/// per-run session id won't persist across launches, which is the best that can be done without one.
public enum GraphArrangementStore {
    /// Turn persistence off globally (e.g. for tests or a consumer that manages its own storage).
    /// A benign config toggle — `nonisolated(unsafe)` because a data race on it can't corrupt anything.
    public nonisolated(unsafe) static var isEnabled = true

    private struct Saved: Codable {
        var nodes: [String: [Double]]
        var edges: [String: [Double]]
    }

    private static func defaultsKey(_ machineID: String) -> String {
        "SwiftXStateGraph.arrangement.\(machineID)"
    }

    static func load(_ machineID: String) -> (nodes: [String: CGSize], edges: [String: CGSize]) {
        guard isEnabled, !machineID.isEmpty,
              let data = UserDefaults.standard.data(forKey: defaultsKey(machineID)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return ([:], [:]) }
        func sizes(_ dict: [String: [Double]]) -> [String: CGSize] {
            var out: [String: CGSize] = [:]
            for (key, value) in dict where value.count == 2 {
                out[key] = CGSize(width: value[0], height: value[1])
            }
            return out
        }
        return (sizes(saved.nodes), sizes(saved.edges))
    }

    static func save(_ machineID: String, nodes: [String: CGSize], edges: [String: CGSize]) {
        guard isEnabled, !machineID.isEmpty else { return }
        // Nothing to remember → drop the key so we don't accumulate empty blobs.
        if nodes.isEmpty, edges.isEmpty { clear(machineID); return }
        func doubles(_ dict: [String: CGSize]) -> [String: [Double]] {
            dict.mapValues { [Double($0.width), Double($0.height)] }
        }
        let saved = Saved(nodes: doubles(nodes), edges: doubles(edges))
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey(machineID))
        }
    }

    static func clear(_ machineID: String) {
        guard !machineID.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey(machineID))
    }
}
#endif
