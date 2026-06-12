import CoreGraphics
import Foundation

/// Pure frame computation for snap presets (leftHalf / rightThird / …).
/// The basis is the display's visible frame in CG coordinates.
public enum SnapPresetResolver {
    public static func frame(for preset: SnapPreset, basis: CGRect) -> ResolvedFrame {
        let x = basis.origin.x
        let y = basis.origin.y
        let width = basis.width
        let height = basis.height

        switch preset {
        case .leftHalf:
            return ResolvedFrame(x: x, y: y, width: width / 2, height: height)
        case .rightHalf:
            return ResolvedFrame(x: x + width / 2, y: y, width: width / 2, height: height)
        case .topHalf:
            return ResolvedFrame(x: x, y: y, width: width, height: height / 2)
        case .bottomHalf:
            return ResolvedFrame(x: x, y: y + height / 2, width: width, height: height / 2)
        case .leftThird:
            return ResolvedFrame(x: x, y: y, width: width / 3, height: height)
        case .centerThird:
            return ResolvedFrame(x: x + width / 3, y: y, width: width / 3, height: height)
        case .rightThird:
            return ResolvedFrame(x: x + width * 2 / 3, y: y, width: width / 3, height: height)
        case .maximize:
            return ResolvedFrame(x: x, y: y, width: width, height: height)
        case .center:
            return ResolvedFrame(
                x: x + width / 8,
                y: y + height / 8,
                width: width * 3 / 4,
                height: height * 3 / 4
            )
        }
    }
}
