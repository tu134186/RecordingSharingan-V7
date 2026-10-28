#import "RSAdjustCell.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
static NSString *const domain = @"com.tu.recordingsharingan.settings";
static NSString *const notification = @"com.tu.recordingsharingan.settings.changed";
@interface RSAdjustCell ()
@property(nonatomic,strong) UISlider *slider;
@property(nonatomic,strong) UILabel *number;
@property(nonatomic,strong) UIButton *minus;
@property(nonatomic,strong) UIButton *plus;
@end
@implementation RSAdjustCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse specifier:(PSSpecifier *)spec {
 self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse specifier:spec]; if(!self)return nil;
 _slider=[UISlider new];_number=[UILabel new];_minus=[UIButton buttonWithType:UIButtonTypeSystem];_plus=[UIButton buttonWithType:UIButtonTypeSystem];
 [_minus setTitle:@"−" forState:UIControlStateNormal];[_plus setTitle:@"+" forState:UIControlStateNormal];
 _minus.titleLabel.font=[UIFont boldSystemFontOfSize:25];_plus.titleLabel.font=[UIFont boldSystemFontOfSize:25];
 _number.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];_number.textAlignment=NSTextAlignmentRight;
 [_slider addTarget:self action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
 [_minus addTarget:self action:@selector(decrease) forControlEvents:UIControlEventTouchUpInside];[_plus addTarget:self action:@selector(increase) forControlEvents:UIControlEventTouchUpInside];
 for(UIView *v in @[_slider,_number,_minus,_plus]) [self.contentView addSubview:v];
 self.selectionStyle=UITableViewCellSelectionStyleNone;[self reload];return self;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)spec { [super refreshCellContentsWithSpecifier:spec];[self reload]; }
- (void)reload {
 self.textLabel.text=self.specifier.name;self.slider.minimumValue=[[self.specifier propertyForKey:@"min"] floatValue];self.slider.maximumValue=[[self.specifier propertyForKey:@"max"] floatValue];
 NSString *key=[self.specifier propertyForKey:@"key"];CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
 CFPropertyListRef val=CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)domain);
 float v=val?[(__bridge id)val floatValue]:[[self.specifier propertyForKey:@"default"] floatValue];if(val)CFRelease(val);
 self.slider.value=fmaxf(self.slider.minimumValue,fminf(self.slider.maximumValue,v));[self showValue];
}
- (void)layoutSubviews {
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
- (void)showValue {self.number.text=[NSString stringWithFormat:@"%.1f",self.slider.value];}
- (void)save { NSString *key=[self.specifier propertyForKey:@"key"];if(!key)return;
 CFPreferencesSetAppValue((__bridge CFStringRef)key,(__bridge CFPropertyListRef)@(self.slider.value),(__bridge CFStringRef)domain);
 CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
 CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge CFStringRef)notification,NULL,NULL,YES);[self showValue];}
- (void)slide:(UISlider *)s {[self save];}
- (void)decrease {[self adjust:-0.1f];}
- (void)increase {[self adjust:0.1f];}
- (void)adjust:(float)d {self.slider.value=fmaxf(self.slider.minimumValue,fminf(self.slider.maximumValue,roundf((self.slider.value+d)*10.0f)/10.0f));[self save];}
@end
