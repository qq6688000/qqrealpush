// QQRealPush v1.1.0 — QQ 前后台实时推送横幅（诊断增强版）
//
// 改进：
// 1. 诊断日志：记录所有 NSNotification、badge 变化、声音播放、通知请求
// 2. 启动 3 秒后发测试通知，验证通知系统是否正常
// 3. 多路消息检测：NSNotificationCenter + AudioServices + badge + AppDelegate 远程推送
// 4. 前台横幅强制：增加延迟检查现有 delegate + 无 delegate 时自动设置
// 5. 运行时类发现：记录 QQ 中含 Message/Chat/Session 的类名

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

// ====================== 设置 ======================
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.qq.realpush.plist";
static NSString *const kPrefsChanged = @"com.qq.realpush/prefs-changed";
static NSString *const kLogPath = @"/var/mobile/Library/Preferences/com.qq.realpush.log";

static BOOL gEnabled = YES;
static BOOL gFrontBanner = YES;
static BOOL gShowContent = YES;
static BOOL gOnlyOthers = YES;
static BOOL gSound = YES;
static BOOL gClearOnOpen = YES;
static BOOL gDebug = YES;       // 诊断模式（记录所有日志）
static BOOL gTestNotify = YES;  // 启动后发测试通知

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!p) return;
    if (p[@"Enabled"])     gEnabled     = [p[@"Enabled"] boolValue];
    if (p[@"FrontBanner"]) gFrontBanner = [p[@"FrontBanner"] boolValue];
    if (p[@"ShowContent"]) gShowContent = [p[@"ShowContent"] boolValue];
    if (p[@"OnlyOthers"])  gOnlyOthers  = [p[@"OnlyOthers"] boolValue];
    if (p[@"Sound"])       gSound       = [p[@"Sound"] boolValue];
    if (p[@"ClearOnOpen"]) gClearOnOpen  = [p[@"ClearOnOpen"] boolValue];
    if (p[@"Debug"])       gDebug       = [p[@"Debug"] boolValue];
    if (p[@"TestNotify"])  gTestNotify  = [p[@"TestNotify"] boolValue];
}

static void prefsChangedCb(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadPrefs();
}

// ====================== 诊断日志 ======================
static NSMutableSet *loggedNotifNames(void) {
    static NSMutableSet *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[NSMutableSet alloc] init]; });
    return s;
}

static void qrpLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void qrpLog(NSString *format, ...) {
    if (!gDebug) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSLog(@"[QQRealPush] %@", msg);

    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) {
            [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ====================== 去重 ======================
static NSMutableSet *recentIDs(void) {
    static NSMutableSet *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[NSMutableSet alloc] init]; });
    return s;
}

// ====================== Part 1: 前台横幅强制 ======================
static NSMutableDictionary<NSString *, NSValue *> *swizzledClasses(void) {
    static NSMutableDictionary *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ d = [[NSMutableDictionary alloc] init]; });
    return d;
}

static void hookWillPresent(id self, SEL _cmd,
    UNUserNotificationCenter *center,
    UNNotification *notification,
    void(^completion)(NSUInteger)) {

    if (!gEnabled || !gFrontBanner) {
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

    NSUInteger forceOpts =
        UNNotificationPresentationOptionBanner |
        UNNotificationPresentationOptionList |
        UNNotificationPresentationOptionSound;

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
        if (!called && completion) {
            called = YES;
            completion(forceOpts);
        }
    } else {
        if (completion) completion(forceOpts);
    }
}

// swizzle 一个 delegate 类的 willPresentNotification:
static void swizzleDelegateClass(Class cls) {
    if (!cls) return;
    NSString *clsName = NSStringFromClass(cls);

    @synchronized(swizzledClasses()) {
        if ([swizzledClasses() objectForKey:clsName]) return;

        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(cls, sel);

        if (m) {
            IMP orig = method_getImplementation(m);
            [swizzledClasses() setObject:[NSValue valueWithPointer:orig] forKey:clsName];
            method_setImplementation(m, (IMP)hookWillPresent);
        } else {
            [swizzledClasses() setObject:[NSValue valueWithPointer:NULL] forKey:clsName];
            class_addMethod(cls, sel, (IMP)hookWillPresent, "v@:@@@?");
        }
        qrpLog(@"swizzled willPresentNotification on class %@", clsName);
    }
}

