#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdio.h>
#import <stdlib.h>

#pragma mark - 固定配置（请勿修改）
static NSString *const kCheckURL        = @"https://YOUR-SERVER/kami/check.php";
static NSString *const kAppName         = @"zfb370";
static NSString *const kSignKey         = @"zfb-5b9d8d8f0d0548b0";
static const NSTimeInterval kStartDelay = 1.5;          // 启动延迟1.5秒
static const NSTimeInterval kHeartbeatInterval = 50;    // 心跳间隔50秒
static const NSInteger kMaxHeartbeatFail = 5;           // 最大连续心跳失败次数
static const NSTimeInterval kTimestampTolerance = 120;  // 时间戳误差容忍120秒
static const NSTimeInterval kSuccessAlertDuration = 2;  // 成功弹窗显示时长

#pragma mark - 本地存储Key
static NSString *const kCachedCardKey   = @"com.keyt.kamicheck.cachedCard";
static NSString *const kBlacklistKey    = @"com.keyt.kamicheck.blacklist";
static NSString *const kSavedUDIDKey    = @"com.keyt.kamicheck.savedUDID";

#pragma mark - 全局变量
static NSTimer *_heartbeatTimer = nil;
static NSInteger _heartbeatFailCount = 0;
static NSString *_currentCard = nil;

#pragma mark - 工具函数
// 32位小写MD5
static NSString *MD5(NSString *input) {
    const char *cStr = input.UTF8String;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output.copy;
}

// 获取设备ID：优先IDFV，失败生成本地UUID持久化
static NSString *GetDeviceUDID() {
    NSString *idfv = [UIDevice currentDevice].identifierForVendor.UUIDString;
    if (idfv.length > 0) return idfv;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedUDID = [defaults stringForKey:kSavedUDIDKey];
    if (savedUDID.length > 0) return savedUDID;
    
    savedUDID = [NSUUID UUID].UUIDString;
    [defaults setObject:savedUDID forKey:kSavedUDIDKey];
    [defaults synchronize];
    return savedUDID;
}

// 获取本地缓存的有效卡密（排除黑名单）
static NSString *GetCachedValidCard() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *cachedCard = [defaults stringForKey:kCachedCardKey];
    if (cachedCard.length == 0) return nil;
    
    NSArray *blacklist = [defaults arrayForKey:kBlacklistKey] ?: @[];
    if ([blacklist containsObject:cachedCard]) return nil;
    
    return cachedCard;
}

// 保存有效卡密到本地
static void SaveValidCard(NSString *card) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:card forKey:kCachedCardKey];
    
    NSMutableArray *blacklist = [[defaults arrayForKey:kBlacklistKey] mutableCopy] ?: [NSMutableArray array];
    [blacklist removeObject:card];
    [defaults setObject:blacklist.copy forKey:kBlacklistKey];
    [defaults synchronize];
}

// 将卡密加入黑名单
static void AddToBlacklist(NSString *card) {
    if (card.length == 0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSMutableArray *blacklist = [[defaults arrayForKey:kBlacklistKey] mutableCopy] ?: [NSMutableArray array];
    if (![blacklist containsObject:card]) [blacklist addObject:card];
    
    [defaults removeObjectForKey:kCachedCardKey];
    [defaults setObject:blacklist.copy forKey:kBlacklistKey];
    [defaults synchronize];
}

// 格式化剩余时间
static NSString *FormatDuration(NSTimeInterval seconds) {
    NSInteger days = (NSInteger)seconds / 86400;
    NSInteger hours = ((NSInteger)seconds % 86400) / 3600;
    NSInteger minutes = ((NSInteger)seconds % 3600) / 60;
    
    if (days > 0) return [NSString stringWithFormat:@"%ld天%ld小时%ld分钟", (long)days, (long)hours, (long)minutes];
    if (hours > 0) return [NSString stringWithFormat:@"%ld小时%ld分钟", (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"%ld分钟", (long)minutes];
}

// 获取当前顶层控制器
static UIViewController *GetTopViewController() {
    UIViewController *rootVC = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            
            for (UIWindow *window in ws.windows) {
                if (window.isKeyWindow) {
                    rootVC = window.rootViewController;
                    break;
                }
            }
            if (rootVC) break;
        }
    } else {
        rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    }
    
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    return rootVC;
}

