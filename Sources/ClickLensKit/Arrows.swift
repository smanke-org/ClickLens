import CoreGraphics
import Foundation

/// The arrow styles ClickLens can draw.
public enum ArrowShape: String, CaseIterable, Sendable {
    /// A straight line with a solid triangular head.
    case classic
    /// A straight line with an open, chevron head.
    case open
    /// A gentle curve with a solid head.
    case curved
    /// Solid heads at both ends.
    case double
    /// A single solid block shape, like a sign.
    case block

    public var title: String {
        switch self {
        case .classic: "Classic"
        case .open: "Open"
        case .curved: "Curved"
        case .double: "Double"
        case .block: "Block"
        }
    }
}

/// How an arrow is painted. Kept as two paths because filling the line too would
/// fill the area under a curve.
public struct ArrowPath {
    /// Stroked only: the shaft, and an open arrow's chevron.
    public var line: CGPath
    /// Filled (and stroked, so its corners round off like the line's): the heads, or the
    /// whole block arrow.
    public var head: CGPath
    /// The stroke width to draw with.
    public var lineWidth: CGFloat

    /// Both parts together, for measuring.
    public var path: CGPath {
        let both = CGMutablePath()
        both.addPath(line)
        both.addPath(head)
        return both
    }
}

public enum ArrowGeometry {
    /// The head's length and half-width for a line of `thickness`. Grows with the line
    /// but never so small that the head disappears on a thin one.
    static func head(_ thickness: CGFloat) -> (length: CGFloat, halfWidth: CGFloat) {
        (thickness * 3.2 + 10, thickness * 2.0 + 6)
    }

    /// The arrow from `tail` to `tip`.
    public static func path(from tail: CGPoint, to tip: CGPoint, shape: ArrowShape, thickness: CGFloat) -> ArrowPath {
        let path = CGMutablePath()   // the line
        let heads = CGMutablePath()
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let (headLength, headHalf) = head(thickness)
        // Keep heads from overrunning a very short arrow.
        let headL = min(headLength, length * 0.6)

        switch shape {
        case .classic:
            let dir = CGVector(dx: dx / length, dy: dy / length)
            addHead(to: heads, tip: tip, direction: dir, length: headL, halfWidth: headHalf)
            path.move(to: tail)
            // The line stops inside the head, so its round cap never pokes out of the tip.
            path.addLine(to: point(tip, dir, -headL * 0.6))
            return ArrowPath(line: path, head: heads, lineWidth: thickness)

        case .double:
            let dir = CGVector(dx: dx / length, dy: dy / length)
            let back = CGVector(dx: -dir.dx, dy: -dir.dy)
            let l = min(headLength, length * 0.4)
            addHead(to: heads, tip: tip, direction: dir, length: l, halfWidth: headHalf)
            addHead(to: heads, tip: tail, direction: back, length: l, halfWidth: headHalf)
            path.move(to: point(tail, dir, l * 0.6))
            path.addLine(to: point(tip, dir, -l * 0.6))
            return ArrowPath(line: path, head: heads, lineWidth: thickness)

        case .open:
            let dir = CGVector(dx: dx / length, dy: dy / length)
            let normal = CGVector(dx: -dir.dy, dy: dir.dx)
            let base = point(tip, dir, -headL)
            path.move(to: tail)
            path.addLine(to: tip)
            path.move(to: CGPoint(x: base.x + normal.dx * headHalf, y: base.y + normal.dy * headHalf))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: base.x - normal.dx * headHalf, y: base.y - normal.dy * headHalf))
            return ArrowPath(line: path, head: heads, lineWidth: thickness)

        case .curved:
            // Bow the line to one side by a fifth of its length.
            let mid = CGPoint(x: (tail.x + tip.x) / 2, y: (tail.y + tip.y) / 2)
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            let control = CGPoint(x: mid.x + normal.dx * length * 0.2, y: mid.y + normal.dy * length * 0.2)
            // The head follows the curve's direction where it arrives at the tip.
            let tx = tip.x - control.x, ty = tip.y - control.y
            let tl = max((tx * tx + ty * ty).squareRoot(), 0.001)
            let dir = CGVector(dx: tx / tl, dy: ty / tl)
            addHead(to: heads, tip: tip, direction: dir, length: headL, halfWidth: headHalf)
            path.move(to: tail)
            path.addQuadCurve(to: point(tip, dir, -headL * 0.6), control: control)
            return ArrowPath(line: path, head: heads, lineWidth: thickness)

        case .block:
            let dir = CGVector(dx: dx / length, dy: dy / length)
            let normal = CGVector(dx: -dir.dy, dy: dir.dx)
            let shaftHalf = thickness * 1.4 + 3
            let blockHead = min(headLength * 1.3, length * 0.6)
            let half = headHalf * 1.35
            let base = point(tip, dir, -blockHead)
            func off(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + normal.dx * d, y: p.y + normal.dy * d) }
            path.move(to: off(tail, shaftHalf))
            path.addLine(to: off(base, shaftHalf))
            path.addLine(to: off(base, half))
            path.addLine(to: tip)
            path.addLine(to: off(base, -half))
            path.addLine(to: off(base, -shaftHalf))
            path.addLine(to: off(tail, -shaftHalf))
            path.closeSubpath()
            return ArrowPath(line: CGMutablePath(), head: path, lineWidth: 1)
        }
    }

    private static func point(_ p: CGPoint, _ d: CGVector, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: p.x + d.dx * distance, y: p.y + d.dy * distance)
    }

    private static func addHead(to path: CGMutablePath, tip: CGPoint, direction d: CGVector, length: CGFloat, halfWidth: CGFloat) {
        let base = point(tip, d, -length)
        let n = CGVector(dx: -d.dy, dy: d.dx)
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + n.dx * halfWidth, y: base.y + n.dy * halfWidth))
        path.addLine(to: CGPoint(x: base.x - n.dx * halfWidth, y: base.y - n.dy * halfWidth))
        path.closeSubpath()
    }
}
