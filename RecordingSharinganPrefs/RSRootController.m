#import "RSRootController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/PSSpecifier.h>
#import <os/log.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <string.h>

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <string.h>

static NSString * const RSMaterialDomain = @"com.tu.recordingsharingan.settings";
static NSString *RSMaterialDirectory(void) { return @"/var/mobile/Library/Preferences/RecordingSharinganAssets"; }
static id RSMaterialPref(NSString *key) {
 return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)RSMaterialDomain));
}
static void RSMaterialNotify(void) {
 CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.tu.recordingsharingan.settings.changed"),NULL,NULL,YES);
}
static NSString *RSMaterialSideKey(BOOL right) { return right ? @"rightMaterial" : @"leftMaterial"; }
static BOOL RSMaterialIsCustom(NSString *name) {
 return [name isKindOfClass:NSString.class] && [name hasPrefix:@"custom-"] && [name isEqualToString:name.lastPathComponent] && [name.pathExtension.lowercaseString isEqualToString:@"png"];
}
static NSString *RSMaterialChoice(BOOL right) {
 id raw=RSMaterialPref(RSMaterialSideKey(right));
 if([raw isKindOfClass:NSString.class] && ([raw isEqualToString:@"builtin:1"] || [raw isEqualToString:@"builtin:2"] || RSMaterialIsCustom(raw)))return raw;
 NSInteger style=[RSMaterialPref(@"eyeStyle") integerValue];
 id name=RSMaterialPref(@"customAssetName");
 if(style==3 && RSMaterialIsCustom(name))return name;
 return style==2 ? @"builtin:2" : @"builtin:1";
}
static BOOL RSMaterialSaveChoices(NSString *left,NSString *right) {
 id oldLeft=RSMaterialPref(@"leftMaterial"),oldRight=RSMaterialPref(@"rightMaterial");
 if(left) CFPreferencesSetAppValue(CFSTR("leftMaterial"),(__bridge CFPropertyListRef)left,(__bridge CFStringRef)RSMaterialDomain);
 if(right) CFPreferencesSetAppValue(CFSTR("rightMaterial"),(__bridge CFPropertyListRef)right,(__bridge CFStringRef)RSMaterialDomain);
 BOOL saved=CFPreferencesAppSynchronize((__bridge CFStringRef)RSMaterialDomain);
 if(!saved){
  CFPreferencesSetAppValue(CFSTR("leftMaterial"),oldLeft ? (__bridge CFPropertyListRef)oldLeft : NULL,(__bridge CFStringRef)RSMaterialDomain);
  CFPreferencesSetAppValue(CFSTR("rightMaterial"),oldRight ? (__bridge CFPropertyListRef)oldRight : NULL,(__bridge CFStringRef)RSMaterialDomain);
  CFPreferencesAppSynchronize((__bridge CFStringRef)RSMaterialDomain);
 }else RSMaterialNotify();
 return saved;
}
static NSArray<NSString *> *RSMaterialFiles(void) {
 NSArray *all=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:RSMaterialDirectory() error:NULL];
 NSMutableArray *files=[NSMutableArray array];
 for(NSString *name in all)if(RSMaterialIsCustom(name)) [files addObject:name];
 return [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}
