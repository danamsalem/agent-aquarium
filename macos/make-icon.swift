// Draws the settings app's icon as a PNG from the full-bleed artwork in brand/.
// The artwork fills the whole canvas (no margin, corners or shadow): macOS applies its own icon mask,
// and puts icons with transparent margins in a grey tile instead.
// Usage: swift make-icon.swift <artwork.png> <output.png>
import AppKit

let size: CGFloat = 1024
let art = NSImage(contentsOfFile: CommandLine.arguments[1])!
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
art.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
