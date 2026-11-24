// Иконка «Радара» (выбрана scope - экран радара в рамке); запуск: swift make_icon.swift scope icon_1024.png
import AppKit
let size: CGFloat = 1024
let style = CommandLine.arguments[1]; let out = CommandLine.arguments[2]
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
let C = NSPoint(x: 512, y: 512)
func circle(_ r: CGFloat, at p: NSPoint = C) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
func tileFill(_ colors: [NSColor], angle: CGFloat) {
    ctx.saveGState(); let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    colors[0].setFill(); tilePath.fill(); ctx.restoreGState()
    NSGradient(colors: colors)!.draw(in: tilePath, angle: angle)
}
switch style {
case "coral":
    // коралловая плитка, белый радар: тонкие кольца, луч, точки-цели
    tileFill([c(0xF08A62), c(0xE86E4B), c(0xC9502F)], angle: -90)
    tilePath.addClip()
    for r in [120.0, 220.0, 320.0] as [CGFloat] { let p = circle(r); p.lineWidth = 10; c(0xFFFFFF, 0.35).setStroke(); p.stroke() }
    let cross = NSBezierPath(); cross.move(to: NSPoint(x: 512, y: 180)); cross.line(to: NSPoint(x: 512, y: 844)); cross.move(to: NSPoint(x: 180, y: 512)); cross.line(to: NSPoint(x: 844, y: 512))
    cross.lineWidth = 6; c(0xFFFFFF, 0.25).setStroke(); cross.stroke()
    ctx.saveGState(); let w = NSBezierPath(); w.move(to: C); w.appendArc(withCenter: C, radius: 330, startAngle: 20, endAngle: 75); w.close(); w.addClip()
    NSGradient(colors: [c(0xFFFFFF, 0.0), c(0xFFFFFF, 0.75)])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 75); ctx.restoreGState()
    let beam = NSBezierPath(); beam.move(to: C); beam.line(to: NSPoint(x: 512 + 330 * cos(CGFloat(75) * CGFloat.pi / 180), y: 512 + 330 * sin(CGFloat(75) * CGFloat.pi / 180))); beam.lineWidth = 14; beam.lineCapStyle = .round; c(0xFFFFFF).setStroke(); beam.stroke()
    for (p, r) in [(NSPoint(x: 650, y: 690), 30.0), (NSPoint(x: 360, y: 640), 22.0), (NSPoint(x: 620, y: 330), 18.0)] as [(NSPoint, CGFloat)] { c(0xFFFFFF).setFill(); circle(r, at: p).fill() }
    c(0xFFFFFF).setFill(); circle(26).fill()
case "scope":
    // светлая плитка, круглый экран радара как у старого прибора, зелёное свечение
    tileFill([c(0xF4F5F7), c(0xD9DCE1)], angle: -90)
    tilePath.addClip()
    c(0x9AA0A8).setFill(); circle(352).fill()
    NSGradient(colors: [c(0xFFFFFF), c(0x8D939B)])!.draw(in: circle(340), angle: -90)
    NSGradient(colors: [c(0x0F2A1C), c(0x06120C)])!.draw(in: circle(300), relativeCenterPosition: .zero)
    circle(300).addClip()
    for r in [100.0, 200.0, 290.0] as [CGFloat] { let p = circle(r); p.lineWidth = 5; c(0x37D67A, 0.35).setStroke(); p.stroke() }
    ctx.saveGState(); let w = NSBezierPath(); w.move(to: C); w.appendArc(withCenter: C, radius: 300, startAngle: 35, endAngle: 100); w.close(); w.addClip()
    NSGradient(colors: [c(0x37D67A, 0.0), c(0x37D67A, 0.8)])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 100); ctx.restoreGState()
    for (p, r) in [(NSPoint(x: 600, y: 680), 22.0), (NSPoint(x: 400, y: 410), 16.0)] as [(NSPoint, CGFloat)] { c(0xB8FFD3).setFill(); circle(r, at: p).fill() }
    // стеклянный блик на экране
    let gl = NSBezierPath(ovalIn: NSRect(x: 290, y: 560, width: 440, height: 230)); c(0xFFFFFF, 0.10).setFill(); gl.fill()
case "gauge":
    // тёплый градиент, белый спидометр со стрелкой
    tileFill([c(0xFFB020), c(0xE86E4B)], angle: -60)
    tilePath.addClip()
    let arcC = NSPoint(x: 512, y: 430)
    let track = NSBezierPath(); track.appendArc(withCenter: arcC, radius: 300, startAngle: 200, endAngle: -20, clockwise: true); track.lineWidth = 64; track.lineCapStyle = .round; c(0xFFFFFF, 0.35).setStroke(); track.stroke()
    let val = NSBezierPath(); val.appendArc(withCenter: arcC, radius: 300, startAngle: 200, endAngle: 60, clockwise: true); val.lineWidth = 64; val.lineCapStyle = .round; c(0xFFFFFF).setStroke(); val.stroke()
    for a in stride(from: 200.0, through: -20.0, by: -27.5) { let r1: CGFloat = 215, r2: CGFloat = 245; let t = NSBezierPath(); let rad = CGFloat(a) * .pi / 180
        t.move(to: NSPoint(x: arcC.x + r1 * cos(rad), y: arcC.y + r1 * sin(rad))); t.line(to: NSPoint(x: arcC.x + r2 * cos(rad), y: arcC.y + r2 * sin(rad))); t.lineWidth = 12; t.lineCapStyle = .round; c(0xFFFFFF, 0.8).setStroke(); t.stroke() }
    let na: CGFloat = 60 * .pi / 180
    let needle = NSBezierPath(); needle.move(to: arcC); needle.line(to: NSPoint(x: arcC.x + 230 * cos(na), y: arcC.y + 230 * sin(na))); needle.lineWidth = 30; needle.lineCapStyle = .round; c(0x0E0F13).setStroke(); needle.stroke()
    c(0x0E0F13).setFill(); circle(48, at: arcC).fill(); c(0xFFFFFF).setFill(); circle(18, at: arcC).fill()
case "bars":
    // зелёный градиент, три белых столбика нагрузки и диск
    tileFill([c(0x5BE596), c(0x37D67A), c(0x1FA85B)], angle: -90)
    tilePath.addClip()
    let bars: [(CGFloat, CGFloat)] = [(280, 300), (450, 470), (620, 380)]
    for (x, h) in bars { let b = NSBezierPath(roundedRect: NSRect(x: x - 60, y: 250, width: 120, height: h), xRadius: 60, yRadius: 60); c(0xFFFFFF).setFill(); b.fill() }
    let base = NSBezierPath(roundedRect: NSRect(x: 200, y: 190, width: 624, height: 26), xRadius: 13, yRadius: 13); c(0xFFFFFF, 0.6).setFill(); base.fill()
    c(0xE86E4B).setFill(); circle(52, at: NSPoint(x: 760, y: 770)).fill()
default: break
}
// тонкая кромка
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184); rim.lineWidth = 3; c(0xFFFFFF, 0.18).setStroke(); rim.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