static NSDictionary *RSMaterialAliases(void) {
 id names=RSMaterialPref(@"materialDisplayNames");return [names isKindOfClass:NSDictionary.class] ? names : @{};
}
static NSString *RSMaterialTitle(NSString *name) {
 id alias=RSMaterialAliases()[name];if([alias isKindOfClass:NSString.class] && [alias length])return alias;
 if([name isEqualToString:@"builtin:1"])return @"素材 1";
 if([name isEqualToString:@"builtin:2"])return @"素材 2";
 NSRange r=[name rangeOfString:@"--"];
 return r.location==NSNotFound ? name : [name substringFromIndex:NSMaxRange(r)];
}
static NSString *RSMaterialPath(NSString *name) {
 if(RSMaterialIsCustom(name))return [RSMaterialDirectory() stringByAppendingPathComponent:name];
 NSString *file=[name isEqualToString:@"builtin:2"] ? @"replay2.png" : @"replay1.png";
 for(NSString *base in @[@"/var/jb/Library/Application Support/RecordingSharingan/eye",@"/Library/Application Support/RecordingSharingan/eye"]){
  NSString *p=[base stringByAppendingPathComponent:file];if([[NSFileManager defaultManager] fileExistsAtPath:p])return p;
 }
 return nil;
}
static UIImage *RSMaterialThumbnail(NSString *name) {
 NSString *path=RSMaterialPath(name);if(!path)return nil;
 static NSCache *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=64;});
 UIImage *cached=[cache objectForKey:path];if(cached)return cached;
 CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);
 if(!source)return nil;
 NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@132,(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES};
 CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);CFRelease(source);
 if(!cg)return nil;
 UIImage *image=[UIImage imageWithCGImage:cg];CGImageRelease(cg);
 [cache setObject:image forKey:path];return image;
}
static void RSMaterialAlert(UIViewController *vc,NSString *message) {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"素材" message:message preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
 [vc presentViewController:a animated:YES completion:nil];
}
@interface RSMaterialPreviewCell : UITableViewCell
@property(nonatomic,strong) UIImageView *materialPreview;
@end
@implementation RSMaterialPreviewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
 if((self=[super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier])){
  _materialPreview=[[UIImageView alloc] initWithFrame:CGRectZero];_materialPreview.contentMode=UIViewContentModeScaleAspectFit;
  [self.contentView addSubview:_materialPreview];
  self.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.detailTextLabel.textColor=UIColor.secondaryLabelColor;
 }
 return self;
}
- (void)layoutSubviews {
 [super layoutSubviews];CGFloat h=self.contentView.bounds.size.height,w=self.contentView.bounds.size.width;
 self.materialPreview.frame=CGRectMake(16,(h-44)/2,44,44);
 self.textLabel.frame=CGRectMake(74,10,MAX(10,w-90),24);
 self.detailTextLabel.frame=CGRectMake(74,36,MAX(10,w-90),18);
}
@end
@interface RSMaterialListController : UITableViewController
@property(nonatomic,strong) NSArray<NSString *> *files;
@property(nonatomic,assign) BOOL rightSide;
@end
@implementation RSMaterialListController
- (void)viewDidLoad {
 [super viewDidLoad];self.title=self.rightSide ? @"右侧素材" : @"左侧素材";
 self.navigationItem.rightBarButtonItem=self.editButtonItem;self.tableView.rowHeight=68;
}
- (void)viewWillAppear:(BOOL)animated {
 [super viewWillAppear:animated];CFPreferencesAppSynchronize((__bridge CFStringRef)RSMaterialDomain);
 self.files=RSMaterialFiles();[self.tableView reloadData];
}
- (NSString *)nameForIndexPath:(NSIndexPath *)indexPath {
 return indexPath.section==0 ? (indexPath.row==0 ? @"builtin:1" : @"builtin:2") : self.files[indexPath.row];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0 ? 2 : self.files.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0 ? @"内置素材" : @"自定义素材"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
 return section==1 ? (self.files.count ? @"点击选用；左滑可重命名或删除自定义素材。" : @"返回上一页，点击“导入素材”添加 PNG 图片。") : @"左滑可重命名，内置图片始终保留。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
 RSMaterialPreviewCell *cell=[[RSMaterialPreviewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
 NSString *name=[self nameForIndexPath:indexPath];cell.textLabel.text=RSMaterialTitle(name);cell.materialPreview.image=RSMaterialThumbnail(name);
 BOOL left=[RSMaterialChoice(NO) isEqualToString:name],right=[RSMaterialChoice(YES) isEqualToString:name];
 cell.detailTextLabel.text=left && right ? @"左右两侧使用中" : left ? @"左侧使用中" : right ? @"右侧使用中" : @"未使用";
 cell.accessoryType=[RSMaterialChoice(self.rightSide) isEqualToString:name] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
 return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
 [tableView deselectRowAtIndexPath:indexPath animated:YES];NSString *name=[self nameForIndexPath:indexPath];
 if(!RSMaterialThumbnail(name)){RSMaterialAlert(self,@"素材已丢失或损坏，请重新导入。");return;}
 if(!RSMaterialSaveChoices(self.rightSide ? nil : name,self.rightSide ? name : nil))RSMaterialAlert(self,@"无法保存选择，请重试。");
 [tableView reloadData];
}
- (void)renameMaterial:(NSString *)name {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"重命名" message:@"只修改显示名称，图片和当前选择保持不变。" preferredStyle:UIAlertControllerStyleAlert];
 [a addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=RSMaterialTitle(name);field.clearButtonMode=UITextFieldViewModeWhileEditing;}];
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
  NSString *title=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if(!title.length || title.length>40){dispatch_async(dispatch_get_main_queue(),^{RSMaterialAlert(self,@"名称请填写 1～40 个字符。");});return;}
  NSDictionary *old=RSMaterialAliases();NSMutableDictionary *names=[old mutableCopy];names[name]=title;
  CFPreferencesSetAppValue(CFSTR("materialDisplayNames"),(__bridge CFPropertyListRef)names,(__bridge CFStringRef)RSMaterialDomain);
  if(!CFPreferencesAppSynchronize((__bridge CFStringRef)RSMaterialDomain)){
   CFPreferencesSetAppValue(CFSTR("materialDisplayNames"),(__bridge CFPropertyListRef)old,(__bridge CFStringRef)RSMaterialDomain);CFPreferencesAppSynchronize((__bridge CFStringRef)RSMaterialDomain);
   dispatch_async(dispatch_get_main_queue(),^{RSMaterialAlert(self,@"名称保存失败，原名称已保留。");});
  }
  [self.tableView reloadData];
 }]];[self presentViewController:a animated:YES completion:nil];
}
- (void)deleteMaterial:(NSString *)name {
 NSString *oldLeft=RSMaterialChoice(NO),*oldRight=RSMaterialChoice(YES);
 BOOL left=[oldLeft isEqualToString:name],right=[oldRight isEqualToString:name];
 if((left || right) && !RSMaterialSaveChoices(left ? @"builtin:1" : nil,right ? @"builtin:1" : nil)){RSMaterialAlert(self,@"无法切回内置素材，未删除图片。");return;}
 NSError *error=nil;
 if(![[NSFileManager defaultManager] removeItemAtPath:RSMaterialPath(name) error:&error]){
  if(left || right)RSMaterialSaveChoices(left ? oldLeft : nil,right ? oldRight : nil);
  RSMaterialAlert(self,error.localizedDescription ?: @"删除失败。");return;
 }
 self.files=RSMaterialFiles();[self.tableView reloadData];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
 return indexPath.section==1 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
 if(style==UITableViewCellEditingStyleDelete && indexPath.section==1)[self deleteMaterial:[self nameForIndexPath:indexPath]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
 NSString *name=[self nameForIndexPath:indexPath];
 UIContextualAction *rename=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"重命名" handler:^(__unused UIContextualAction *action,__unused UIView *view,void (^done)(BOOL)){done(YES);[self renameMaterial:name];}];
 rename.backgroundColor=UIColor.systemBlueColor;NSMutableArray *actions=[NSMutableArray array];
 if(indexPath.section==1){
  UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(__unused UIContextualAction *action,__unused UIView *view,void (^done)(BOOL)){done(YES);[self deleteMaterial:name];}];[actions addObject:remove];
 }
 [actions addObject:rename];UISwipeActionsConfiguration *config=[UISwipeActionsConfiguration configurationWithActions:actions];config.performsFirstActionWithFullSwipe=NO;return config;
}
@end

