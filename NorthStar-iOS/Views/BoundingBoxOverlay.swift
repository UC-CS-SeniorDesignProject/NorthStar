// draws bounding boxes on images for ocr and detection results
import SwiftUI

struct OCRBoundingBoxOverlay: View {
    let blocks: [OCRBlock]
    let imageSize: CGSize
    let displaySize: CGSize

    var body: some View {
        Canvas { context, size in
            let scaleX = displaySize.width / imageSize.width
            let scaleY = displaySize.height / imageSize.height

            for block in blocks {
                guard block.polygon.count >= 4 else { continue }

                var path = Path()
                let points = block.polygon.compactMap { pt -> CGPoint? in
                    guard pt.count >= 2 else { return nil }
                    return CGPoint(x: pt[0] * scaleX, y: pt[1] * scaleY)
                }
                guard points.count >= 3 else { continue }
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()

                context.stroke(path, with: .color(.blue.opacity(0.8)), lineWidth: 2)
                context.fill(path, with: .color(.blue.opacity(0.1)))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(false)
    }
}

struct DetectBoundingBoxOverlay: View {
    let objects: [DetectedObject]
    let imageSize: CGSize
    let displaySize: CGSize

    private let colors: [Color] = [.red, .green, .orange, .purple, .cyan, .yellow, .pink, .mint]

    var body: some View {
        Canvas { context, size in
            let scaleX = displaySize.width / imageSize.width
            let scaleY = displaySize.height / imageSize.height

            for (index, obj) in objects.enumerated() {
                guard obj.bbox.count == 4 else { continue }

                let rect = CGRect(
                    x: obj.bbox[0] * scaleX,
                    y: obj.bbox[1] * scaleY,
                    width: (obj.bbox[2] - obj.bbox[0]) * scaleX,
                    height: (obj.bbox[3] - obj.bbox[1]) * scaleY
                )

                let color = colors[index % colors.count]

                context.stroke(Path(rect), with: .color(color), lineWidth: 2.5)
                context.fill(Path(rect), with: .color(color.opacity(0.1)))

                let label = "\(obj.label) \(String(format: "%.0f%%", obj.confidence * 100))"
                let text = Text(label).font(.caption2).bold().foregroundColor(.white)
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: rect.minX + 4, y: rect.minY + 2),
                    anchor: .topLeading
                )
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(false)
    }
}
