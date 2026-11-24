#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

/*
 * LCUpdateAssistant · LiveContainer 软件源辅助
 *
 * 功能：
 *   1. 「源」页顶部常驻蓝色按钮「八区软件源」，点开面板（免责声明 + 设备/站点信息 + 功能菜单）
 *   2. 摇一摇 / 菜单呼出「卡密解锁」，卡密或 UDID 二选一，直接调 api.php 激活/验证
 *   3. 解锁成功后自动把「带 UDID 的专属源」导入 LiveContainer 软件源列表，不用手动添加
 *   4. 回前台静默查源，本机版本落后时提示（不再提供无效的「立即检查更新」入口）
 *
 * 硬限制（写在前面，别踩坑）：
 *   iOS 普通 App 拿不到真机 UDID，identifierForVendor 跟后台设备表对不上。
 *   所以 UDID 必须用户从描述文件获取后手输/粘贴，插件不假装能自动拿。
 *
 * v2.0：按钮/面板改名「八区软件源」；面板正文换成免责声明 + 设备 UID / 当前 IP / 会员到期 /
 *       站内应用数 / 本次更新 / 数据刷新 / QQ 群；解锁成功弹窗去掉源地址块与「复制源地址」按钮，
 *       UDID 提到到期时间上方；去掉「复制专属源地址（带 UDID）」菜单项。
 * v1.9：按钮改蓝色；去掉「诊断软件源」「立即检查更新」；解锁成功自动导入专属源
 *       （写 LCAltStoreSourceURLs + 预置缓存 + livecontainer://source 深链即时生效）。
 * v1.8：去掉无用弹窗；模块页双击恢复被隐藏的按钮。
 */

// -------- 可改配置（改完 make 一次）--------
static NSString *const kDefaultSourceURL = @"https://app.baqu.net/altstore.php/apps.json";
static NSString *const kDefaultAPIURL    = @"https://app.baqu.net/api.php";
static NSString *const kDefaultAPIKey    = @"";   // 后台「API密钥」为空就留空；填了则必须一致
static NSTimeInterval const kCheckInterval = 1800.0;
static BOOL const kEnableShakeUnlock  = YES;
static BOOL const kEnableFloatButton  = YES;   // 常驻悬浮设置按钮
static NSString *const kButtonHiddenKey = @"lcua_float_hidden";
static NSString *const kAppTitle        = @"八区软件源";   // 按钮 + 面板标题
static NSString *const kQQGroup         = @"565911547";
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

// 给源地址拼上 udid（专属源）
static NSString *LCSourceURLWithUDID(NSString *udid) {
    NSString *src = LCSourceURL();
    if (udid.length == 0) return src;
    return ([src rangeOfString:@"?"].location == NSNotFound)
        ? [src stringByAppendingFormat:@"?udid=%@", LCURLEncode(udid)]
        : [src stringByAppendingFormat:@"&udid=%@", LCURLEncode(udid)];
}

static NSString *LCStripQuery(NSString *u) {
    NSRange r = [u rangeOfString:@"?"];
    return r.location == NSNotFound ? u : [u substringToIndex:r.location];
}

// ============ 面板统计信息（UID / IP / 到期 / 应用数 / 更新数 / 刷新时间）============
static NSString *LCFormatDate(NSDate *d, NSString *fmt) {
    static NSDateFormatter *f = nil;
    static NSString *curFmt = nil;
    if (!f) f = [[NSDateFormatter alloc] init];
    if (![curFmt isEqualToString:fmt]) { f.dateFormat = fmt; curFmt = fmt; }
    return [f stringFromDate:d] ?: @"";
}

static NSDate *LCDateFromString(NSString *s) {
    if (s.length == 0) return nil;
    static NSDateFormatter *f = nil;
    if (!f) { f = [[NSDateFormatter alloc] init]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss"; }
    return [f dateFromString:s];
}

static NSInteger LCDaysLeftOf(NSString *expire) {
    NSDate *d = LCDateFromString(expire);
    if (!d) return -1;
    NSTimeInterval left = [d timeIntervalSinceNow];
    if (left < 0) return 0;
    return (NSInteger)ceil(left / 86400.0);
}

// 从任意文本里抠出第一个 IPv4（myip.ipip.net / ip.3322.net 返回纯文本）
static NSString *LCFirstIPv4(NSString *s) {
    if (s.length == 0) return nil;
    NSUInteger n = s.length, i = 0;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    while (i < n) {
        if (![digits characterIsMember:[s characterAtIndex:i]]) { i++; continue; }
        NSMutableString *buf = [NSMutableString string];
        NSUInteger j = i;
        while (j < n) {
            unichar c = [s characterAtIndex:j];
            if ([digits characterIsMember:c] || c == '.') { [buf appendFormat:@"%C", c]; j++; }
            else break;
        }
        NSString *cand = [buf stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"."]];
        NSArray *parts = [cand componentsSeparatedByString:@"."];
        if (parts.count == 4 && cand.length >= 7) {
            BOOL ok = YES;
            for (NSString *p in parts) { if (p.length == 0 || p.length > 3) { ok = NO; break; } }
            if (ok) return cand;
        }
        i = (j > i) ? j : i + 1;
    }
    return nil;
}

