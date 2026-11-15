import SwiftUI

/// Caskroom's motion in one place: short system springs, used only where brew or
/// the user changed something. Animation lives in views, keyed to the value that
/// changed, never in BrewStore.
enum Motion {
    /// State changes: a button's phase, a banner, a logo arriving.
    static let standard: Animation = .smooth(duration: 0.3)
    /// Small swaps: labels and counters.
    static let quick: Animation = .snappy(duration: 0.2)
    /// Liquid Glass reshaping: a little overshoot so glass stretches and splits
    /// like liquid. A plain ease under Reduce Motion.
    static func liquid(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .bouncy(duration: 0.45, extraBounce: 0.08)
    }

    /// Rows moving in and out of a list. None under Reduce Motion: a row sliding
    /// between sections is exactly the movement it asks to drop.
    static func list(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : standard
    }
}

extension AnyTransition {
    /// Moves in from `edge`, or only fades under Reduce Motion.
    static func move(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}