// ====================== Part 2: 本地通知生成 ======================
static void pushBanner(NSString *sender, NSString *text, NSString *ident, BOOL isSelf) {
    if (!gEnabled) return;
    if (isSelf && gOnlyOthers) return;

    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive
        && !gFrontBanner) return;

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

    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:identifier content:content trigger:nil];

    qrpLog(@"pushBanner: title=%@ body=%@ id=%@", title, body, identifier);

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:^(NSError *err) {
            if (err) qrpLog(@"pushBanner ERROR: %@", err);
            else qrpLog(@"pushBanner OK");
        }];
}

static NSString *extractString(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *key in keys) {
        @try {
            id v = [obj valueForKey:key];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
            if ([v isKindOfClass:[NSNumber class]]) {
                NSString *s = [(NSNumber *)v stringValue];
                if (s.length > 0) return s;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static void clearDelivered(void) {
    if (!gClearOnOpen) return;
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *ns) {
        NSMutableArray *ids = [NSMutableArray array];
        for (UNNotification *n in ns) {
            if ([n.request.identifier hasPrefix:@"qrp-"])
                [ids addObject:n.request.identifier];
        }
        if (ids.count > 0) [c removeDeliveredNotificationsWithIdentifiers:ids];
    }];
}

// ====================== 测试通知 ======================
static void postTestNotification(void) {
    if (!gTestNotify) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"QQRealPush 测试";
    content.body = @"如果你看到这条通知，说明通知系统正常工作！";
    content.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *req = [UNNotificationRequest
        requestWithIdentifier:@"qrp-test" content:content trigger:nil];

    qrpLog(@"posting test notification");

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:req withCompletionHandler:^(NSError *err) {
            qrpLog(@"test notification result: %@", err ?: @"success");
        }];
}

// ====================== AppDelegate 远程推送拦截 ======================
// Hook AppDelegate 的 application:didReceiveRemoteNotification:fetchCompletionHandler:
// 当 QQ 收到 APNs 时，提取 payload 投递本地通知
static IMP orig_didReceiveRemoteNotification = NULL;

static void hook_didReceiveRemoteNotification(id self, SEL _cmd,
    UIApplication *application, NSDictionary *userInfo,
    void(^completionHandler)(UIBackgroundFetchResult)) {

    qrpLog(@"didReceiveRemoteNotification: userInfo=%@", userInfo);

    // 从 APNs payload 提取消息内容
    NSDictionary *aps = userInfo[@"aps"];
    if (aps) {
        id alertObj = aps[@"alert"];
        NSString *alertText = nil;
        NSString *titleText = nil;

        if ([alertObj isKindOfClass:[NSDictionary class]]) {
            titleText = alertObj[@"title"];
            alertText = alertObj[@"body"];
        } else if ([alertObj isKindOfClass:[NSString class]]) {
            alertText = alertObj;
        }

        if (alertText.length > 0) {
            pushBanner(titleText ?: @"QQ", alertText, nil, NO);
        }
    }

    // 调原始实现
    if (orig_didReceiveRemoteNotification) {
        ((void(*)(id,SEL,id,id,void(^)(UIBackgroundFetchResult)))orig_didReceiveRemoteNotification)(
            self, _cmd, application, userInfo, completionHandler);
    } else if (completionHandler) {
        completionHandler(UIBackgroundFetchResultNoData);
    }
}

// ====================== 运行时类发现 ======================
static void discoverMessageClasses(void) {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);

    int found = 0;
    for (int i = 0; i < numClasses; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *lower = name.lowercaseString;

        if ([lower containsString:@"message"] || [lower containsString:@"msgsvc"]
            || [lower containsString:@"chat"] || [lower containsString:@"conversation"]
            || [lower containsString:@"session"] || [lower containsString:@"recvmsg"]
            || [lower containsString:@"onrecv"] || [lower containsString:@"ntmsg"]
            || [lower containsString:@"msgservice"]) {

            found++;
            if (found <= 80) {  // 限制日志量
                qrpLog(@"CLASS: %@", name);
            }
        }
    }
    qrpLog(@"class discovery: found %d message-related classes", found);
    free(classes);
}

