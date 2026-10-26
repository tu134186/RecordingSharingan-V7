import os,pathlib,plistlib
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.11";new="7.11.9.4.3.2.6.12"
for name in ("control","VERSION.txt"):
 p=root/name;s=p.read_text();assert old in s;p.write_text(s.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes())
d["CFBundleVersion"]=new;d["CFBundleShortVersionString"]=new
d.pop("CFBundleIconFile",None);d.pop("CFBundleIconFiles",None)
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
p=root/"layout/Library/PreferenceLoader/Preferences/RecordingSharingan.plist"
d=plistlib.loads(p.read_bytes())
d.pop("icon",None)
if isinstance(d.get("entry"),dict):d["entry"].pop("icon",None)
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
for name in ("layout/Library/PreferenceLoader/Preferences/RecordingSharingan.png","RecordingSharinganPrefs/Resources/RecordingSharingan.png"):
 p=root/name
 if p.exists():p.unlink()
print("Removed custom icon overrides: use PreferenceLoader default icon")
