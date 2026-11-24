#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/*
 * LCUpdateAssistant · LiveContainer 软件源辅助 (v1.2 解锁版)
 *
 * 功能：
 *   1. App 回前台静默查源，发现新版本弹窗提示 + 复制/打开源地址
 *   2. 摇一摇呼出「卡密解锁」窗口，输入卡密 + UDID，直接调 api.php?action=activate 激活
 *   3. 激活成功后自动记录 UDID，方便下次预填，并给出带 udid 的专属源地址
 *
 * 为什么要摇一摇：
 *   guest App 里没法加按钮，也没法可靠唤起外部 App；摇一摇是 UIResponder 原生事件，
 *   不干扰正常操作，随时能呼出解锁框。
 *
 * 硬限制（写在前面，别踩坑）：
 *   iOS 普通 App 拿不到真机 UDID，identifierForVendor 跟后台设备表对不上。
 *   所以 UDID 必须用户从描述文件获取后手输/粘贴，插件不假装能自动拿。
 *
 * v1.2 相对 v1.1：新增摇一摇解锁；apiURL/apiKey 配置；激活结果直接显示。
 * v1.1 修复：observer 强引用；key 按 App 分开；去掉 canOpenURL；首次提示；弹窗重试。
 */

// -------- 可改配置（改完 make 一次）--------
static NSString *const kDefaultSourceURL = @"https://app.baqu.net/altstore.php/apps.json";
static NSString *const kDefaultAPIURL    = @"https://app.baqu.net/api.php";
static NSString *const kDefaultAPIKey    = @"";   // 后台「API密钥」为空就留空；填了则必须一致
static NSTimeInterval const kCheckInterval = 1800.0;
static BOOL const kEnableFirstRunHint = YES;
static BOOL const kEnableShakeUnlock  = YES;
static BOOL const kEnableFloatButton  = YES;   // 常驻悬浮设置按钮
static NSString *const kButtonHiddenKey = @"lcua_float_hidden";
// ------------------------------------------

// observer 必须强引用持有
static id lcNotificationObserver = nil;

static NSString *LCConfigValue(NSString *key, NSString *fallback) {
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.internal.lcupdateassistant.plist",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/com.internal.lcupdateassistant.plist"]
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d) continue;
        NSString *v = d[key];
        if ([v isKindOfClass:[NSString class]] && v.length > 0) return v;
    }
    return fallback;
}

static NSString *LCSourceURL(void) { return LCConfigValue(@"sourceURL", kDefaultSourceURL); }
static NSString *LCAPIURL(void)    { return LCConfigValue(@"apiURL", kDefaultAPIURL); }
static NSString *LCAPIKey(void)    { return LCConfigValue(@"apiKey", kDefaultAPIKey); }

static NSString *LCKey(NSString *base) {
    NSString *bid = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"] ?: @"unknown";
    return [base stringByAppendingFormat:@"_%@", bid];
}

static NSString *LCURLEncode(NSString *s) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_.~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static UIViewController *LCTopVCFromWindow(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        if (nav.visibleViewController) vc = nav.visibleViewController;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        if (tab.selectedViewController) vc = tab.selectedViewController;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static UIViewController *LCTopVC(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIViewController *vc = app.keyWindow ? LCTopVCFromWindow(app.keyWindow) : nil;
    if (vc) return vc;
    for (UIWindow *w in app.windows) {
        if (w.rootViewController) {
            vc = LCTopVCFromWindow(w);
            if (vc) return vc;
        }
    }
    return nil;
}

static void LCPresent(UIAlertController *alert, NSInteger retry) {
    UIViewController *top = LCTopVC();
    if (top) {
        if (top.presentedViewController) return;
        [top presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (retry <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LCPresent(alert, retry - 1); });
}

static void LCShowAlert(NSString *title, NSString *msg, NSArray *actions) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        for (UIAlertAction *act in actions) [a addAction:act];
        LCPresent(a, 4);
    });
}

static void LCCopy(NSString *text) {
    if (text.length) [UIPasteboard generalPasteboard].string = text;
}

