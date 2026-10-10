import CoreGraphics

// MARK: - Snap Point

/// Which side of the Mini pill its attached panel opens on.
enum AuxPin: Equatable {
    case above
    case below
}

/// One place the Mini pill can rest: a column and row on one screen.
struct SnapPoint: Equatable, Identifiable {
    enum Column: Equatable {
        case left, center, right
    }

    enum Row: Equatable {
        case bottom, center, top
    }

    /// Stable while the screen list stays the same:
    /// `screenIndex * SnapGrid.pointsPerScreen + cell`.
    let id: Int
    let screenIndex: Int
    let column: Column
    let row: Row
    /// The screen's visible frame (menu bar and Dock excluded).
    let screen: CGRect

    /// Top-row points open the attached panel below the pill; the others
    /// open it above.
    var auxPin: AuxPin { row == .top ? .below : .above }
}

// MARK: - Snap Grid

/// The Mini pill's snap points and the math around them. Pure, so tests
/// drive it with plain rectangles. [UI]
enum SnapGrid {

    /// Every screen gets the same nine cells.
    static let pointsPerScreen = 9

    /// Gap between the pill and the screen edge, in points.
    static let margin: CGFloat = 20

    /// A dragged pill this close to a point (center to center) shows that
    /// point as engaged.
    static let engageDistance: CGFloat = 30

    /// Gap between the pill and its attached panel.
    static let auxGap: CGFloat = 8

    /// Cell order inside a screen. Bottom center comes first, so the default
    /// id 0 puts the pill at the bottom center of the first screen.
    static let cells: [(column: SnapPoint.Column, row: SnapPoint.Row)] = [
        (.center, .bottom), (.left, .bottom), (.right, .bottom),
        (.left, .center), (.center, .center), (.right, .center),
        (.left, .top), (.center, .top), (.right, .top),
    ]

    /// All points on `screens` (visible frames, in `NSScreen.screens` order).
    static func points(screens: [CGRect]) -> [SnapPoint] {
        screens.enumerated().flatMap { screenIndex, screen in
            cells.enumerated().map { cell, position in
                SnapPoint(
                    id: screenIndex * pointsPerScreen + cell,
                    screenIndex: screenIndex,
                    column: position.column,
                    row: position.row,
                    screen: screen
                )
            }
        }
    }

    /// The point with `id`, or the first point when that id no longer exists
    /// (its screen was unplugged). Nil only when there are no points.
    static func resolve(id: Int, in points: [SnapPoint]) -> SnapPoint? {
        points.first { $0.id == id } ?? points.first
    }

    /// Bottom-left corner of a pill of `size` resting at `point`, kept
    /// inside the screen.
    static func origin(of point: SnapPoint, size: CGSize, margin: CGFloat = margin) -> CGPoint {
        let screen = point.screen
        let x: CGFloat
        switch point.column {
        case .left: x = screen.minX + margin
        case .center: x = screen.midX - size.width / 2
        case .right: x = screen.maxX - margin - size.width
        }
        let y: CGFloat
        switch point.row {
        case .bottom: y = screen.minY + margin
        case .center: y = screen.midY - size.height / 2
        case .top: y = screen.maxY - margin - size.height
        }
        return RecorderViewModel.clamp(origin: CGPoint(x: x, y: y), size: size, into: screen)
    }

    /// Center of a pill of `size` resting at `point`.
    static func center(of point: SnapPoint, size: CGSize) -> CGPoint {
        let origin = origin(of: point, size: size)
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    /// The point nearest a pill of `size` whose center is at `center`.
    static func nearest(to center: CGPoint, size: CGSize, in points: [SnapPoint]) -> SnapPoint? {
        points.min { distance(center, self.center(of: $0, size: size)) < distance(center, self.center(of: $1, size: size)) }
    }

    /// Whether a pill centered at `center` is close enough to `point` to
    /// show it as engaged.
    static func isEngaged(_ point: SnapPoint, center: CGPoint, size: CGSize) -> Bool {
        distance(center, self.center(of: point, size: size)) <= engageDistance
    }

    /// Bottom-left corner of the attached panel: centered on the pill, above
    /// or below it by `pin`, kept inside `screen`.
    static func auxOrigin(pill: CGRect, auxSize: CGSize, pin: AuxPin, screen: CGRect, gap: CGFloat = auxGap) -> CGPoint {
        let x = pill.midX - auxSize.width / 2
        let y: CGFloat
        switch pin {
        case .above: y = pill.maxY + gap
        case .below: y = pill.minY - gap - auxSize.height
        }
        return RecorderViewModel.clamp(origin: CGPoint(x: x, y: y), size: auxSize, into: screen)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
