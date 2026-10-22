import AppKit
let image=NSImage(contentsOfFile:CommandLine.arguments[1])!
if !NSWorkspace.shared.setIcon(image,forFile:CommandLine.arguments[2],options:[]) { exit(1) }