static NSComparisonResult LCCompareVersion(NSString *a, NSString *b) {
    return [a compare:b options:NSNumericSearch];
}

// ================= 更新检测 =================
static void LCShowUpdateAlert(NSString *appName, NSString *localVer, NSString *remoteVer, NSString *sourceURL) {
    NSString *msg = [NSString stringWithFormat:
        @"本机 %@ → 源里 %@\n\n请回 LiveContainer 添加/刷新这个源后更新安装：\n%@",
        localVer ?: @"?", remoteVer ?: @"?", sourceURL];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"%@ 有新版本", appName ?: @"应用"]
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制源地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCCopy(sourceURL);
    }]];
    NSURL *url = [NSURL URLWithString:sourceURL];
    if (url) {
        [alert addAction:[UIAlertAction actionWithTitle:@"打开源地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
                if (!ok) dispatch_async(dispatch_get_main_queue(), ^{ LCCopy(sourceURL); });
            }];
        }]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ LCPresent(alert, 4); });
}

static void LCRunCheck(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *lastKey = LCKey(@"lcua_last_check");
    NSDate *last = [ud objectForKey:lastKey];
    if (last && -[last timeIntervalSinceNow] < kCheckInterval) return;
    [ud setObject:[NSDate date] forKey:lastKey];

    NSURL *url = [NSURL URLWithString:LCSourceURL()];
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) return;
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
        if (je || ![obj isKindOfClass:[NSDictionary class]]) return;
        NSArray *apps = ((NSDictionary *)obj)[@"apps"];
        if (![apps isKindOfClass:[NSArray class]]) return;

        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        NSString *bid = [info objectForKey:@"CFBundleIdentifier"] ?: @"";
        NSString *localVer = [info objectForKey:@"CFBundleShortVersionString"] ?: @"";
        if (bid.length == 0) return;
        NSString *appName = [info objectForKey:@"CFBundleDisplayName"] ?: [info objectForKey:@"CFBundleName"] ?: bid;

        for (id item in apps) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *app = (NSDictionary *)item;
            if (![[app[@"bundleIdentifier"] description] isEqualToString:bid]) continue;
            NSString *remoteVer = [app[@"version"] description] ?: @"";
            if (remoteVer.length == 0 || LCCompareVersion(remoteVer, localVer) != NSOrderedDescending) return;
            NSString *shownKey = LCKey(@"lcua_shown_version");
            if ([[ud stringForKey:shownKey] isEqualToString:remoteVer]) return;
            [ud setObject:remoteVer forKey:shownKey];
            [ud synchronize];
            LCShowUpdateAlert(appName, localVer, remoteVer, LCSourceURL());
            return;
        }
    }] resume];
}