@implementation RSRootController
- (void)rsManageLeftMaterials {
 RSMaterialListController *list=[[RSMaterialListController alloc] initWithStyle:UITableViewStyleInsetGrouped];list.rightSide=NO;
 [self.navigationController pushViewController:list animated:YES];
}
- (void)rsManageRightMaterials {
 RSMaterialListController *list=[[RSMaterialListController alloc] initWithStyle:UITableViewStyleInsetGrouped];list.rightSide=YES;
 [self.navigationController pushViewController:list animated:YES];
}
- (void)rsChooseFile {
 UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePNG] asCopy:YES];
 picker.delegate=self;picker.allowsMultipleSelection=YES;
 [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
 NSMutableArray<NSString *> *imported=[NSMutableArray array];
 NSMutableArray<NSString *> *failures=[NSMutableArray array];
 NSFileManager *fm=[NSFileManager defaultManager];NSString *dir=RSMaterialDirectory();
 NSError *directoryError=nil;
 BOOL ready=[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:&directoryError];
 if(ready)[fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:dir error:NULL];
 for(NSURL *url in urls) {
  if(!ready){[failures addObject:directoryError.localizedDescription ?: @"无法创建素材目录"];break;}
  BOOL scoped=[url startAccessingSecurityScopedResource];
  __block NSData *data=nil;__block NSError *readError=nil;
  NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateReadingItemAtURL:url options:0 error:&readError byAccessor:^(NSURL *safeURL) {
   NSNumber *size=nil;[safeURL getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
   if(size && size.unsignedLongLongValue>20*1024*1024)return;
   data=[NSData dataWithContentsOfURL:safeURL options:NSDataReadingMappedIfSafe error:&readError];
  }];
  if(scoped)[url stopAccessingSecurityScopedResource];
  const unsigned char png[8]={137,80,78,71,13,10,26,10};
  BOOL valid=!readError && data.length>=24 && data.length<=20*1024*1024 && memcmp(data.bytes,png,8)==0;
  CGImageSourceRef source=valid ? CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL) : NULL;
  NSDictionary *properties=source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
  NSUInteger width=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
  NSUInteger height=[properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
  valid=valid && width>0 && height>0 && width<=4096 && height<=4096;
  UIImage *image=valid ? [UIImage imageWithData:data] : nil;
  if(source)CFRelease(source);
  if(!image){[failures addObject:[NSString stringWithFormat:@"%@：请选择 20MB 以内、4096×4096 以内的有效 PNG。",url.lastPathComponent]];continue;}
  NSString *name=[NSString stringWithFormat:@"custom-%@--%@",NSUUID.UUID.UUIDString,url.lastPathComponent];
  NSString *target=[dir stringByAppendingPathComponent:name];NSError *writeError=nil;
  if(![data writeToFile:target options:NSDataWritingAtomic error:&writeError]) {
   [failures addObject:writeError.localizedDescription ?: @"保存失败"];continue;
  }
  if(![fm setAttributes:@{NSFilePosixPermissions:@0644,NSFileProtectionKey:NSFileProtectionNone} ofItemAtPath:target error:&writeError]) {
   [fm removeItemAtPath:target error:NULL];[failures addObject:writeError.localizedDescription ?: @"无法设置读取权限"];continue;
  }
  [imported addObject:name];
 }
 NSString *message=imported.count ? [NSString stringWithFormat:@"已添加 %lu 张素材，可分别设置左右两侧。",(unsigned long)imported.count] : @"未导入素材，原来的选择和图片已保留。";
 if(failures.count)message=[message stringByAppendingFormat:@"\n%@",[failures componentsJoinedByString:@"\n"]];
 [controller dismissViewControllerAnimated:YES completion:^{
  if(!imported.count){RSMaterialAlert(self,message);return;}
  NSString *name=imported.lastObject;
  UIAlertController *a=[UIAlertController alertControllerWithTitle:@"导入完成" message:message preferredStyle:UIAlertControllerStyleAlert];
  NSArray *titles=@[@"左侧使用",@"右侧使用",@"两侧使用"];
  for(NSInteger i=0;i<3;i++){
   NSInteger target=i;
   [a addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
    if(!RSMaterialSaveChoices(target==1 ? nil : name,target==0 ? nil : name))dispatch_async(dispatch_get_main_queue(),^{RSMaterialAlert(self,@"选用失败，图片已保存，请到素材列表重新选择。");});
   }]];
  }
  [a addAction:[UIAlertAction actionWithTitle:@"稍后选择" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
 }];
}

