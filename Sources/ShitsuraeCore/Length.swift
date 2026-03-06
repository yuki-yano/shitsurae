import CoreGraphics
import Foundation

public enum LengthUnit: Equatable {
    case pt
    case percent
    case ratio
    case px
}

public struct ParsedLength: Equatable {
    public let value: Double
    public let unit: LengthUnit

    public func resolve(dimension: Double, scale: Double) -> Double {
        switch unit {
        case .pt:
            return value
        case .percent:
            return dimension * (value / 100.0)
        case .ratio:
            return dimension * value
        case .px:
            return (value / scale).rounded()
        }
    }
}

public struct ResolvedFrame: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public enum LengthParser {
    public static func parse(_ length: LengthValue) throws -> ParsedLength {
        switch length {
        case let .pt(value):
            return ParsedLength(value: value, unit: .pt)
        case let .expression(raw):
            return try parse(raw)
        }
    }

    public static func parse(_ raw: String) throws -> ParsedLength {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("%") {
            let number = String(value.dropLast())
            guard let parsed = Double(number) else {
                throw ShitsuraeError(.validationError, "invalid percent length: \(raw)")
            }
            guard (0 ... 100).contains(parsed) else {
                throw ShitsuraeError(.validationError, "percent length out of range: \(raw)")
            }
            return ParsedLength(value: parsed, unit: .percent)
        }

        if value.hasSuffix("r") {
            let number = String(value.dropLast())
            guard let parsed = Double(number) else {
                throw ShitsuraeError(.validationError, "invalid ratio length: \(raw)")
            }
            guard (0 ... 1).contains(parsed) else {
                throw ShitsuraeError(.validationError, "ratio length out of range: \(raw)")
            }
            return ParsedLength(value: parsed, unit: .ratio)
        }

        if value.hasSuffix("pt") {
            let number = String(value.dropLast(2))
            guard let parsed = Double(number) else {
                throw ShitsuraeError(.validationError, "invalid pt length: \(raw)")
            }
            return ParsedLength(value: parsed, unit: .pt)
        }

        if value.hasSuffix("px") {
            let number = String(value.dropLast(2))
            guard let parsed = Double(number) else {
                throw ShitsuraeError(.validationError, "invalid px length: \(raw)")
            }
            return ParsedLength(value: parsed, unit: .px)
        }

        if let parsed = Double(value) {
            return ParsedLength(value: parsed, unit: .pt)
        }

        throw ShitsuraeError(.validationError, "invalid length expression: \(raw)")
    }

    public static func resolveFrame(
        _ frame: FrameDefinition,
        basis: CGRect,
        scale: Double
    ) throws -> ResolvedFrame {
        let x = try parse(frame.x).resolve(dimension: basis.width, scale: scale)
        let y = try parse(frame.y).resolve(dimension: basis.height, scale: scale)
        let width = try parse(frame.width).resolve(dimension: basis.width, scale: scale)
        let height = try parse(frame.height).resolve(dimension: basis.height, scale: scale)

        guard width >= 1, height >= 1 else {
            throw ShitsuraeError(.validationError, "resolved width/height must be >= 1pt")
        }

        return ResolvedFrame(x: x, y: y, width: width, height: height)
    }
}
