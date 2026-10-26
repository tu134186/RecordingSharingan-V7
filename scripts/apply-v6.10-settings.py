import os,pathlib,plistlib,subprocess,tempfile
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.9";new="7.11.9.4.3.2.6.10"
for name in ("control","VERSION.txt"):
 p=root/name;s=p.read_text();assert old in s,(name,s[:100]);p.write_text(s.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes());d["CFBundleVersion"]=new;d["CFBundleShortVersionString"]=new
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/Resources/Root.plist"
d=plistlib.loads(p.read_bytes());rows=d if isinstance(d,list) else d["items"]
for item in rows:
 if item.get("label")=="写轮眼素材":item["label"]="写轮眼"
 if item.get("cell")=="PSGroupCell" and item.get("label") in ("素材选择","旋转控制","位置微调","素材尺寸","恢复"):
  item["height"]=26
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/RSAdjustCell.m"
s=p.read_text()
start=s.index("- (void)layoutSubviews")
end=s.index("- (void)showValue",start)
s=s[:start]+'''- (void)layoutSubviews {
 [super layoutSubviews];
 CGFloat w=self.contentView.bounds.size.width;
 CGFloat h=self.contentView.bounds.size.height;
 // Shared aligned columns; 44pt hit targets, compact visual gaps.
 CGFloat left=12, right=8;
 CGFloat titleWidth=58;
 CGFloat buttonWidth=36;
 CGFloat numberWidth=43;
 CGFloat gap=3;
 CGFloat sliderX=left+titleWidth+buttonWidth+gap;
 CGFloat numberX=w-right-numberWidth;
 CGFloat plusX=numberX-gap-buttonWidth;
 CGFloat sliderRight=plusX-gap;
 self.textLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
 self.textLabel.adjustsFontSizeToFitWidth=YES;
 self.textLabel.minimumScaleFactor=0.8;
 self.textLabel.frame=CGRectMake(left,0,titleWidth,h);
 self.minus.frame=CGRectMake(left+titleWidth,0,buttonWidth,h);
 self.slider.frame=CGRectMake(sliderX,(h-32)/2,MAX(28,sliderRight-sliderX),32);
 self.plus.frame=CGRectMake(plusX,0,buttonWidth,h);
 self.number.frame=CGRectMake(numberX,0,numberWidth,h);
 self.minus.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
 self.plus.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
 self.number.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
}
'''+s[end:]
p.write_text(s)
# Add a neutral rounded-square canvas behind the circular logo, keeping its size and position.
icon=root/"layout/Library/PreferenceLoader/Preferences/RecordingSharingan.png"
swift=r"""
import AppKit
let path=CommandLine.arguments[1]
guard let original=NSImage(contentsOfFile:path),
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:58,pixelsHigh:58,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
let context=NSGraphicsContext(bitmapImageRep:rep) else { fatalError("icon unavailable") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=context
NSColor.clear.setFill();NSRect(x:0,y:0,width:58,height:58).fill()
NSColor(calibratedWhite:0.94,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:1,y:1,width:56,height:56),xRadius:11,yRadius:11).fill()
original.draw(in:NSRect(x:0,y:0,width:58,height:58),from:NSRect(origin:.zero,size:original.size),operation:.sourceOver,fraction:1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png=rep.representation(using:.png,properties:[:]) else { fatalError("PNG encode") }
try png.write(to:URL(fileURLWithPath:path))
"""
with tempfile.NamedTemporaryFile(mode="w",suffix=".swift",delete=False) as f:
 f.write(swift);tmp=f.name
try:subprocess.run(["swift",tmp,str(icon)],check=True)
finally:os.unlink(tmp)
import shutil
shutil.copy2(icon,root/"RecordingSharinganPrefs/Resources/RecordingSharingan.png")
print("V6.10 compact slider geometry, grouped spacing and square icon completed")