static void LCFetchClientIPFrom(NSArray *urls, NSUInteger idx) {
    if (idx >= urls.count) return;
    NSURL *u = [NSURL URLWithString:urls[idx]];
    if (!u) { LCFetchClientIPFrom(urls, idx + 1); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 8;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *ip = nil;
        if (!err && data.length) {
            ip = LCFirstIPv4([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        }
        if (ip.length) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setObject:ip forKey:@"lcua_last_ip"];
            [ud synchronize];
            return;
        }
        LCFetchClientIPFrom(urls, idx + 1);
    }] resume];
}

static void LCFetchClientIP(void) {
    // 依次尝试，前一个不通再换下一个
    LCFetchClientIPFrom(@[@"https://myip.ipip.net", @"https://ip.3322.net", @"https://api.ipify.org"], 0);
}

// 记录「本站现有应用 / 本次更新 / 刷新时间」：与上次快照比版本号得出更新数
static void LCRecordSourceStats(NSArray *apps) {
    if (![apps isKindOfClass:[NSArray class]]) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *verMap = [NSMutableDictionary dictionary];
    NSString *today = LCFormatDate([NSDate date], @"yyyy-MM-dd");
    NSInteger todayUpdates = 0;

    for (id it in apps) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *a = (NSDictionary *)it;
        NSString *bid = [a[@"bundleIdentifier"] description] ?: @"";
        NSString *ver = [a[@"version"] description] ?: @"";
        if (bid.length) verMap[bid] = ver;
        NSString *vd = [a[@"versionDate"] description] ?: @"";
        if (vd.length >= 10 && [[vd substringToIndex:10] isEqualToString:today]) todayUpdates++;
    }

    NSDictionary *prev = [ud dictionaryForKey:@"lcua_ver_map"];
    NSInteger changed = -1;
    if ([prev isKindOfClass:[NSDictionary class]] && prev.count > 0) {
        changed = 0;
        for (NSString *bid in verMap) {
            id old = prev[bid];
            if (![old isKindOfClass:[NSString class]] || ![(NSString *)old isEqualToString:verMap[bid]]) changed++;
        }
    }
    if (changed < 0) changed = todayUpdates;   // 首次没有快照，退化成「今天更新的数量」

    [ud setObject:@((NSInteger)apps.count) forKey:@"lcua_app_count"];
    [ud setObject:@(changed) forKey:@"lcua_update_count"];
    [ud setObject:LCFormatDate([NSDate date], @"yyyy-MM-dd HH:mm:ss") forKey:@"lcua_stats_time"];
    [ud setObject:verMap forKey:@"lcua_ver_map"];
    [ud synchronize];
}