// 退出程序
static void ExitApp(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                       message:reason
                                                                preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *exitAction = [UIAlertAction actionWithTitle:@"退出"
                                                             style:UIAlertActionStyleDestructive
                                                           handler:^(UIAlertAction * _Nonnull action) {
            exit(0);
        }];
        [alert addAction:exitAction];
        [GetTopViewController() presentViewController:alert animated:NO completion:nil];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    });
}

// 显示验证成功弹窗
static void ShowSuccessAlert(NSTimeInterval remainingSeconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:@"验证成功，剩余授权时间：%@", FormatDuration(remainingSeconds)];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"验证通过"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [GetTopViewController() presentViewController:alert animated:NO completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSuccessAlertDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    });
}

// 发送同步验证/心跳请求
// ============ 本地卡密校验（无需服务器 / 无需网络） ============
static NSString *const kLocalAlphabet = @"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
static const long long kLocalEpoch = 1577836800LL;   // 2020-01-01 UTC

static int LocalB32Dec(NSString *s) {
    int n = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        NSString *ch = [NSString stringWithCharacters:&c length:1];
        NSRange r = [kLocalAlphabet rangeOfString:ch];
        if (r.location == NSNotFound) return -1;
        n = (n << 5) | (int)r.location;
    }
    return n;
}

static NSString *LocalB32Enc(int n, int len) {
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < len; i++) {
        [out insertString:[kLocalAlphabet substringWithRange:NSMakeRange(n & 31, 1)] atIndex:0];
        n >>= 5;
    }
    return out;
}

static int LocalSign20(NSString *prefix, NSString *udid) {
    NSString *h = MD5([NSString stringWithFormat:@"%@%@%@", kSignKey, prefix, udid ?: @""]);
    unsigned int v = 0;
    sscanf([[h substringToIndex:8] UTF8String], "%x", &v);
    return (int)(v & 0xFFFFF);
}

static NSDictionary *SendVerifyRequest(NSString *card) {
    NSString *raw = [[card stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length != 16) return @{@"success": @NO, @"error": @"卡密格式错误"};

    NSString *prefix = [raw substringToIndex:12];
    int sig = LocalB32Dec([raw substringFromIndex:12]);
    if (sig < 0) return @{@"success": @NO, @"error": @"卡密格式错误"};

    NSString *udid = GetDeviceUDID();
    BOOL ok = (sig == LocalSign20(prefix, udid)) || (sig == LocalSign20(prefix, @""));
    if (!ok) return @{@"success": @NO, @"error": @"卡密无效"};

    int days = LocalB32Dec([raw substringToIndex:4]);
    if (days < 0) return @{@"success": @NO, @"error": @"卡密格式错误"};

    long long expire = kLocalEpoch + (long long)days * 86400LL;
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    long long remain = expire - now;
    if (remain <= 0) return @{@"success": @NO, @"error": @"卡密已过期"};

    return @{@"success": @YES, @"remaining": @((double)remain)};
}

static void HeartbeatTick() {
    if (_currentCard.length == 0) return;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *result = SendVerifyRequest(_currentCard);
        BOOL success = [result[@"success"] boolValue];
        
        if (success) {
            _heartbeatFailCount = 0;
            return;
        }
        
        _heartbeatFailCount++;
        NSString *error = result[@"error"];
        
        // 卡密失效直接退出
        if ([error containsString:@"卡密"] || [error containsString:@"失效"] || 
            [error containsString:@"过期"] || [error containsString:@"无效"]) {
            AddToBlacklist(_currentCard);
            ExitApp([NSString stringWithFormat:@"卡密已失效：%@", error]);
            return;
        }
        
        // 连续失败次数超限退出
        if (_heartbeatFailCount >= kMaxHeartbeatFail) {
            ExitApp([NSString stringWithFormat:@"连续%ld次心跳失败，程序将退出", (long)kMaxHeartbeatFail]);
        }
    });
}

// 启动心跳定时器
static void StartHeartbeat() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_heartbeatTimer) {
            [_heartbeatTimer invalidate];
            _heartbeatTimer = nil;
        }
        _heartbeatFailCount = 0;
        
        if (@available(iOS 10.0, *)) {
            _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:kHeartbeatInterval
                                                              repeats:YES
                                                                block:^(NSTimer * _Nonnull timer) {
                HeartbeatTick();
            }];
        }
        [[NSRunLoop mainRunLoop] addTimer:_heartbeatTimer forMode:NSRunLoopCommonModes];
    });
}

