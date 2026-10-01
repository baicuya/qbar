import AppKit

@main
struct GenerateIcon {
static func main() throws {
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let set = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        QbarBrand.drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon-\(points)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "Qbar", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: set.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "Qbar", "version": 1]], options: .prettyPrinted)
    .write(to: root.appendingPathComponent("Resources/Assets.xcassets/Contents.json"))

}
}
