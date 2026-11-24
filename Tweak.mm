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
static BOOL const kEnableFirstRunHint = NO;   // 首次弹窗已关闭（太烦）
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
// 通用 POST：action -> 服务器 JSON
static void LCAPICall(NSString *action, NSDictionary *params, void (^done)(NSDictionary *res, NSString *errMsg)) {
    NSURL *url = [NSURL URLWithString:LCAPIURL()];
    if (!url) { done(nil, @"apiURL 配置不正确"); return; }

    NSMutableString *body = [NSMutableString stringWithFormat:@"action=%@&api_key=%@", LCURLEncode(action), LCURLEncode(LCAPIKey())];
    [params enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [body appendFormat:@"&%@=%@", LCURLEncode(k), LCURLEncode(v)];
    }];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { done(nil, err.localizedDescription); return; }
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&je];
        if (je || ![obj isKindOfClass:[NSDictionary class]]) {
            NSString *raw = [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
            done(nil, [NSString stringWithFormat:@"后台返回无法解析：%@", [raw substringToIndex:MIN(raw.length, 160)]]);
            return;
        }
        done((NSDictionary *)obj, nil);
    }] resume];
}

// 解锁成功后的统一提示：记 UDID + 给带 udid 的专属源
static void LCUnlockSuccess(NSString *udid, NSString *message) {
    [[NSUserDefaults standardUserDefaults] setObject:udid forKey:@"lcua_last_udid"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSString *src = LCSourceURL();
    NSString *udidSrc = ([src rangeOfString:@"?"].location == NSNotFound)
        ? [src stringByAppendingFormat:@"?udid=%@", LCURLEncode(udid)]
        : [src stringByAppendingFormat:@"&udid=%@", LCURLEncode(udid)];
    NSString *msg = [NSString stringWithFormat:@"%@\n\n专属源地址（已带 UDID）：\n%@\n\n请回 LiveContainer 添加/刷新这个源，付费 App 就会出现。", message, udidSrc];
    LCShowAlert(@"解锁成功", msg, @[
        [UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil],
        [UIAlertAction actionWithTitle:@"复制专属源地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { LCCopy(udidSrc); }]
    ]);
}

// 路径 A：两个都填 —— 新卡首次激活（原逻辑）
static void LCActivateBoth(NSString *card, NSString *udid) {
    LCAPICall(@"activate", @{@"card_key": card, @"device_id": udid}, ^(NSDictionary *res, NSString *errMsg) {
        if (errMsg) { LCShowAlert(@"激活失败", errMsg, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }
        BOOL ok = [[res objectForKey:@"success"] boolValue];
        NSString *msg = [res objectForKey:@"message"] ?: (ok ? @"激活成功" : @"激活失败");
        if (ok) LCUnlockSuccess(udid, msg);
        else LCShowAlert(@"激活失败", msg, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
    });
}

// 路径 B：只填 UDID —— 已激活未过期的设备直接放行（validate）
static void LCValidateUdid(NSString *udid) {
    LCAPICall(@"validate", @{@"device_id": udid}, ^(NSDictionary *res, NSString *errMsg) {
        if (errMsg) { LCShowAlert(@"验证失败", errMsg, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }
        BOOL ok = [[res objectForKey:@"success"] boolValue];
        NSString *msg = [res objectForKey:@"message"] ?: @"";
        if (!ok) {
            LCShowAlert(@"未解锁", [NSString stringWithFormat:@"该 UDID 未激活或已过期：%@", msg],
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        NSDictionary *data = [res objectForKey:@"data"];
        NSString *expire = [data objectForKey:@"expire_time"] ?: @"";
        NSString *left = [data objectForKey:@"days_left"] ?: @"";
        NSString *detail = [NSString stringWithFormat:@"设备已激活，未过期。\n到期：%@\n剩余：%@ 天", expire, left];
        LCUnlockSuccess(udid, detail);
    });
}

// 路径 C：只填卡密 —— query 拿绑定 UDID，再 validate 确认未过期
static void LCQueryCard(NSString *card) {
    LCAPICall(@"query", @{@"card_key": card}, ^(NSDictionary *res, NSString *errMsg) {
        if (errMsg) { LCShowAlert(@"查询失败", errMsg, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }
        BOOL ok = [[res objectForKey:@"success"] boolValue];
        if (!ok) {
            LCShowAlert(@"查询失败", [res objectForKey:@"message"] ?: @"卡密不存在",
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        NSDictionary *data = [res objectForKey:@"data"];
        NSString *bind = [data objectForKey:@"bind_device"] ?: @"";
        NSString *status = [data objectForKey:@"status_name"] ?: @"";
        if (bind.length == 0) {
            LCShowAlert(@"卡密未绑定设备", [NSString stringWithFormat:@"状态：%@\n这张卡还没绑定 UDID，请卡密和 UDID 一起填来首次激活。", status],
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        // 拿到绑定 UDID 后，走 validate 确认未过期（复用路径 B）
        LCValidateUdid(bind);
    });
}

// 统一入口：两个都填=激活；只填卡密=查询绑定设备；只填UDID=验证已激活
static void LCUnlock(NSString *card, NSString *udid) {
    card = [card stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    udid = [udid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (card.length == 0 && udid.length == 0) {
        LCShowAlert(@"填写不完整", @"卡密和 UDID 至少填一个。\n两个都填 = 新卡激活；只填卡密 = 查绑定设备；只填 UDID = 验证已激活设备。",
            @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
        return;
    }
    if (card.length > 0 && udid.length > 0) LCActivateBoth(card, udid);
    else if (udid.length > 0) LCValidateUdid(udid);
    else LCQueryCard(card);
}

static void LCShowUnlockDialog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lcua_last_udid"] ?: @"";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡密解锁"
            message:@"已激活未过期的：只填卡密 或 只填 UDID 即可。\n新卡首次激活：两个都填。\nUDID 需用 Safari 装描述文件获取。"
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"卡密（已激活的填这个即可）";
            tf.secureTextEntry = YES;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"设备 UDID（已激活的填这个即可）";
            tf.text = saved;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"解锁" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *card = alert.textFields.count > 0 ? alert.textFields[0].text : @"";
            NSString *udid = alert.textFields.count > 1 ? alert.textFields[1].text : @"";
            LCUnlock(card, udid);
        }]];
        LCPresent(alert, 4);
    });
}

// ============ 顶部固定「激活软件源」按钮 ============
static UIView *lcFloatButton = nil;

static void LCShowSettingsMenu(void);

// 胶囊按钮：纯 ObjC 自定义 view，只处理点击（固定位置，不拖动）
@interface LCFloatButtonView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation LCFloatButtonView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.layer.cornerRadius = frame.size.height / 2;
    self.layer.masksToBounds = YES;
    self.backgroundColor = [UIColor colorWithRed:0.36 green:0.24 blue:0.72 alpha:0.92];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 5;
    self.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
    label.text = @"激活软件源";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont boldSystemFontOfSize:13];
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    [self addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lcTapped)];
    [self addGestureRecognizer:tap];
    return self;
}

- (void)lcTapped { if (self.onTap) self.onTap(); }
@end

// -------- 只在 LiveContainer 的「源」页显示按钮 --------
// SwiftUI TabView 底层是 UITabBarController；"源"是第 0 个 tab。
// 递归找 UITabBarController，判断 selectedIndex==0；同时确认当前是 LiveContainer 本体而非 guest App。
static UITabBarController *LCFindTabBar(UIViewController *vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:[UITabBarController class]]) return (UITabBarController *)vc;
    for (UIViewController *child in vc.childViewControllers) {
        UITabBarController *t = LCFindTabBar(child);
        if (t) return t;
    }
    if (vc.presentedViewController) {
        UITabBarController *t = LCFindTabBar(vc.presentedViewController);
        if (t) return t;
    }
    return nil;
}

static BOOL LCIsLiveContainerApp(void) {
    NSBundle *main = [NSBundle mainBundle];
    NSString *bid = [[main infoDictionary] objectForKey:@"CFBundleIdentifier"] ?: @"";
    if ([bid rangeOfString:@"livecontainer"].location == NSNotFound) return NO;
    // 关键：guest App 里 mainBundle 被 LiveContainer patch 成客制 App，
    // 但 lcMainBundle 始终是宿主。本体里两者相同；不同则一定是 guest，直接否掉。
    // LiveContainer 在 NSUserDefaults 上加了 +lcMainBundle category（私有 API）。
    // 用 runtime 调，避免编译期找不到方法声明。
    NSBundle *host = nil;
    if ([NSUserDefaults respondsToSelector:NSSelectorFromString(@"lcMainBundle")]) {
        @try {
            IMP imp = [NSUserDefaults methodForSelector:NSSelectorFromString(@"lcMainBundle")];
            host = ((NSBundle *(*)(id, SEL))imp)([NSUserDefaults class], NSSelectorFromString(@"lcMainBundle"));
        } @catch (...) { host = nil; }
    }
    if (host && host != main) return NO;
    // 再兜底：客制 App 的 mainBundle 若指向非 LiveContainer.app 路径也否掉
    NSString *path = [main bundlePath] ?: @"";
    if ([path rangeOfString:@"LiveContainer.app"].location == NSNotFound) return NO;
    return YES;
}

static BOOL LCIsOnSourcesTab(void) {
    if (!LCIsLiveContainerApp()) return NO;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UITabBarController *tab = LCFindTabBar(win.rootViewController);
    if (!tab) return NO;
    return tab.selectedIndex == 0;
}

// -------- 诊断：拉专属源，解读 deviceState / 描述 / 应用数 --------
static void LCDiagnoseSource(void) {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lcua_last_udid"] ?: @"";
    NSString *src = LCSourceURL();
    if (saved.length) {
        src = ([src rangeOfString:@"?"].location == NSNotFound)
            ? [src stringByAppendingFormat:@"?udid=%@", LCURLEncode(saved)]
            : [src stringByAppendingFormat:@"&udid=%@", LCURLEncode(saved)];
    }
    NSURL *url = [NSURL URLWithString:src];
    if (!url) { LCShowAlert(@"诊断失败", @"源地址无效", @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }

    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) { LCShowAlert(@"诊断失败", err.localizedDescription, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *state = http ? ([http.allHeaderFields objectForKey:@"X-AltStore-Device-State"] ?: @"(无)") : @"(无)";
        NSString *unlocked = http ? ([http.allHeaderFields objectForKey:@"X-AltStore-Unlocked"] ?: @"?") : @"?";
        NSString *bindReason = http ? ([http.allHeaderFields objectForKey:@"X-AltStore-Bind-Reason"] ?: @"") : @"";

        NSString *desc = @"";
        NSInteger appCount = -1;
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&je];
        if (!je && [obj isKindOfClass:[NSDictionary class]]) {
            desc = [obj objectForKey:@"description"] ?: @"";
            NSArray *apps = [obj objectForKey:@"apps"];
            if ([apps isKindOfClass:[NSArray class]]) appCount = (NSInteger)apps.count;
        }

        NSString *statusLine = [NSString stringWithFormat:@"HTTP %ld · 解锁头=%@ · 设备状态=%@ · 应用数=%ld",
            (long)(http ? http.statusCode : 0), unlocked, state, (long)appCount];
        NSString *advice = @"";
        if ([state isEqualToString:@"foreign"] || [bindReason isEqualToString:@"ip"]) {
            advice = @"\n\n【付费应用不出的原因】当前网络与首次绑定网络不一致：\n1) 用手机 Safari 打开一次 https://app.baqu.net 首页；\n2) 回 LiveContainer 下拉刷新专属源；\n3) 仍不行到后台「设备管理→详情」解绑后刷新。";
        } else if ([state isEqualToString:@"expired"]) {
            advice = @"\n\n授权已过期，续期后刷新自动恢复付费应用。";
        } else if ([state isEqualToString:@"disabled"] || [state isEqualToString:@"blacklisted"]) {
            advice = @"\n\n设备被禁用/拉黑，联系管理员处理。";
        } else if ([state isEqualToString:@"not_found"] || [state isEqualToString:@"invalid"]) {
            advice = @"\n\n设备未激活或 UDID 不对，先在插件里解锁。";
        } else if ([state isEqualToString:@"ok"]) {
            advice = @"\n\n设备状态正常。若仍只有免费应用，确认你添加的是「带 UDID 的专属源地址」而不是不带参数的普通源。";
        } else {
            advice = @"\n\n未拿到设备状态——很可能添加的是不带 UDID 的普通源。请用菜单里「复制专属源地址（带 UDID）」重新添加。";
        }
        NSString *msg = [NSString stringWithFormat:@"%@\n\n源描述：%@%@", statusLine,
            desc.length > 120 ? [desc substringToIndex:120] : (desc.length ? desc : @"(无)"), advice];
        LCShowAlert(@"软件源诊断", msg, @[
            [UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil],
            [UIAlertAction actionWithTitle:@"复制诊断信息" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { LCCopy(msg); }]
        ]);
    }] resume];
}

static UIView *LCMakeFloatButton(void) {
    return [[LCFloatButtonView alloc] initWithFrame:CGRectMake(0, 0, 108, 36)];
}

// 固定在顶部中间：安全区下沿 + 6pt，水平居中
static void LCPositionButton(UIView *btn) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    CGFloat top = 0;
    if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top;
    if (top <= 0) top = 44;                 // 兜底：状态栏+导航区高度
    CGFloat w = btn.bounds.size.width;
    CGFloat x = (win.bounds.size.width - w) / 2;
    btn.frame = CGRectMake(x, top + 6, w, 36);
}

static void LCHideFloatButton(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kButtonHiddenKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (lcFloatButton) [lcFloatButton removeFromSuperview];
}

static void LCAttachFloatButton(void);   // 前置声明（双击恢复要用）

// -------- 双击「模块」页恢复被隐藏的按钮 --------
static BOOL lcModulesDoubleTapFired = NO;

@interface LCDoubleTapTarget : NSObject
- (void)onDoubleTap;
@end
@implementation LCDoubleTapTarget
- (void)onDoubleTap {
    if (!LCIsLiveContainerApp()) return;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UITabBarController *tab = LCFindTabBar(win.rootViewController);
    if (!tab || tab.selectedIndex != 2) return;   // 2 = 模块页
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kButtonHiddenKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    LCAttachFloatButton();
    LCShowAlert(@"按钮已恢复", @"「激活软件源」按钮已重新显示在「源」页。",
        @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
}
@end

static LCDoubleTapTarget *lcDoubleTapTarget = nil;

static void LCInstallDoubleTap(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LCInstallDoubleTap(); }); return; }
    static char kLCDoubleTagKey;
    for (UIGestureRecognizer *old in win.gestureRecognizers) {
        if (objc_getAssociatedObject(old, &kLCDoubleTagKey)) return;   // 已装过
    }
    if (!lcDoubleTapTarget) lcDoubleTapTarget = [LCDoubleTapTarget new];
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:lcDoubleTapTarget action:@selector(onDoubleTap)];
    g.numberOfTapsRequired = 2;
    g.cancelsTouchesInView = NO;
    objc_setAssociatedObject(g, &kLCDoubleTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [win addGestureRecognizer:g];
}

