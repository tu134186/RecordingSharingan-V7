import os,pathlib,plistlib,subprocess,tempfile,zipfile
root=pathlib.Path(os.environ['PROJECT_DIR'])
old='7.11.9.4.3.2.6.10';new='7.11.9.4.3.2.6.11'
for name in ('control','VERSION.txt'):
 p=root/name;s=p.read_text();assert old in s;p.write_text(s.replace(old,new))
p=root/'RecordingSharinganPrefs/Resources/Info.plist';d=plistlib.loads(p.read_bytes());d['CFBundleVersion']=new;d['CFBundleShortVersionString']=new;p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
archive=pathlib.Path(os.environ['GITHUB_WORKSPACE'])/'app.zip'
with zipfile.ZipFile(archive) as z:
 matches=[n for n in z.namelist() if n.endswith('layout/Library/PreferenceLoader/Preferences/RecordingSharingan.png')]
 assert len(matches)==1,matches
 original=z.read(matches[0])
with tempfile.TemporaryDirectory() as temp:
 src=pathlib.Path(temp)/'original.png';src.write_bytes(original)
 dst=pathlib.Path(temp)/'fixed.png'
 swift=r"""
import AppKit
import Foundation
let src=CommandLine.arguments[1],dst=CommandLine.arguments[2]
guard let image=NSImage(contentsOfFile:src),let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:58,pixelsHigh:58,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let ctx=NSGraphicsContext(bitmapImageRep:rep) else {fatalError("icon load failed")}
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=ctx
NSColor.clear.setFill();NSRect(x:0,y:0,width:58,height:58).fill()
let square=NSRect(x:10,y:10,width:38,height:38)
NSColor(calibratedWhite:0.95,alpha:1).setFill()
NSBezierPath(roundedRect:square,xRadius:8,yRadius:8).fill()
ctx.imageInterpolation = .high
image.draw(in:NSRect(x:12,y:12,width:34,height:34),from:NSRect(x:8,y:8,width:42,height:42),operation:.sourceOver,fraction:1)
ctx.flushGraphics();NSGraphicsContext.restoreGraphicsState()
guard let png=rep.representation(using:.png,properties:[:]) else {fatalError("icon export failed")}
try png.write(to:URL(fileURLWithPath:dst))
"""
 code=pathlib.Path(temp)/'icon.swift';code.write_text(swift)
 subprocess.run(['swift',str(code),str(src),str(dst)],check=True)
 data=dst.read_bytes()
 for path in ('layout/Library/PreferenceLoader/Preferences/RecordingSharingan.png','RecordingSharinganPrefs/Resources/RecordingSharingan.png'):
  (root/path).write_bytes(data)
print('V6.11 rebuilt icon from pristine source')