// ====================== Hooks ======================

// ---- Part 1: UNUserNotificationCenter (setDelegate + addNotificationRequest) ----
%hook UNUserNotificationCenter

- (void)setDelegate:(id<UNUserNotificationCenterDelegate>)delegate {
    %orig;
    qrpLog(@"setDelegate called, delegate=%@ class=%@",
           delegate, delegate ? NSStringFromClass([delegate class]) : @"nil");

    if (!gEnabled || !gFrontBanner || !delegate) return;
    swizzleDelegateClass([delegate class]);
}

- (void)addNotificationRequest:(UNNotificationRequest *)request
          withCompletionHandler:(void(^)(NSError *))handler {
    qrpLog(@"addNotificationRequest: id=%@ title=%@ body=%@",
           request.identifier, request.content.title, request.content.body);
    %orig;
}

%end

// ---- Part 2a: NSNotificationCenter（日志 + 消息检测）----
%hook NSNotificationCenter

- (void)postNotification:(NSNotification *)notification {
    %orig;
    if (!gEnabled) return;

    @autoreleasepool {
        NSString *name = notification.name ?: @"";
        NSString *lower = name.lowercaseString;

        // 诊断：记录所有通知名（去重，最多 300 个）
        if (gDebug) {
            @synchronized(loggedNotifNames()) {
                if (![loggedNotifNames() containsObject:name]) {
                    if ([loggedNotifNames() count] < 300) {
                        [loggedNotifNames() addObject:name];
                        NSString *objCls = notification.object
                            ? NSStringFromClass([notification.object class]) : @"nil";
                        qrpLog(@"NOTIF: name=%@ objClass=%@", name, objCls);
                    }
                }
            }
        }

        // 消息检测
        BOOL nameMatch = [lower containsString:@"msg"]
                      || [lower containsString:@"message"]
                      || [lower containsString:@"chat"]
                      || [lower containsString:@"recv"]
                      || [lower containsString:@"receive"];
        id obj = notification.object;
        BOOL classMatch = NO;
        if (obj) {
            NSString *cn = NSStringFromClass([obj class]).lowercaseString;
            classMatch = [cn containsString:@"msg"] || [cn containsString:@"message"]
                      || [cn containsString:@"chat"] || [cn containsString:@"recv"];
        }
        if (!nameMatch && !classMatch) return;

        // 排除噪音
        static NSArray<NSString *> *excludePatterns;
        static dispatch_once_t t;
        dispatch_once(&t, ^{
            excludePatterns = @[
                @"heartbeat", @"sync", @"statechange", @"willenter", @"didenter",
                @"willresign", @"didresign", @"willappear", @"didappear",
                @"willdisappear", @"diddisappear", @"selfsend", @"sendingsuccess",
                @"sendfail", @"read", @"recall", @"withdraw", @"delete",
                @"typing", @"presence", @"network", @"connect", @"launch",
                @"finish", @"loading", @"cache", @"config", @"token",
                @"pushkit", @"pushtoken", @"fetch", @"upload", @"download"
            ];
        });
        for (NSString *p in excludePatterns) {
            if ([lower containsString:p]) return;
        }

        qrpLog(@"MSG MATCH: name=%@ objClass=%@", name,
               obj ? NSStringFromClass([obj class]) : @"nil");

        id source = obj ?: notification.userInfo;
        NSDictionary *userInfo = notification.userInfo;

        NSString *ident = extractString(source, @[
            @"msgUid", @"uid", @"msgSeq", @"messageID", @"msgId", @"seq", @"messageSeq"
        ]);
        if (!ident && userInfo)
            ident = extractString(userInfo, @[@"msgUid", @"uid", @"msgSeq", @"messageID", @"msgId"]);

        NSString *sender = extractString(source, @[
            @"nickName", @"senderName", @"friendNick", @"uin",
            @"senderUid", @"fromUid", @"senderUin", @"friendUin"
        ]);
        if (!sender && userInfo)
            sender = extractString(userInfo, @[@"nickName", @"senderName", @"friendNick", @"uin"]);

        NSString *text = extractString(source, @[
            @"msgContent", @"content", @"text", @"summary", @"msgSummary", @"abstract"
        ]);
        if (!text && userInfo)
            text = extractString(userInfo, @[@"msgContent", @"content", @"text", @"summary"]);

        BOOL isSelf = NO;
        @try {
            id v = [source valueForKey:@"isSelf"];
            if (v) isSelf = [v boolValue];
        } @catch (NSException *e) {}

        if (text.length > 0 || sender.length > 0) {
            pushBanner(sender, text, ident, isSelf);
        }
    }
}

