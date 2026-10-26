import os, pathlib, plistlib, shutil, subprocess, tempfile
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.5"; new="7.11.9.4.3.2.6.8"
for name in ("control","VERSION.txt"):
 p=root/name; t=p.read_text(); assert old in t,(name,t[:150]); p.write_text(t.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes()); d["CFBundleVersion"]=new; d["CFBundleShortVersionString"]=new
d["CFBundleIconFile"]="RecordingSharingan.png"
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/Resources/Root.plist"
d=plistlib.loads(p.read_bytes()); rows=d if isinstance(d,list) else d["items"]
adjust=[i for i in rows if i.get("cellClass")=="RSAdjustCell"]
assert len(adjust)==6,len(adjust)
for i in adjust:i["height"]=46
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/RSAdjustCell.m"
t=p.read_text()
start=t.index("- (void)layoutSubviews")
end=t.index("- (void)showValue",start)
t=t[:start]+'''- (void)layoutSubviews {
 [super layoutSubviews];
 CGFloat w=self.contentView.bounds.size.width;
 // Compact single-row layout: title | minus | slider | plus | value.
 CGFloat titleWidth=MAX(72,MIN(112,w*0.26));
 self.textLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
 self.textLabel.adjustsFontSizeToFitWidth=YES;
 self.textLabel.minimumScaleFactor=0.75;
 self.textLabel.frame=CGRectMake(12,0,titleWidth-8,46);
 CGFloat x=titleWidth;
 self.minus.frame=CGRectMake(x,6,24,34);
 self.number.frame=CGRectMake(w-54,0,46,46);
 self.plus.frame=CGRectMake(w-82,6,24,34);
 self.slider.frame=CGRectMake(x+25,8,MAX(30,w-x-111),30);
 self.minus.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
 self.plus.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
 self.number.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
}
''' +t[end:]
p.write_text(t)
icon=root/"layout/Library/PreferenceLoader/Preferences/RecordingSharingan.png"
assert icon.is_file() and icon.stat().st_size>100
# Scale artwork to 44pt inside the original 58pt transparent canvas.
# macOS AppKit avoids third-party image dependencies.
swift_code = r"""
import AppKit
import Foundation
let src = URL(fileURLWithPath: CommandLine.arguments[1])
guard let original = NSImage(contentsOf: src),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 58, pixelsHigh: 58,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon canvas") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 58, height: 58).fill()
original.draw(in: NSRect(x: 7, y: 7, width: 44, height: 44),
              from: NSRect(origin: .zero, size: original.size), operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG export failed") }
try png.write(to: src)
"""
with tempfile.NamedTemporaryFile(mode="w", suffix=".swift", delete=False) as swift:
 swift.write(swift_code)
 swift_path=swift.name
try:
 subprocess.run(["swift", swift_path, str(icon)], check=True)
finally:
 os.unlink(swift_path)
shutil.copy2(icon,root/"RecordingSharinganPrefs/Resources/RecordingSharingan.png")
p=root/"layout/Library/PreferenceLoader/Preferences/RecordingSharingan.plist"
d=plistlib.loads(p.read_bytes())
assert "entry" in d
# PreferenceLoader implementations differ in whether icon is read at root or entry.
d["entry"]["icon"]="RecordingSharingan.png"
d["icon"]="RecordingSharingan.png"
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
print("V6.8 Preferences patch complete: 6 x 46pt one-row sliders; dual icon metadata and bundle icon.")
