import Foundation

/// What makes a finished box or arrow go away.
public enum MarkDismissal: String, CaseIterable, Sendable {
    /// After the "Fade after" seconds.
    case afterTime
    /// When Esc is pressed, however long that takes.
    case onEscape
    /// Whichever comes first.
    case both

    public init(stored: String?) {
        self = MarkDismissal(rawValue: stored ?? "") ?? .afterTime
    }

    public var usesTime: Bool { self != .onEscape }
    public var usesEscape: Bool { self != .afterTime }

    /// When a mark starts fading, or nil while it should stay on screen.
    /// - Parameters:
    ///   - finished: when the drag ended (nil while it is still being drawn).
    ///   - fadeAfter: the seconds it stays when it goes after a time.
    ///   - escaped: when Esc was pressed for it, if it was.
    public func fadeStart(finished: Double?, fadeAfter: Double, escaped: Double?) -> Double? {
        guard let finished else { return nil }
        let timed = usesTime ? finished + fadeAfter : nil
        let esc = usesEscape ? escaped : nil
        switch (timed, esc) {
        case let (t?, e?): return min(t, e)
        case let (t?, nil): return t
        case let (nil, e?): return e
        case (nil, nil): return nil
        }
    }
}
