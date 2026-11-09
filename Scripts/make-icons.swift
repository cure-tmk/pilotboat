// Generates Design/AppIcon.icns from Design/AppIcon-1024.png (Apple's 824 pt squircle on a transparent canvas).
// Usage: swift Scripts/make-icons.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("Design")
let fm = FileManager.default

func makeAppIcon() throws {
    guard let source = NSImage(contentsOf: design.appendingPathComponent("AppIcon-1024.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "icons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Design/AppIcon-1024.png missing"])
    }
    let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let pixels = points * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let side = CGFloat(pixels) * 824 / 1024
        let inset = (CGFloat(pixels) - side) / 2
        let shape = CGRect(x: inset, y: inset, width: side, height: side)
        ctx.addPath(CGPath(roundedRect: shape, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(source, in: shape)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", design.appendingPathComponent("AppIcon.icns").path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "icons", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]) }
}

try makeAppIcon()
print("wrote Design/AppIcon.icns")