static void LCAttachFloatButton(void) {
    if (!kEnableFloatButton) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kButtonHiddenKey]) return;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LCAttachFloatButton(); });
        return;
    }
    // 只在「源」tab 显示；其它页面/客制 App 里隐藏
    BOOL onSources = LCIsOnSourcesTab();
    if (!onSources) {
        if (lcFloatButton) [lcFloatButton removeFromSuperview];
        return;
    }
    if (lcFloatButton && lcFloatButton.superview == win) { LCPositionButton(lcFloatButton); return; }
    if (!lcFloatButton) lcFloatButton = LCMakeFloatButton();
    [win addSubview:lcFloatButton];
    LCPositionButton(lcFloatButton);
    ((LCFloatButtonView *)lcFloatButton).onTap = ^{ LCShowSettingsMenu(); };
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"激活软件源"
        message:[NSString stringWithFormat:@"源：%@\nUDID：%@", src, saved.length ? saved : @"未记录"]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"卡密解锁（卡密或 UDID 二选一）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCShowUnlockDialog();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制专属源地址（带 UDID）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCCopy(u);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"诊断软件源（查付费应用为何不显示）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCDiagnoseSource();
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
                    LCAttachFloatButton();
                    LCRunCheck();
                });
            }];
        // 每 0.5 秒检查一次当前 tab，源页显示、其它页隐藏（SwiftUI TabView 切换无通知）
        // 延迟到下一个 runloop，确保主线程 runloop 已就绪
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCInstallDoubleTap();
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                LCAttachFloatButton();
                LCInstallDoubleTap();
            }];
        });
    }
}