- (NSArray *)specifiers {
 if (!_specifiers) {
  NSString *root = [[NSBundle bundleForClass:[self class]] pathForResource:@"Root" ofType:@"plist"];
  NSLog(@"[RecordingSharinganPrefs] controller loaded, Root.plist=%@, bundle=%@", root ?: @"MISSING", [NSBundle bundleForClass:[self class]].bundlePath);
  NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
  if (loaded.count) {
   _specifiers = [loaded mutableCopy];
  } else {
   NSLog(@"[RecordingSharinganPrefs] ERROR: Root specifiers missing or empty");
   PSSpecifier *error = [PSSpecifier preferenceSpecifierNamed:@"设置加载失败：Root.plist 未读取" target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:Nil];
   _specifiers = [@[error] mutableCopy];
  }
 }
 return _specifiers;
}
- (void)resetDefaults {
 NSString *domain=@"com.tu.recordingsharingan.settings";
 NSDictionary *defaults=@{@"rotationSpeed":@1.0,@"leftXOffset":@0.0,@"rightXOffset":@0.0,@"yOffset":@0.0,@"leftSize":@31.0,@"rightSize":@37.0};
 for(NSString *key in defaults)CFPreferencesSetAppValue((__bridge CFStringRef)key,(__bridge CFPropertyListRef)defaults[key],(__bridge CFStringRef)domain);
 CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
 CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.tu.recordingsharingan.settings.changed"),NULL,NULL,YES);
 [self reloadSpecifiers];
}
- (void)rsOpenVolumeSettings {
 NSArray *paths=@[@"/var/jb/Library/PreferenceBundles/RSIslandVolumePrefs.bundle",@"/Library/PreferenceBundles/RSIslandVolumePrefs.bundle",[[[NSBundle bundleForClass:self.class] bundlePath].stringByDeletingLastPathComponent stringByAppendingPathComponent:@"RSIslandVolumePrefs.bundle"]];
 for(NSString *path in paths) { NSBundle *bundle=[NSBundle bundleWithPath:path]; if(bundle && [bundle load]) break; }
 Class cls=NSClassFromString(@"RSIVSettingsController");
 if(cls) { UIViewController *controller=[[cls alloc] init]; [self.navigationController pushViewController:controller animated:YES]; }
 else { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"音量设置未加载" message:@"音量设置组件缺失，请重新安装完整 DEB。" preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
}
@end
