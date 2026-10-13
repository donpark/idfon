import UIKit

/// D11's avatar chips: stable per-name color + initials. The bubbles use the
/// pieces as live views; list rows use the rendered image.
enum Avatar {
    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }
            .map(String.init).joined().uppercased()
    }

    /// Stable per-name chip color (`hashValue` is not stable across runs).
    static func color(_ name: String) -> UIColor {
        let palette: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink,
                                  .systemPurple, .systemTeal]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    /// The initials chip as a round image (list rows).
    static func image(_ name: String, size: CGFloat = 36) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            color(name).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.4, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = initials(name) as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2),
                      withAttributes: attributes)
        }
    }
}
