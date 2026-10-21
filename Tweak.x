// QQRealPush — QQ 前后台实时推送横幅
//
// 两大功能合一：
// 1. 前台横幅强制显示：swizzle UNUserNotificationCenter 代理的
//    willPresentNotification:withCompletionHandler:，强制返回 Banner|List|Sound
//    （iOS 默认前台不弹横幅，必须 swizzle 才能在前台显示）
// 2. 本地通知生成：hook QQ 内部 NSNotificationCenter 消息通知
//    提取发送者/内容，投递 trigger:nil 本地通知（前后台均立即触发）
//
// 不依赖苹果远程推送（APNs），QQ 在后台存活即可推送。
//
// 设置文件：/var/mobile/Library/Preferences/com.qq.realpush.plist
//   Enabled        总开关            （默认 YES）
//   FrontBanner    前台也弹横幅       （默认 YES）
//   ShowContent    显示消息内容       （默认 YES，NO 则只显示"你收到一条新消息"）
//   OnlyOthers     只推送别人的消息   （默认 YES）
//   Sound          播放提示音         （默认 YES）
//   ClearOnOpen    打开 QQ 时清理已弹出的通知（默认 YES）

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ====================== 设置 ======================
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.qq.realpush.plist";
static NSString *const kPrefsChanged = @"com.qq.realpush/prefs-changed";

static BOOL gEnabled = YES;
static BOOL gFrontBanner = YES;
static BOOL gShowContent = YES;
static BOOL gOnlyOthers = YES;
static BOOL gSound = YES;
static BOOL gClearOnOpen = YES;

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!p) return;
    if (p[@"Enabled"])     gEnabled     = [p[@"Enabled"] boolValue];
    if (p[@"FrontBanner"]) gFrontBanner = [p[@"FrontBanner"] boolValue];
    if (p[@"ShowContent"]) gShowContent = [p[@"ShowContent"] boolValue];
    if (p[@"OnlyOthers"])  gOnlyOthers  = [p[@"OnlyOthers"] boolValue];
    if (p[@"Sound"])       gSound       = [p[@"Sound"] boolValue];
    if (p[@"ClearOnOpen"]) gClearOnOpen  = [p[@"ClearOnOpen"] boolValue];
}

static void prefsChangedCb(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadPrefs();
}

// ====================== 去重 ======================
static NSMutableSet *recentIDs(void) {
    static NSMutableSet *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[NSMutableSet alloc] init]; });
    return s;
}

// ====================== Part 1: 前台横幅强制 ======================
// iOS 默认行为：App 在前台时收到通知，系统不弹横幅，只调 delegate 的
// willPresentNotification:withCompletionHandler:，由 App 决定展示什么。
// QQ 的实现通常返回 0（不展示）或只 List，导致前台无横幅。
//
// 本段 swizzle QQ 设置的 UNUserNotificationCenter delegate 类，强制返回
// Banner | List | Sound，使前台也能弹横幅。
// 同时对我们的本地通知生效——前台收到本地通知也会弹横幅。

// 每个被 swizzle 的类名 → 原始 IMP
static NSMutableDictionary<NSString *, NSValue *> *swizzledClasses(void) {
    static NSMutableDictionary *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ d = [[NSMutableDictionary alloc] init]; });
    return d;
}

// 替换 IMP：强制返回 Banner | List | Sound
static void hookWillPresent(id self, SEL _cmd,
    UNUserNotificationCenter *center,
    UNNotification *notification,
    void(^completion)(NSUInteger)) {

    if (!gEnabled || !gFrontBanner) {
        // 禁用或前台不弹 → 调原始实现
        NSString *cls = NSStringFromClass([self class]);
        NSValue *v = swizzledClasses()[cls];
        IMP orig = v ? (IMP)[v pointerValue] : NULL;
        if (orig) {
            ((void(*)(id,SEL,id,id,void(^)(NSUInteger)))orig)(
                self, _cmd, center, notification, completion);
        } else if (completion) {
            completion(0);
        }
        return;
    }

    // 强制 Banner | List | Sound
    NSUInteger forceOpts =
        UNNotificationPresentationOptionBanner |
        UNNotificationPresentationOptionList |
        UNNotificationPresentationOptionSound;

    // 调原始实现，但包裹 completion 强制覆盖返回值
    __block BOOL called = NO;
    void(^wrapped)(NSUInteger) = ^(NSUInteger opts) {
        if (!called) {
            called = YES;
            if (completion) completion(forceOpts);
        }
    };

    NSString *cls = NSStringFromClass([self class]);
    NSValue *v = swizzledClasses()[cls];
    IMP orig = v ? (IMP)[v pointerValue] : NULL;

    if (orig) {
        ((void(*)(id,SEL,id,id,void(^)(NSUInteger)))orig)(
            self, _cmd, center, notification, wrapped);
        // Fallback：如果原始实现没同步调 completion
        if (!called && completion) {
            called = YES;
            completion(forceOpts);
        }
    } else {
        if (completion) completion(forceOpts);
    }
}