// 面板正文：免责声明 + 设备信息 + 站点数据
static NSString *LCStatsMessage(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *udid   = [ud stringForKey:@"lcua_last_udid"] ?: @"";
    NSString *ip     = [ud stringForKey:@"lcua_last_ip"] ?: @"";
    NSString *expire = [ud stringForKey:@"lcua_expire"] ?: @"";
    NSString *time   = [ud stringForKey:@"lcua_stats_time"] ?: @"";
    NSNumber *appCnt = [ud objectForKey:@"lcua_app_count"];
    NSNumber *updCnt = [ud objectForKey:@"lcua_update_count"];

    NSString *appsLine = (appCnt && updCnt)
        ? [NSString stringWithFormat:@"本站现有应用：%ld 款｜本次更新：%ld 款",
           (long)[appCnt integerValue], (long)[updCnt integerValue]]
        : @"本站现有应用：读取中…";

    return [NSString stringWithFormat:
        @"所有资源均来自网络公开分享，仅用于个人学习交流，严禁商用，违规后果自行承担，如有版权问题请联系我们下架！请勿使用本源安装、分发违规相关应用及文件，账号封禁与本软件源无关。\n"
        @"设备 UID：%@\n"
        @"当前 IP：%@\n"
        @"会员到期时间：%@\n"
        @"%@\n"
        @"数据刷新：%@\n"
        @"交流QQ群：【%@】",
        udid.length ? udid : @"未解锁",
        ip.length ? ip : @"获取中…",
        expire.length ? expire : @"未解锁",
        appsLine,
        time.length ? time : LCFormatDate([NSDate date], @"yyyy-MM-dd HH:mm:ss"),
        kQQGroup];
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

        // 顺手把面板要用的统计（应用数 / 更新数 / 刷新时间）记下来
        LCRecordSourceStats(apps);

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

// ============ 自动导入专属源到 LiveContainer 软件源 ============
// LiveContainer 的源列表存在 UserDefaults 的 LCAltStoreSourceURLs（字符串数组），
// 拉到的源 JSON 缓存在 Caches/AltStoreSourceCache/<sha256(源地址)>.json。
// 官方还支持深链 livecontainer://source?url=xxx，走的就是「+ 添加源」那条路，能立即刷新 UI。
static BOOL LCIsLiveContainerApp(void);   // 前置声明（定义在后文）

static NSString *LCSHA256Hex(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
    return out;
}

// 把专属源写进 LiveContainer 的源列表；同域名的旧地址（无 udid / 旧 udid）顺手替换掉
static BOOL LCImportSourceToDefaults(NSString *udidSrc, BOOL *existedBefore) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    id stored = [ud arrayForKey:@"LCAltStoreSourceURLs"];
    NSArray *old = [stored isKindOfClass:[NSArray class]] ? (NSArray *)stored : @[];
    if (existedBefore) *existedBefore = [old containsObject:udidSrc];

    NSString *base = LCStripQuery(LCSourceURL());
    NSMutableArray *list = [NSMutableArray array];
    for (id it in old) {
        if (![it isKindOfClass:[NSString class]]) continue;
        NSString *s = (NSString *)it;
        if ([LCStripQuery(s) isEqualToString:base]) continue;   // 同一源的旧地址，换成新的
        [list addObject:s];
    }
    if (![list containsObject:udidSrc]) [list addObject:udidSrc];
    [ud setObject:list forKey:@"LCAltStoreSourceURLs"];
    [ud synchronize];
    return YES;
}

// 预置源缓存：即使深链没走通，下次进「源」页也能直接把 App 列出来
static void LCWarmSourceCache(NSString *src) {
    NSURL *url = [NSURL URLWithString:src];
    if (!url) return;
    NSString *fileName = [LCSHA256Hex(src) stringByAppendingString:@".json"];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || data.length < 32) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
        if (!caches) return;
        NSURL *dir = [caches URLByAppendingPathComponent:@"AltStoreSourceCache" isDirectory:YES];
        if (![fm fileExistsAtPath:dir.path]) {
            [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [data writeToURL:[dir URLByAppendingPathComponent:fileName] atomically:YES];
    }] resume];
}

// 深链让「源」页当场把新源加载出来（等价于点 + 手动粘贴地址）
static void LCOpenSourceDeepLink(NSString *udidSrc) {
    NSString *s = [NSString stringWithFormat:@"livecontainer://source?url=%@", LCURLEncode(udidSrc)];
    NSURL *url = [NSURL URLWithString:s];
    if (!url) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
}

// 后台刷新面板数据：源应用数/更新数 + 公网 IP + 会员到期
static void LCRefreshStatsAsync(void) {
    NSString *udid = [[NSUserDefaults standardUserDefaults] stringForKey:@"lcua_last_udid"] ?: @"";
    NSURL *url = [NSURL URLWithString:LCSourceURLWithUDID(udid)];
    if (url) {
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data.length) return;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) return;
            NSArray *apps = ((NSDictionary *)obj)[@"apps"];
            if ([apps isKindOfClass:[NSArray class]]) LCRecordSourceStats(apps);
        }] resume];
    }
    LCFetchClientIP();
    if (udid.length == 0) return;
    LCAPICall(@"validate", @{@"device_id": udid}, ^(NSDictionary *res, NSString *err) {
        if (err || ![[res objectForKey:@"success"] boolValue]) return;
        id d = [res objectForKey:@"data"];
        if (![d isKindOfClass:[NSDictionary class]]) return;
        id exp = [(NSDictionary *)d objectForKey:@"expire_time"];
        if ([exp isKindOfClass:[NSString class]] && [(NSString *)exp length]) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setObject:exp forKey:@"lcua_expire"];
            [ud synchronize];
        }
    });
}

