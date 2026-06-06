# InspectorPasteApp

A tiny macOS app: **paste an XState machine definition (JSON) on the left, see it load into the
native SwiftXState Inspector on the right.** No running machine and no WebSocket/Stately relay —
the graph and the initial state are reconstructed directly from the pasted definition.

These are **source files only** — wire them into your own Xcode project (so your dev credentials /
signing stay yours).

## Files

| File | Role |
|------|------|
| `InspectorPasteApp.swift` | `@main` App entry point |
| `ContentView.swift` | `HSplitView` of `InspectorPasteView` ⟷ `MachineInspectorView` over one shared `InspectorStore` |
| `SampleMachines.swift` | Two ready-to-paste samples (traffic light, parallel editor) |

The reusable pieces live in the package, not here:
- `InspectorPasteView` — the paste pane (editor + Load button + error reporting)
- `MachineDefinitionImporter` / `InspectorStore.loadDefinition(json:)` — the JSON → inspector bridge

## Wiring it up in Xcode

1. **File ▸ New ▸ Project… ▸ macOS ▸ App.** Name it `InspectorPasteApp`, interface **SwiftUI**,
   language **Swift**. Delete the auto-generated `ContentView.swift` and `…App.swift`.
2. **Add the SwiftXState package**: File ▸ Add Package Dependencies… ▸ *Add Local…* and pick this
   repo's root (`swift-xstate/`). Add these three library products to the app target:
   - `SwiftXState`
   - `SwiftXStateGraph`
   - `SwiftXStateInspectorUI`
3. **Drag the four `.swift` files in this folder** into the app target (check *Copy items if
   needed* or reference in place — your call).
4. **Build & run.** macOS 14+. No special entitlements needed (no networking).

> The `SWIFTXSTATE_INSPECTOR_UI` / `SWIFTXSTATE_GRAPH_UI` compile flags are already enabled inside
> the package for Apple platforms, so there's nothing extra to set in Xcode.

## Using it

- The editor starts pre-filled with the traffic-light sample. Hit **Load into Inspector**
  (or ⌘↩) to parse it.
- Paste any XState machine definition — e.g. the JSON from `try machine.definitionJSON()`, or an
  XState config object. The **Graph** tab renders the structure; the **State** tab shows the
  initial state value and the top-level `context`.
- Paste a different machine and Load again to replace it.

### What loads

| Tab | From a static definition |
|-----|--------------------------|
| **Graph** | ✅ full structure (states, transitions, nested/parallel regions) |
| **State** | ✅ initial state value + initial `context` |
| **Events** / **Sequence** | ➖ empty — there's no live run (guards/actions are code, not data) |

To get a *live* event feed you'd drive a real running actor through `InspectorStore.observe()`
(as the SwiftXChess example does). A structural "click events to step the state" simulator on top
of a pasted definition is a natural next addition.