// ====================== Part 2: 本地通知生成 ======================

static void pushBanner(NSString *sender, NSString *text, NSString *ident, BOOL isSelf) {
    if (!gEnabled) return;
    if (isSelf && gOnlyOthers) return;

    // 前台开关
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive
        && !gFrontBanner) return;

    // 去重（同一消息 ID 只弹一次）
    NSString *identifier;
    if (ident.length > 0) {
        identifier = [@"qrp-" stringByAppendingString:ident];
        @synchronized(recentIDs()) {
            if ([recentIDs() containsObject:identifier]) return;
            [recentIDs() addObject:identifier];
            if ([recentIDs() count] > 300) [recentIDs() removeAllObjects];
        }
    } else {
        identifier = [NSString stringWithFormat:@"qrp-%f", [NSDate date].timeIntervalSince1970];
    }

    NSString *title = (sender.length > 0) ? sender : @"QQ";
    NSString *body = (gShowContent && text.length > 0) ? text : @"你收到一条新消息";

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    if (gSound) content.sound = [UNNotificationSound defaultSound];
    content.threadIdentifier = @"com.qq.realpush";
    content.categoryIdentifier = @"QRPP_MESSAGE";

    // trigger:nil = 立即触发，前台（需 Part 1 配合）和后台均弹横幅
    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:identifier
                       content:content
                       trigger:nil];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
          withCompletionHandler:nil];
}

