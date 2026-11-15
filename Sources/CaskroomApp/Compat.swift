import SwiftUI

// macOS 15 fallbacks for macOS 26's Liquid Glass. Each one keeps macOS 26's
// look as it is and gives Sequoia what its own apps used before glass.

extension View {
    /// A glass button on macOS 26; on macOS 15 the bordered button Apple's
    /// apps used there (the App Store's Get and Update were these).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

extension AnyTransition {
    /// A symbol drawing itself in on macOS 26; a fade on macOS 15, which has
    /// no draw effect.
    static var drawOn: AnyTransition {
        if #available(macOS 26, *) {
            AnyTransition(.symbolEffect(.drawOn))
        } else {
            .opacity
        }
    }
}
