import Foundation

enum KeyboardCursorFollow {
    /// Dead-zone tracking in viewport points. Changes the view, never the cursor.
    static func nextOffset(cursor: CGPoint, content: CGRect, viewport: CGSize,
                           scale: CGFloat, offset: CGSize, visibleTop: CGFloat,
                           visibleBottom: CGFloat, travel: CGSize, immediate: Bool = false) -> CGSize {
        guard cursor.x.isFinite, cursor.y.isFinite, scale.isFinite,
              visibleBottom > visibleTop else { return offset }
        let x = viewport.width / 2 + (cursor.x - 0.5) * content.width * scale + offset.width
        let y = viewport.height / 2 + (cursor.y - 0.5) * content.height * scale + offset.height
        let margin = min(36, (visibleBottom - visibleTop) / 4)
        let dy = y < visibleTop + margin ? visibleTop + margin - y
            : y > visibleBottom - margin ? visibleBottom - margin - y : 0
        let dx = x < 24 ? 24 - x : x > viewport.width - 24 ? viewport.width - 24 - x : 0
        let target = CGSize(width: min(travel.width, max(-travel.width, offset.width + dx)),
                            height: min(travel.height, max(-travel.height, offset.height + dy)))
        let fraction: CGFloat = immediate ? 1 : 0.3
        func step(_ current: CGFloat, _ target: CGFloat) -> CGFloat {
            abs(target - current) < 0.5 ? target : current + (target - current) * fraction
        }
        return CGSize(width: step(offset.width, target.width), height: step(offset.height, target.height))
    }
}
