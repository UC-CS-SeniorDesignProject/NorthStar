
import UIKit

enum ImageUtils {
    // converts UIImage to base64 string for sending to server
    static func toBase64(_ image: UIImage, quality: CGFloat = 0.9) -> String {
        let data = image.jpegData(compressionQuality: quality) ?? image.pngData() ?? Data()
        return data.base64EncodedString()
    }

    // scales image down if its bigger than maxSide
    static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let maxDimension = max(size.width, size.height)
        guard maxDimension > maxSide else { return image }

        let scale = maxSide / maxDimension
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