%end

// ---- Part 2b: UIApplication badge 变化检测 ----
%hook UIApplication

- (void)setApplicationIconBadgeNumber:(NSInteger)badge {
    qrpLog(@"badge number: %ld -> %ld", (long)self.applicationIconBadgeNumber, (long)badge);
    %orig;

    // badge 增加 = 可能收到新消息
    if (gEnabled && badge > self.applicationIconBadgeNumber && badge > 0) {
        qrpLog(@"badge increased — possible new message");
        // 不直接 pushBanner（无法提取内容），仅记录
    }
}

%end

// ---- Part 2c: AudioServices 声音/振动检测 ----
%hookf(void, AudioServicesPlaySystemSound, SystemSoundID inSystemSoundID) {
    qrpLog(@"AudioServicesPlaySystemSound: %u (state=%d)",
           (unsigned)inSystemSoundID,
           [UIApplication sharedApplication].applicationState);
    %orig;

    // 振动 (4095) 或用户自定义提示音 → 可能收到新消息
    if (gEnabled && inSystemSoundID != 0) {
        // 常见消息提示音 ID: 1003, 1007, 1306, 4095(振动)
        // 先记录，确认后再决定是否触发推送
    }
}

// ====================== 构造函数 ======================
%ctor {
    @autoreleasepool {
        loadPrefs();

        // 清空旧日志
        [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)prefsChangedCb,
            (CFStringRef)kPrefsChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            clearDelivered();
        }];

        // 通知权限自检
        [[UNUserNotificationCenter currentNotificationCenter]
            getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            qrpLog(@"notification auth status: %ld", (long)settings.authorizationStatus);
            if (settings.authorizationStatus != UNAuthorizationStatusAuthorized) {
                qrpLog(@"WARNING: QQ notification permission NOT granted!");
            }
        }];

        qrpLog(@"loaded (enabled=%d front=%d content=%d debug=%d test=%d)",
              gEnabled, gFrontBanner, gShowContent, gDebug, gTestNotify);

        // 2 秒后：检查并 swizzle 当前的 UNUserNotificationCenter delegate
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id<UNUserNotificationCenterDelegate> dlg =
                [UNUserNotificationCenter currentNotificationCenter].delegate;
            qrpLog(@"current delegate=%@ class=%@",
                   dlg, dlg ? NSStringFromClass([dlg class]) : @"nil");
            if (dlg && gEnabled && gFrontBanner) {
                swizzleDelegateClass([dlg class]);
            }
        });

        // 3 秒后：发测试通知
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            postTestNotification();
        });

        // 5 秒后：swizzle AppDelegate 远程推送方法 + 运行时类发现
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // AppDelegate 远程推送
            id appDelegate = [UIApplication sharedApplication].delegate;
            if (appDelegate) {
                Class cls = [appDelegate class];
                SEL sel = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    orig_didReceiveRemoteNotification = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hook_didReceiveRemoteNotification);
                    qrpLog(@"swizzled AppDelegate didReceiveRemoteNotification on %@",
                           NSStringFromClass(cls));
                } else {
                    qrpLog(@"AppDelegate %@ has no didReceiveRemoteNotification method",
                           NSStringFromClass(cls));
                }
            }

            // 运行时类发现
            discoverMessageClasses();
        });
    }
}
