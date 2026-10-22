import AppKit
import Foundation
let out=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let image=NSImage(size:NSSize(width:size,height:size)); image.lockFocus()
    let s=CGFloat(size), rect=NSRect(x:s*0.04,y:s*0.04,width:s*0.92,height:s*0.92)
    NSColor(calibratedRed:0.06,green:0.09,blue:0.13,alpha:1).setFill(); NSBezierPath(roundedRect:rect,xRadius:s*0.21,yRadius:s*0.21).fill()
    let camera=NSBezierPath(roundedRect:NSRect(x:s*0.18,y:s*0.30,width:s*0.64,height:s*0.43),xRadius:s*0.07,yRadius:s*0.07)
    NSColor(calibratedRed:0.25,green:0.88,blue:0.76,alpha:1).setFill(); camera.fill()
    NSBezierPath(roundedRect:NSRect(x:s*0.28,y:s*0.69,width:s*0.22,height:s*0.08),xRadius:s*0.025,yRadius:s*0.025).fill()
    NSColor(calibratedRed:0.06,green:0.09,blue:0.13,alpha:1).setFill(); NSBezierPath(ovalIn:NSRect(x:s*0.35,y:s*0.365,width:s*0.31,height:s*0.31)).fill()
    NSColor.white.setStroke(); let lens=NSBezierPath(ovalIn:NSRect(x:s*0.405,y:s*0.42,width:s*0.20,height:s*0.20)); lens.lineWidth=s*0.012; lens.stroke()
    NSColor.white.withAlphaComponent(0.8).setFill(); for x in [0.29,0.43,0.57,0.71] { NSBezierPath(ovalIn:NSRect(x:s*CGFloat(x)-s*0.028,y:s*0.17,width:s*0.056,height:s*0.056)).fill() }
    image.unlockFocus()
    let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!; let data=bitmap.representation(using:.png,properties:[:])!
    try data.write(to:URL(fileURLWithPath:out).appendingPathComponent("\(size).png"))
}