// 显示卡密输入弹窗
static void ShowCardInputAlert(NSString *defaultCard) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡密验证"
                                                                       message:@"请输入您的卡密以继续使用"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"请输入卡密";
            textField.text = defaultCard ?: @"";
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        
        __block UIAlertAction *verifyAction = nil;
        // 退出按钮
        UIAlertAction *exitAction = [UIAlertAction actionWithTitle:@"退出"
                                                             style:UIAlertActionStyleCancel
                                                           handler:^(UIAlertAction * _Nonnull action) {
            exit(0);
        }];
        
        // 验证按钮
        verifyAction = [UIAlertAction actionWithTitle:@"验证"
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction * _Nonnull action) {
            NSString *card = alert.textFields.firstObject.text ?: @"";
            card = [card stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if (card.length == 0) {
                alert.message = @"卡密不能为空，请输入";
                return;
            }
            
            // 显示loading状态
            verifyAction.enabled = NO;
            exitAction.enabled = NO;
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            spinner.translatesAutoresizingMaskIntoConstraints = NO;
            [alert.view addSubview:spinner];
            [NSLayoutConstraint activateConstraints:@[
                [spinner.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
                [spinner.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-25]
            ]];
            [spinner startAnimating];
            
            // 子线程发送同步验证请求
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSDictionary *result = SendVerifyRequest(card);
                BOOL success = [result[@"success"] boolValue];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [spinner stopAnimating];
                    [spinner removeFromSuperview];
                    verifyAction.enabled = YES;
                    exitAction.enabled = YES;
                    
                    if (success) {
                        [alert dismissViewControllerAnimated:NO completion:^{
                            _currentCard = card;
                            SaveValidCard(card);
                            NSTimeInterval remaining = [result[@"remaining"] doubleValue];
                            ShowSuccessAlert(remaining);
                            StartHeartbeat();
                        }];
                    } else {
                        NSString *error = result[@"error"];
                        if ([error containsString:@"卡密"] || [error containsString:@"失效"] ||
                            [error containsString:@"过期"] || [error containsString:@"无效"]) {
                            AddToBlacklist(card);
                        }
                        alert.message = [NSString stringWithFormat:@"验证失败：%@", error];
                    }
                });
            });
        }];
        
        [alert addAction:exitAction];
        [alert addAction:verifyAction];
        alert.preferredAction = verifyAction;
        
        [GetTopViewController() presentViewController:alert animated:NO completion:nil];
    });
}

#pragma mark - 插件入口
%ctor {
    @autoreleasepool {
        // 延迟1.5秒启动验证，避免影响APP启动流程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *cachedCard = GetCachedValidCard();
            if (cachedCard.length > 0) {
                // 静默登录loading
                UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"正在验证"
                                                                                      message:@"请稍候..."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                spinner.translatesAutoresizingMaskIntoConstraints = NO;
                [loadingAlert.view addSubview:spinner];
                [NSLayoutConstraint activateConstraints:@[
                    [spinner.centerXAnchor constraintEqualToAnchor:loadingAlert.view.centerXAnchor],
                    [spinner.bottomAnchor constraintEqualToAnchor:loadingAlert.view.bottomAnchor constant:-25]
                ]];
                [spinner startAnimating];
                
                [GetTopViewController() presentViewController:loadingAlert animated:NO completion:^{
                    // 子线程验证缓存卡密
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        NSDictionary *result = SendVerifyRequest(cachedCard);
                        BOOL success = [result[@"success"] boolValue];
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [loadingAlert dismissViewControllerAnimated:NO completion:^{
                                if (success) {
                                    _currentCard = cachedCard;
                                    NSTimeInterval remaining = [result[@"remaining"] doubleValue];
                                    ShowSuccessAlert(remaining);
                                    StartHeartbeat();
                                } else {
                                    NSString *error = result[@"error"];
                                    if ([error containsString:@"卡密"] || [error containsString:@"失效"] ||
                                        [error containsString:@"过期"] || [error containsString:@"无效"]) {
                                        AddToBlacklist(cachedCard);
                                    }
                                    ShowCardInputAlert(nil);
                                }
                            }];
                        });
                    });
                }];
            } else {
                // 无缓存卡密，直接显示输入框
                ShowCardInputAlert(nil);
            }
        });
    }
}



