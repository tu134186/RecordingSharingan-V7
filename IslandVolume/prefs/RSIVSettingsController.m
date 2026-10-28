// RecordingSharingan integration UI for Crescendo-derived module. GPL-3.0.
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../RSIVPrefs.h"
@interface RSIVSettingsController : PSListController @end
@implementation RSIVSettingsController
- (NSArray *)specifiers {
 if (!_specifiers) _specifiers=[[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
 return _specifiers;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"音乐音量控制"; RSIVPrefsPublishState(); }
- (id)readPreferenceValue:(PSSpecifier *)specifier {
 CFPreferencesAppSynchronize(CFSTR(kRSIVPrefsDomain));
 id value=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[specifier propertyForKey:@"key"],CFSTR(kRSIVPrefsDomain)));
 return value ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
 CFPreferencesSetAppValue((__bridge CFStringRef)[specifier propertyForKey:@"key"],(__bridge CFPropertyListRef)value,CFSTR(kRSIVPrefsDomain));
 CFPreferencesAppSynchronize(CFSTR(kRSIVPrefsDomain));
 RSIVPrefsPublishState();
}
- (void)showCredits {
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"开源致谢" message:@"音量模块基于 Yves000 / Crescendo，遵循 GPL-3.0。上游提交：33c60a69。整合源码、修改说明与许可证随本项目源码公开。" preferredStyle:UIAlertControllerStyleAlert];
 [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
 [self presentViewController:alert animated:YES completion:nil];
}
@end