// ================= 卡密解锁 =================
static void LCDoActivate(NSString *cardKey, NSString *deviceId) {
    cardKey = [cardKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    deviceId = [deviceId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cardKey.length == 0 || deviceId.length == 0) {
        LCShowAlert(@"填写不完整", @"卡密和 UDID 都要填。UDID 需要用 Safari 装描述文件获取。",
            @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
        return;
    }

    NSString *api = LCAPIURL();
    NSURL *url = [NSURL URLWithString:api];
    if (!url) {
        LCShowAlert(@"地址无效", @"apiURL 配置不正确，请检查源码常量或 plist。",
            @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
        return;
    }

    NSString *body = [NSString stringWithFormat:@"action=activate&card_key=%@&device_id=%@&api_key=%@",
        LCURLEncode(cardKey), LCURLEncode(deviceId), LCURLEncode(LCAPIKey())];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            LCShowAlert(@"激活失败", err.localizedDescription,
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&je];
        if (je || ![obj isKindOfClass:[NSDictionary class]]) {
            NSString *raw = [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
            LCShowAlert(@"激活失败", [NSString stringWithFormat:@"后台返回无法解析：%@", [raw substringToIndex:MIN(raw.length, 200)]],
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        NSDictionary *res = (NSDictionary *)obj;
        BOOL ok = [[res objectForKey:@"success"] boolValue];
        NSString *message = [res objectForKey:@"message"] ?: (ok ? @"激活成功" : @"激活失败");

        if (ok) {
            // 记住 UDID，下次预填
            [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:@"lcua_last_udid"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            // 专属源地址：带上刚激活的 udid
            NSString *src = LCSourceURL();
            NSString *udidSrc = [src rangeOfString:@"?"].location == NSNotFound
                ? [src stringByAppendingFormat:@"?udid=%@", LCURLEncode(deviceId)]
                : [src stringByAppendingFormat:@"&udid=%@", LCURLEncode(deviceId)];
            NSString *msg = [NSString stringWithFormat:@"%@\n\n专属源地址（已带 UDID）：\n%@\n\n请回 LiveContainer 添加/刷新这个源，付费 App 就会出现。", message, udidSrc];
            LCShowAlert(@"解锁成功", msg, @[
                [UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil],
                [UIAlertAction actionWithTitle:@"复制专属源地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    LCCopy(udidSrc);
                }]
            ]);
        } else {
            LCShowAlert(@"解锁失败", message,
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
        }
    }] resume];
}

static void LCShowUnlockDialog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lcua_last_udid"] ?: @"";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡密解锁"
            message:@"输入卡密和 UDID，直接向服务器激活。\nUDID 需用 Safari 装描述文件获取，普通 App 拿不到真 UDID。"
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"卡密";
            tf.secureTextEntry = YES;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"设备 UDID";
            tf.text = saved;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *card = alert.textFields.count > 0 ? alert.textFields[0].text : @"";
            NSString *udid = alert.textFields.count > 1 ? alert.textFields[1].text : @"";
            LCDoActivate(card, udid);
        }]];
        LCPresent(alert, 4);
    });
}

// ============ 常驻悬浮设置按钮 ============
static UIView *lcFloatButton = nil;

static NSString *const kButtonYKey = @"lcua_btn_y";   // 相对屏幕高度比例 0~1

static void LCShowSettingsMenu(void);

// 自定义按钮视图：自己处理拖动和点击（纯 ObjC，不依赖 Logos）
@interface LCFloatButtonView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onMove)(CGFloat x, CGFloat yRatio);
@end

@implementation LCFloatButtonView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.layer.cornerRadius = frame.size.width / 2;
    self.backgroundColor = [UIColor colorWithRed:0.36 green:0.24 blue:0.72 alpha:0.92];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.32;
    self.layer.shadowRadius = 6;
    self.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
    label.text = @"设置";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont boldSystemFontOfSize:14];
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    [self addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lcTapped)];
    [self addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(lcPanned:)];
    [self addGestureRecognizer:pan];
    return self;
}

- (void)lcTapped {
    if (self.onTap) self.onTap();
}

- (void)lcPanned:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint p = [g translationInView:win];
    CGPoint c = self.center;
    c.x += p.x;
    c.y += p.y;
    c.x = MAX(28, MIN(c.x, win.bounds.size.width - 28));
    c.y = MAX(80, MIN(c.y, win.bounds.size.height - 70));
    self.center = c;
    [g setTranslation:CGPointZero inView:win];
    if (g.state == UIGestureRecognizerStateEnded && self.onMove) {
        self.onMove(self.frame.origin.x, self.frame.origin.y / win.bounds.size.height);
    }
}
@end

static void LCPositionButton(UIView *btn) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    CGSize ws = win.bounds.size;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat x = [ud floatForKey:kButtonXKey];
    CGFloat yRatio = [ud floatForKey:kButtonYKey];
    if (x <= 0) x = ws.width - 66;          // 默认右侧
    if (yRatio <= 0) yRatio = 0.42;          // 默认偏上
    x = MAX(4, MIN(x, ws.width - 56));
    CGFloat y = MAX(60, MIN(yRatio * ws.height, ws.height - 100));
    btn.frame = CGRectMake(x, y, 52, 52);
}

static void LCHideFloatButton(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kButtonHiddenKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (lcFloatButton) [lcFloatButton removeFromSuperview];
}

