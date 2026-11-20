import AppKit
let output = CommandLine.arguments[1]
let sizes = [16,32,64,128,256,512,1024]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/80); transform.concat()
    NSColor(red: 1, green: 0.408, blue: 0.11, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 3,y: 3,width: 74,height: 74),xRadius: 17,yRadius: 17).fill()
    let ink = NSColor(red: 0.14, green: 0.15, blue: 0.14, alpha: 1); ink.setStroke(); ink.setFill()
    for n in [27,40,53] {
        for points in [[CGFloat(n),14,CGFloat(n),26],[CGFloat(n),54,CGFloat(n),66],[14,CGFloat(n),26,CGFloat(n)],[54,CGFloat(n),66,CGFloat(n)]] {
            let p=NSBezierPath();p.lineWidth=3;p.move(to:NSPoint(x:points[0],y:points[1]));p.line(to:NSPoint(x:points[2],y:points[3]));p.stroke()
        }
    }
    let box=NSBezierPath(roundedRect:NSRect(x:23,y:23,width:34,height:34),xRadius:3,yRadius:3);box.lineWidth=3;box.stroke()
    NSBezierPath(rect:NSRect(x:32,y:42,width:4,height:5)).fill();NSBezierPath(rect:NSRect(x:44,y:42,width:4,height:5)).fill()
    let smile=NSBezierPath();smile.lineWidth=3;smile.move(to:NSPoint(x:32,y:35));smile.curve(to:NSPoint(x:48,y:35),controlPoint1:NSPoint(x:36,y:27),controlPoint2:NSPoint(x:44,y:27));smile.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data=rep.representation(using:.png,properties:[:])!
    if [16,32,128,256,512].contains(size) { try data.write(to:URL(fileURLWithPath:output+"/icon_\(size)x\(size).png")) }
    if [32,64,256,512,1024].contains(size) { try data.write(to:URL(fileURLWithPath:output+"/icon_\(size/2)x\(size/2)@2x.png")) }
}