// 解锁成功后的统一提示：记 UDID / 到期时间 + 自动导入专属源
static void LCUnlockSuccess(NSString *udid, NSString *expire, NSString *note) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:udid forKey:@"lcua_last_udid"];
    if (expire.length) [ud setObject:expire forKey:@"lcua_expire"];
    [ud synchronize];
    NSString *udidSrc = LCSourceURLWithUDID(udid);

    BOOL isLC = LCIsLiveContainerApp();
    BOOL existed = NO;
    if (isLC) {
        LCImportSourceToDefaults(udidSrc, &existed);
        LCWarmSourceCache(udidSrc);
        if (!existed) LCOpenSourceDeepLink(udidSrc);
    }

    NSString *tail;
    if (!isLC) {
        tail = @"当前不在 LiveContainer 本体里，请到「源」页右上角手动添加这个地址：";
    } else if (existed) {
        tail = @"这个源已经在「软件源」列表里了，切到「源」页下拉刷新即可。";
    } else {
        tail = @"已自动导入到「软件源」，切到「源」页就能看到付费 App。\n若列表没变，重启一次 LiveContainer 即可。";
    }
    if (!isLC) tail = [tail stringByAppendingFormat:@"\n%@", udidSrc];

    NSMutableArray *lines = [NSMutableArray array];
    if (note.length) [lines addObject:note];
    [lines addObject:[NSString stringWithFormat:@"UDID：%@", udid]];
    if (expire.length) {
        [lines addObject:[NSString stringWithFormat:@"到期：%@", expire]];
        NSInteger left = LCDaysLeftOf(expire);
        if (left >= 0) [lines addObject:[NSString stringWithFormat:@"剩余：%ld 天", (long)left]];
    }
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@", [lines componentsJoinedByString:@"\n"], tail];
    LCShowAlert(@"解锁成功", msg, @[
        [UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]
    ]);

    // 顺手刷新面板要显示的 IP / 统计
    LCFetchClientIP();
}

// 路径 A：两个都填 —— 新卡首次激活（原逻辑）
static void LCActivateBoth(NSString *card, NSString *udid) {
    LCAPICall(@"activate", @{@"card_key": card, @"device_id": udid}, ^(NSDictionary *res, NSString *errMsg) {
        if (errMsg) { LCShowAlert(@"激活失败", errMsg, @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]); return; }
        BOOL ok = [[res objectForKey:@"success"] boolValue];
        NSString *msg = [res objectForKey:@"message"] ?: (ok ? @"激活成功" : @"激活失败");
        NSDictionary *data = [res objectForKey:@"data"];
        NSString *expire = [data isKindOfClass:[NSDictionary class]] ? ([data objectForKey:@"expire_time"] ?: @"") : @"";
        if (ok) LCUnlockSuccess(udid, expire, msg);
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
        LCUnlockSuccess(udid, expire, @"设备已激活，未过期。");
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

// ============ 顶部固定「八区软件源」按钮 ============
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
    // 蓝色（#0A7AFA），跟系统强调色一致
    self.backgroundColor = [UIColor colorWithRed:0.04 green:0.48 blue:0.98 alpha:0.95];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 5;
    self.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
    label.text = kAppTitle;
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
    LCShowAlert(@"按钮已恢复", [NSString stringWithFormat:@"「%@」按钮已重新显示在「源」页。", kAppTitle],
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
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *saved = [ud stringForKey:@"lcua_last_udid"] ?: @"";
    NSString *u = LCSourceURLWithUDID(saved);

    // 数据超过 5 分钟没刷新就后台静默拉一遍，下次打开面板就是新数字
    NSString *statsTime = [ud stringForKey:@"lcua_stats_time"] ?: @"";
    NSDate *last = statsTime.length ? LCDateFromString(statsTime) : nil;
    if (!last || -[last timeIntervalSinceNow] > 300) LCRefreshStatsAsync();

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:kAppTitle
        message:LCStatsMessage()
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"卡密解锁（卡密或 UDID 二选一）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LCShowUnlockDialog();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入专属源到软件源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (saved.length == 0) {
            LCShowAlert(@"还没解锁", @"先点「卡密解锁」激活一次，插件会记下 UDID，之后就能一键导入。",
                @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
            return;
        }
        BOOL existed = NO;
        LCImportSourceToDefaults(u, &existed);
        LCWarmSourceCache(u);
        if (!existed) LCOpenSourceDeepLink(u);
        LCRefreshStatsAsync();
        LCShowAlert(@"已导入", existed
            ? @"这个源已经在「软件源」列表里了，切到「源」页下拉刷新即可。"
            : @"专属源已加进「软件源」，切到「源」页就能看到付费 App。\n若列表没变，重启一次 LiveContainer 即可。",
            @[[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]]);
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