// 通用字段提取（容错）
static NSString *extractString(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *key in keys) {
        @try {
            id v = [obj valueForKey:key];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                return v;
            if ([v isKindOfClass:[NSNumber class]]) {
                NSString *s = [(NSNumber *)v stringValue];
                if (s.length > 0) return s;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

// 清理已推送通知
static void clearDelivered(void) {
    if (!gClearOnOpen) return;
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *ns) {
        NSMutableArray *ids = [NSMutableArray array];
        for (UNNotification *n in ns) {
            if ([n.request.identifier hasPrefix:@"qrp-"])
                [ids addObject:n.request.identifier];
        }
        if (ids.count > 0)
            [c removeDeliveredNotificationsWithIdentifiers:ids];
    }];
}

// ====================== Hooks ======================

// ---- Part 1: 当 QQ 设置通知代理时 swizzle ----
%hook UNUserNotificationCenter

- (void)setDelegate:(id<UNUserNotificationCenterDelegate>)delegate {
    %orig;

    if (!gEnabled || !gFrontBanner || !delegate) return;

    Class cls = [delegate class];
    NSString *clsName = NSStringFromClass(cls);

    @synchronized(swizzledClasses()) {
        if ([swizzledClasses() objectForKey:clsName]) return; // 已 swizzle

        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(cls, sel);

        if (m) {
            // 方法存在 → 保存原始 IMP，替换为我们的
            IMP orig = method_getImplementation(m);
            [swizzledClasses() setObject:[NSValue valueWithPointer:orig] forKey:clsName];
            method_setImplementation(m, (IMP)hookWillPresent);
        } else {
            // 方法不存在 → 添加
            [swizzledClasses() setObject:[NSValue valueWithPointer:NULL] forKey:clsName];
            class_addMethod(cls, sel, (IMP)hookWillPresent, "v@:@@@?");
        }

        NSLog(@"[QQRealPush] swizzled willPresentNotification on class %@", clsName);
    }
}

%end


// ---- Part 2: 监听 QQ 内部消息通知，弹本地通知横幅 ----
%hook NSNotificationCenter

- (void)postNotification:(NSNotification *)notification {
    %orig;

    if (!gEnabled) return;

    @autoreleasepool {
        NSString *name = notification.name ?: @"";
        NSString *lower = name.lowercaseString;

        // 过滤：通知名 或 通知对象类名 含消息关键词
        BOOL nameMatch = [lower containsString:@"msg"]
                      || [lower containsString:@"message"]
                      || [lower containsString:@"chat"]
                      || [lower containsString:@"recv"]
                      || [lower containsString:@"receive"];

        id obj = notification.object;
        BOOL classMatch = NO;
        if (obj) {
            NSString *cn = NSStringFromClass([obj class]).lowercaseString;
            classMatch = [cn containsString:@"msg"]
                      || [cn containsString:@"message"]
                      || [cn containsString:@"chat"]
                      || [cn containsString:@"recv"];
        }

        if (!nameMatch && !classMatch) return;

        // 排除噪音通知
        static NSArray<NSString *> *excludePatterns;
        static dispatch_once_t t;
        dispatch_once(&t, ^{
            excludePatterns = @[
                @"heartbeat", @"sync", @"statechange",
                @"willenter", @"didenter", @"willresign", @"didresign",
                @"willappear", @"didappear", @"willdisappear", @"diddisappear",
                @"selfsend", @"sendingsuccess", @"sendfail",
                @"read", @"recall", @"withdraw", @"delete",
                @"typing", @"presence", @"network", @"connect",
                @"launch", @"finish", @"loading", @"cache",
                @"config", @"token", @"pushkit", @"pushtoken",
                @"fetch", @"upload", @"download"
            ];
        });
        for (NSString *p in excludePatterns) {
            if ([lower containsString:p]) return;
        }

        // 提取消息字段（从 object 和 userInfo 两处尝试）
        id source = obj ?: notification.userInfo;
        NSDictionary *userInfo = notification.userInfo;

        NSString *ident = extractString(source, @[
            @"msgUid", @"uid", @"msgSeq", @"messageID", @"msgId", @"seq", @"messageSeq"
        ]);
        if (!ident && userInfo) {
            ident = extractString(userInfo, @[
                @"msgUid", @"uid", @"msgSeq", @"messageID", @"msgId", @"seq"
            ]);
        }

        NSString *sender = extractString(source, @[
            @"nickName", @"senderName", @"friendNick", @"uin",
            @"senderUid", @"fromUid", @"senderUin", @"friendUin"
        ]);
        if (!sender && userInfo) {
            sender = extractString(userInfo, @[
                @"nickName", @"senderName", @"friendNick", @"uin", @"senderUid"
            ]);
        }

        NSString *text = extractString(source, @[
            @"msgContent", @"content", @"text", @"summary",
            @"msgSummary", @"abstract", @"richTextContent"
        ]);
        if (!text && userInfo) {
            text = extractString(userInfo, @[
                @"msgContent", @"content", @"text", @"summary", @"msgSummary"
            ]);
        }

        // 判断是否自己发的
        BOOL isSelf = NO;
        @try {
            id v = [source valueForKey:@"isSelf"];
            if (v) isSelf = [v boolValue];
        } @catch (NSException *e) {}

        // 有内容或发送者就推送
        if (text.length > 0 || sender.length > 0) {
            pushBanner(sender, text, ident, isSelf);
        }
    }
}

%end

// ====================== 构造函数 ======================
%ctor {
    @autoreleasepool {
        loadPrefs();

        // 监听设置变更（Darwin 通知）
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)prefsChangedCb,
            (CFStringRef)kPrefsChanged,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // 打开 QQ 时清理已弹出的通知
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            clearDelivered();
        }];

        // 通知权限自检
        [[UNUserNotificationCenter currentNotificationCenter]
            getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            if (settings.authorizationStatus != UNAuthorizationStatusAuthorized) {
                NSLog(@"[QQRealPush] WARNING: QQ notification permission not granted. "
                       "Go to Settings -> Notifications -> QQ -> Allow Notifications");
            }
        }];

        NSLog(@"[QQRealPush] loaded (enabled=%d front=%d content=%d onlyOthers=%d sound=%d)",
              gEnabled, gFrontBanner, gShowContent, gOnlyOthers, gSound);
    }
}
