import os,pathlib,plistlib
root=pathlib.Path(os.environ["PROJECT_DIR"])
old="7.11.9.4.3.2.6.13"; new="7.11.9.4.3.2.6.14"
for name in ("control","VERSION.txt"):
 p=root/name;s=p.read_text();assert old in s,(name,old);p.write_text(s.replace(old,new))
p=root/"RecordingSharinganPrefs/Resources/Info.plist"
d=plistlib.loads(p.read_bytes());d["CFBundleVersion"]=new;d["CFBundleShortVersionString"]=new;p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
# Keep original bundled PNGs immutable; imported overrides live in mobile-writable storage.
p=root/"Tweak.xm";s=p.read_text()
needle='    for (NSString *base in bases) {\n        NSString *p = [base stringByAppendingPathComponent:name];'
assert needle in s
s=s.replace(needle,'''    NSString *custom = [@"/var/mobile/Library/Preferences/RecordingSharinganAssets" stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:custom]) return custom;
'''+needle,1)
p.write_text(s)
p=root/"RecordingSharinganPrefs/RSRootController.h";s=p.read_text()
s=s.replace('@interface RSRootController : PSListController','@interface RSRootController : PSListController <UIDocumentPickerDelegate>')
p.write_text(s)
p=root/"RecordingSharinganPrefs/RSRootController.m";s=p.read_text()
assert '#import "RSRootController.h"' in s
s=s.replace('#import "RSRootController.h"','#import "RSRootController.h"\n#import <UIKit/UIKit.h>
#import <string.h>\n#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>')
s=s.replace('@implementation RSRootController','''@interface RSRootController ()
@property(nonatomic,assign) NSInteger rsImportSlot;
@end
@implementation RSRootController
- (void)rsAlert:(NSString *)message {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"写轮眼素材" message:message preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
 [self presentViewController:a animated:YES completion:nil];
}
- (void)rsNotify {
 CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.tu.recordingsharingan.settings.changed"),NULL,NULL,YES);
}
- (NSString *)rsAssetDirectory { return @"/var/mobile/Library/Preferences/RecordingSharinganAssets"; }
- (void)rsChooseFile {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"替换素材" message:@"选择要替换的素材位置" preferredStyle:UIAlertControllerStyleActionSheet];
 for (NSInteger i=1;i<=2;i++) {
  NSInteger slot=i;
  [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"素材 %ld",(long)i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
   self.rsImportSlot=slot;
   UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePNG] asCopy:YES];
   picker.delegate=self;picker.allowsMultipleSelection=NO;
   [self presentViewController:picker animated:YES completion:nil];
  }]];
 }
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
 UIPopoverPresentationController *pop=a.popoverPresentationController;
 if(pop){pop.sourceView=self.view;pop.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);}
 [self presentViewController:a animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
 NSURL *url=urls.firstObject;
 if(!url || self.rsImportSlot<1 || self.rsImportSlot>2)return;
 BOOL scoped=[url startAccessingSecurityScopedResource];
 __block NSError *readError=nil;
 __block NSData *data=nil;
 NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
 [coordinator coordinateReadingItemAtURL:url options:0 error:&readError byAccessor:^(NSURL *safeURL) {
  data=[NSData dataWithContentsOfURL:safeURL options:0 error:&readError];
 }];
 if(scoped)[url stopAccessingSecurityScopedResource];
 if(readError || data.length<24 || data.length>20*1024*1024){[self rsAlert:@"读取失败或文件超过 20MB，原素材未改变。"];return;}
 const unsigned char *bytes=data.bytes;
 const unsigned char png[8]={137,80,78,71,13,10,26,10};
 if(memcmp(bytes,png,8)!=0 || ![UIImage imageWithData:data]){[self rsAlert:@"请选择有效的 PNG 图片，原素材未改变。"];return;}
 NSString *dir=[self rsAssetDirectory];
 NSError *error=nil;
 if(![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]){
  [self rsAlert:[NSString stringWithFormat:@"无法创建素材目录：%@",error.localizedDescription?:@"权限不足"]];return;
 }
 NSString *name=[NSString stringWithFormat:@"replay%ld.png",(long)self.rsImportSlot];
 NSString *target=[dir stringByAppendingPathComponent:name];
 if(![data writeToFile:target options:NSDataWritingAtomic error:&error]){
  [self rsAlert:[NSString stringWithFormat:@"保存失败：%@",error.localizedDescription?:@"权限不足"]];return;
 }
 [self rsNotify];
 [self rsAlert:[NSString stringWithFormat:@"素材 %ld 已导入。录屏中将尝试立即刷新，未录屏则下次显示。",(long)self.rsImportSlot]];
}
- (void)rsRestoreMaterial {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"恢复内置素材" message:@"删除导入的图片，恢复两款内置素材？" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
  NSFileManager *fm=[NSFileManager defaultManager];NSString *dir=[self rsAssetDirectory];
  NSError *err=nil;
  for(NSInteger i=1;i<=2;i++){
   NSString *p=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"replay%ld.png",(long)i]];
   if([fm fileExistsAtPath:p] && ![fm removeItemAtPath:p error:&err])break;
  }
  if(err)[self rsAlert:[NSString stringWithFormat:@"恢复失败：%@",err.localizedDescription]];
  else {[self rsNotify];[self rsAlert:@"已恢复内置素材。"];}
 }]];
 [self presentViewController:a animated:YES completion:nil];
}
''',1)
p.write_text(s)
p=root/"RecordingSharinganPrefs/Resources/Root.plist";d=plistlib.loads(p.read_bytes());items=d["items"] if isinstance(d,dict) else d
idx=next(i for i,x in enumerate(items) if x.get("key")=="eyeStyle")
items[idx+1:idx+1]=[
 {"cell":"PSButtonCell","label":"选择文件 · 替换素材","action":"rsChooseFile"},
 {"cell":"PSButtonCell","label":"恢复内置素材","action":"rsRestoreMaterial"}
]
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
print("Material picker and override paths applied:",new)