static UIView *LCMakeFloatButton(void) {
    return [[LCFloatButtonView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
}

static void LCAttachFloatButton(void) {
    if (!kEnableFloatButton) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kButtonHiddenKey]) return;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LCAttachFloatButton(); });
        return;
    }
    if (lcFloatButton && lcFloatButton.superview == win) { LCPositionButton(lcFloatButton); return; }

    LCFloatButtonView *btn = (LCFloatButtonView *)LCMakeFloatButton();
    if (!lcFloatButton) lcFloatButton = btn;
    [win addSubview:lcFloatButton];
    LCPositionButton(lcFloatButton);

    __weak UIView *weakBtn = lcFloatButton;
    ((LCFloatButtonView *)lcFloatButton).onTap = ^{ LCShowSettingsMenu(); };
    ((LCFloatButtonView *)lcFloatButton).onMove = ^(CGFloat x, CGFloat yRatio) {
        UIView *b = weakBtn;
        if (!b) return;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setFloat:x forKey:kButtonXKey];
        [ud setFloat:yRatio forKey:kButtonYKey];
        [ud synchronize];
    };
}

static void LCShowSettingsMenu(void) {
    NSString *src = LCSourceURL();
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lcua_last_udid"] ?: @"";
    NSString *u = src;
    if (saved.length) {
        u = ([src rangeOfString:@"?"].location == NSNotFound)
            ? [src stringByAppendingFormat:@"?udid=%@", LCURLEncode(saved)]
            : [src stringByAppendingFormat:@"&udid=%@", LCURLEncode(saved)];
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"LC 辅助设置"
        message:[NSString stringWithFormat:@"源：%@\nUDID：%@", src, saved.length ? saved : @"未记录"]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"卡密解锁（输入卡密 + UDID）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCShowUnlockDialog();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制专属源地址（带 UDID）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCCopy(u);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"立即检查更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:LCKey(@"lcua_last_check")];
        LCRunCheck();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏此按钮" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        LCHideFloatButton();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = lcFloatButton;
    sheet.popoverPresentationController.sourceRect = lcFloatButton.bounds;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = LCTopVC();
        if (top && !top.presentedViewController) [top presentViewController:sheet animated:YES completion:nil];
    });
}

static void LCFirstRunHint(void) {
    if (!kEnableFirstRunHint) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:@"lcua_first_run_done"]) return;
    [ud setBool:YES forKey:@"lcua_first_run_done"];
    [ud synchronize];
    NSString *msg = kEnableShakeUnlock
        ? @"插件正在工作。\n\n· 有新版本会自动提示\n· 想解锁：摇一摇手机，输入卡密 + UDID 即可激活"
        : @"插件正在工作，发现新版本会提示。";
    LCShowAlert(@"LCUpdateAssistant 已加载", msg,
        @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
}

// ============ 原生 runtime hook（不依赖 Logos / CydiaSubstrate）============
// 摇一摇：给 UIApplication 加 motionBegan:withEvent: 的实现，保存父类原 IMP 并调用
static IMP lcOrigMotionBegan = NULL;

static void lcMotionBeganHook(id self, SEL _cmd, UIEventSubtype motion, UIEvent *event) {
    if (lcOrigMotionBegan) {
        ((void (*)(id, SEL, UIEventSubtype, UIEvent *))lcOrigMotionBegan)(self, _cmd, motion, event);
    }
    if (kEnableShakeUnlock && motion == UIEventSubtypeMotionShake) {
        LCShowUnlockDialog();
    }
}

__attribute__((constructor)) static void lcInit(void) {
    @autoreleasepool {
        // 只 hook UIApplication 自己，不动 UIResponder 父类，避免影响所有响应者
        Method parentMethod = class_getInstanceMethod([UIApplication class], @selector(motionBegan:withEvent:));
        if (parentMethod) {
            const char *types = method_getTypeEncoding(parentMethod);
            lcOrigMotionBegan = method_getImplementation(parentMethod);
            class_addMethod([UIApplication class], @selector(motionBegan:withEvent:), (IMP)lcMotionBeganHook, types);
        }
        // 回前台通知
        lcNotificationObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidBecomeActiveNotification"
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    LCFirstRunHint();
                    LCAttachFloatButton();
                    LCRunCheck();
                });
            }];
    }
}
