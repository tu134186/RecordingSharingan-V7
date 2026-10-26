import os,pathlib,plistlib
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.12";new="7.11.9.4.3.2.6.13"
for name in ("control","VERSION.txt"):
 p=root/name;s=p.read_text();assert old in s;p.write_text(s.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes());d["CFBundleVersion"]=new;d["CFBundleShortVersionString"]=new;p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/RSAdjustCell.m"
s=p.read_text()
start=s.index("- (void)layoutSubviews")
end=s.index("- (void)showValue",start)
s=s[:start]+'''- (void)layoutSubviews {
 [super layoutSubviews];
 const CGFloat w=self.contentView.bounds.size.width;
 const CGFloat h=self.contentView.bounds.size.height;
 // Same 17pt body size as native Settings rows, shared aligned columns.
 const CGFloat inset=12.0;
 const CGFloat labelWidth=69.0;
 const CGFloat controlWidth=30.0;
 const CGFloat valueWidth=43.0;
 const CGFloat gap=2.0;
 const CGFloat valueX=w-8.0-valueWidth;
 const CGFloat plusX=valueX-gap-controlWidth;
 const CGFloat minusX=inset+labelWidth;
 const CGFloat sliderX=minusX+controlWidth+gap;
 const CGFloat sliderEnd=plusX-gap;
 self.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
 self.textLabel.adjustsFontSizeToFitWidth=NO;
 self.textLabel.frame=CGRectMake(inset,0,labelWidth,h);
 self.minus.frame=CGRectMake(minusX,0,controlWidth,h);
 self.slider.frame=CGRectMake(sliderX,(h-32.0)/2.0,MAX(40.0,sliderEnd-sliderX),32.0);
 self.plus.frame=CGRectMake(plusX,0,controlWidth,h);
 self.number.frame=CGRectMake(valueX,0,valueWidth,h);
 self.minus.titleLabel.font=[UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
 self.plus.titleLabel.font=[UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
 self.number.font=[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
}
'''+s[end:]
p.write_text(s)
print("Native Settings font and compact aligned controls applied",new)
