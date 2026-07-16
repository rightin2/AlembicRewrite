// Generates MenuBarIcon.png / MenuBarIcon@2x.png — template image (black + alpha)
// Same mark as design/menubar-icon.svg: serif R with quill leaf at the shoulder.
import AppKit

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 128.0

    // Serif R (Times New Roman Bold), baseline matched to the SVG (y=112 in a 128 flipped space)
    let font = NSFont(name: "Times New Roman Bold", size: 118 * s) ?? NSFont.boldSystemFont(ofSize: 118 * s)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let rStr = NSAttributedString(string: "R", attributes: attrs)
    // AppKit origin is bottom-left; SVG baseline y=112 from top => 16 from bottom minus descender
    rStr.draw(at: NSPoint(x: 8 * s, y: (128 - 112) * s + font.descender))

    // Quill leaf: rotate(40deg) about (96,44) in SVG top-left coords => convert to bottom-left
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    let cx = 96 * s, cy = (128 - 44) * s
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: -40 * .pi / 180)   // negative: flipped Y vs SVG
    ctx.translateBy(x: -cx, y: -cy)
    let leaf = NSBezierPath()
    // SVG: M96 -14 C89 8 89 34 96 66 C103 34 103 8 96 -14 (top-left coords) -> flip y
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: (128 - y) * s) }
    leaf.move(to: P(96, -14))
    leaf.curve(to: P(96, 66), controlPoint1: P(89, 8), controlPoint2: P(89, 34))
    leaf.curve(to: P(96, -14), controlPoint1: P(103, 34), controlPoint2: P(103, 8))
    leaf.close()
    NSColor.black.setFill()
    leaf.fill()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String) {
    let rect = NSRect(origin: .zero, size: image.size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
savePNG(draw(size: 36), to: outDir + "/MenuBarIcon.png")      // 18pt @2x-ready base is 36px? no: 18px @1x
savePNG(draw(size: 72), to: outDir + "/MenuBarIcon@2x.png")
print("wrote MenuBarIcon.png (36px) and MenuBarIcon@2x.png (72px) to \(outDir)")
