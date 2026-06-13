import JavaScriptKit

/// Tiny DOM convenience layer over JavaScriptKit. Everything the inspector draws goes through here,
/// so the view code reads like building a tree rather than juggling `JSValue`s.
@MainActor
enum DOM {
    static var document: JSValue { JSObject.global.document }

    /// Event-listener closures must outlive the call that registers them, or JS calls back into freed
    /// memory. We keep every one alive for the life of the page (the inspector is long-lived).
    static var retained: [JSClosure] = []

    /// Create an element, optionally with a class and text content.
    @discardableResult
    static func el(_ tag: String, _ cls: String? = nil, text: String? = nil) -> JSValue {
        let e = document.createElement(tag)
        if let cls { e.className = .string(cls) }
        if let text { e.textContent = .string(text) }
        return e
    }

    @discardableResult
    static func append(_ parent: JSValue, _ children: JSValue...) -> JSValue {
        for child in children { _ = parent.appendChild(child) }
        return parent
    }

    static func removeAllChildren(_ e: JSValue) {
        e.innerHTML = .string("")
    }

    static func onClick(_ e: JSValue, _ handler: @escaping () -> Void) {
        let closure = JSClosure { _ in
            MainActor.assumeIsolated { handler() }
            return .undefined
        }
        retained.append(closure)
        _ = e.addEventListener("click", closure)
    }

    static func byId(_ id: String) -> JSValue {
        document.getElementById(id)
    }

    /// Inject a `<style>` block into `<head>` once.
    static func injectStyle(_ css: String) {
        let style = document.createElement("style")
        style.textContent = .string(css)
        _ = document.head.appendChild(style)
    }

    /// Set an inline style string on an element.
    static func style(_ e: JSValue, _ css: String) {
        _ = e.setAttribute("style", css)
    }
}
