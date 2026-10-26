import os, pathlib, plistlib, re
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.8"
new="7.11.9.4.3.2.6.9"
for name in ("control","VERSION.txt"):
 p=root/name
 s=p.read_text()
 assert old in s,(name,s[:100])
 p.write_text(s.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes())
d["CFBundleVersion"]=new
d["CFBundleShortVersionString"]=new
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"RecordingSharinganPrefs/Resources/Root.plist"
d=plistlib.loads(p.read_bytes())
rows=d if isinstance(d,list) else d["items"]
labels={"素材":"素材选择","旋转":"旋转控制","旋转速度":"速度","大小":"素材尺寸","左侧大小":"左侧","右侧大小":"右侧"}
for row in rows:
 label=row.get("label")
 if label in labels:row["label"]=labels[label]
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
# Fix text label centering to actual contentView height, not a fixed 46pt origin.
p=root/"RecordingSharinganPrefs/RSAdjustCell.m"
s=p.read_text()
needle="self.textLabel.frame=CGRectMake(12,0,titleWidth-8,46);"
assert needle in s
s=s.replace(needle,"self.textLabel.frame=CGRectMake(12,0,titleWidth-8,self.contentView.bounds.size.height);")
p.write_text(s)
# The PreferenceLoader icon has an inset canvas; normalize it without further shrinking.
# iOS Settings owns the layout of other installed tweaks, so do not hook their cells.
p=root/"layout/Library/PreferenceLoader/Preferences/RecordingSharingan.plist"
d=plistlib.loads(p.read_bytes())
assert "entry" in d
d["entry"]["icon"]="RecordingSharingan.png"
d["icon"]="RecordingSharingan.png"
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
print("Settings labels and own icon metadata updated",new)
