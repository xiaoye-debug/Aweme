#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@class AwemeLikeCleaner;

// ================================================================
// 1. 悬浮窗管理器 (AwemeFloatingManager)
// ================================================================
@interface AwemeFloatingManager : NSObject
+ (instancetype)sharedManager;
- (void)showFloatingButton;
@end

// ================================================================
// 2. 点赞清理器 (AwemeLikeCleaner)
// ================================================================
@interface AwemeLikeCleaner : NSObject
@property (nonatomic, assign) BOOL isRunning;
+ (instancetype)sharedCleaner;
- (void)startBatchClearWithTarget:(id)dataController;
- (void)stopTask;
@end

@implementation AwemeFloatingManager {
    UIButton *_floatingButton;
}

+ (instancetype)sharedManager {
    static AwemeFloatingManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AwemeFloatingManager alloc] init];
    });
    return instance;
}

- (UIWindow *)fetchActiveKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        return window;
                    }
                }
            }
        }
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
    #pragma clang diagnostic pop
}

- (UIViewController *)topViewController {
    UIWindow *keyWindow = [self fetchActiveKeyWindow];
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC topViewController];
    }
    return topVC;
}

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floatingButton) {
            // 如果已存在，直接带到最外层
            [self->_floatingButton.superview bringSubviewToFront:self->_floatingButton];
            return;
        }

        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(20, 200, 80, 40);
        [button setTitle:@"清空点赞" forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        button.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:0.9];
        button.layer.cornerRadius = 20.0;
        button.layer.shadowColor = [UIColor blackColor].CGColor;
        button.layer.shadowOffset = CGSizeMake(0, 2);
        button.layer.shadowOpacity = 0.3;
        button.layer.shadowRadius = 4.0;
        
        [button addTarget:self action:@selector(buttonClicked) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [button addGestureRecognizer:pan];
        
        self->_floatingButton = button;

        UIWindow *keyWindow = [self fetchActiveKeyWindow];
        if (keyWindow) {
            [keyWindow addSubview:button];
            [keyWindow bringSubviewToFront:button];
            NSLog(@"[AwemeClear] 悬浮按钮挂载成功！");
        }
    });
}

// 自动寻找当前 View Controller 拥有的 DataController
- (id)findDataControllerFromVC:(UIViewController *)vc {
    if (!vc) return nil;
    
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList([vc class], &count);
    
    for (unsigned int i = 0; i < count; i++) {
        const char *propName = property_getName(properties[i]);
        NSString *name = [NSString stringWithUTF8String:propName];
        
        if ([name containsString:@"DataController"] || [name containsString:@"dataController"]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id targetObj = [vc performSelector:NSSelectorFromString(name)];
            #pragma clang diagnostic pop
            if (targetObj && [targetObj respondsToSelector:NSSelectorFromString(@"changeVideoDiggedStatus:videoID:")]) {
                free(properties);
                return targetObj;
            }
        }
    }
    free(properties);
    return nil;
}

- (void)buttonClicked {
    if ([AwemeLikeCleaner sharedCleaner].isRunning) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"任务执行中，要停止吗？" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"继续执行" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"停止任务" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AwemeLikeCleaner sharedCleaner] stopTask];
        }]];
        [[self topViewController] presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIViewController *topVC = [self topViewController];
    id dataController = [self findDataControllerFromVC:topVC];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空点赞" 
                                                                   message:dataController ? @"已定位点赞数据源，确定要开始批量取消点赞吗？" : @"未在当前页面自动寻找到数据源，请切到【我 - 喜欢】列表页面后再试。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (dataController) {
        [alert addAction:[UIAlertAction actionWithTitle:@"开始清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AwemeLikeCleaner sharedCleaner] startBatchClearWithTarget:dataController];
        }]];
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *button = pan.view;
    CGPoint translation = [pan translationInView:button.superview];
    
    CGPoint newCenter = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    
    CGFloat minX = button.frame.size.width / 2.0;
    CGFloat maxX = button.superview.bounds.size.width - minX;
    CGFloat minY = button.frame.size.height / 2.0 + 40;
    CGFloat maxY = button.superview.bounds.size.height - minY;
    
    newCenter.x = MIN(MAX(newCenter.x, minX), maxX);
    newCenter.y = MIN(MAX(newCenter.y, minY), maxY);
    
    button.center = newCenter;
    [pan setTranslation:CGPointMake(0, 0) inView:button.superview];
}

@end

// ================================================================
// 点赞清理器实现
// ================================================================
@implementation AwemeLikeCleaner

+ (instancetype)sharedCleaner {
    static AwemeLikeCleaner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AwemeLikeCleaner alloc] init];
    });
    return instance;
}

- (void)stopTask {
    self.isRunning = NO;
}

- (void)startBatchClearWithTarget:(id)dataController {
    if (!dataController || self.isRunning) return;
    self.isRunning = YES;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger totalDeletedCount = 0;
        BOOL hasMoreData = YES;
        
        while (self.isRunning && hasMoreData) {
            SEL loadMoreSel = NSSelectorFromString(@"loadMoreWithFilteredCompletion:");
            if ([dataController respondsToSelector:loadMoreSel]) {
                dispatch_semaphore_t sema = dispatch_semaphore_create(0);
                __block NSError *loadError = nil;
                
                void (^loadBlock)(id, NSError *) = ^(id response, NSError *error) {
                    loadError = error;
                    dispatch_semaphore_signal(sema);
                };
                
                NSMethodSignature *sig = [dataController methodSignatureForSelector:loadMoreSel];
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                [invocation setTarget:dataController];
                [invocation setSelector:loadMoreSel];
                [invocation setArgument:&loadBlock atIndex:2];
                [invocation invoke];
                
                dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));
            }
            
            NSArray *currentItems = nil;
            SEL dataSourceSel = NSSelectorFromString(@"dataSource");
            SEL awemeListSel = NSSelectorFromString(@"awemeList");
            
            if ([dataController respondsToSelector:dataSourceSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                currentItems = [dataController performSelector:dataSourceSel];
                #pragma clang diagnostic pop
            } else if ([dataController respondsToSelector:awemeListSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                currentItems = [dataController performSelector:awemeListSel];
                #pragma clang diagnostic pop
            }
            
            if (!currentItems || currentItems.count == 0) {
                hasMoreData = NO;
                break;
            }
            
            NSUInteger batchProcessed = 0;
            for (id item in [currentItems copy]) {
                if (!self.isRunning) break;
                
                NSString *videoID = nil;
                if ([item isKindOfClass:[NSString class]]) {
                    videoID = item;
                } else if ([item respondsToSelector:NSSelectorFromString(@"awemeID")]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    videoID = [item performSelector:NSSelectorFromString(@"awemeID")];
                    #pragma clang diagnostic pop
                } else if ([item respondsToSelector:NSSelectorFromString(@"itemID")]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    videoID = [item performSelector:NSSelectorFromString(@"itemID")];
                    #pragma clang diagnostic pop
                }
                
                if (!videoID || videoID.length == 0) continue;
                
                SEL changeStatusSel = NSSelectorFromString(@"changeVideoDiggedStatus:videoID:");
                if ([dataController respondsToSelector:changeStatusSel]) {
                    NSMethodSignature *sig = [dataController methodSignatureForSelector:changeStatusSel];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                    [invocation setTarget:dataController];
                    [invocation setSelector:changeStatusSel];
                    
                    NSInteger status = 0;
                    [invocation setArgument:&status atIndex:2];
                    [invocation setArgument:&videoID atIndex:3];
                    [invocation invoke];
                    
                    SEL removeSel = NSSelectorFromString(@"removeWithItemID:");
                    if ([dataController respondsToSelector:removeSel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [dataController performSelector:removeSel withObject:videoID];
                        #pragma clang diagnostic pop
                    }
                    
                    totalDeletedCount++;
                    batchProcessed++;
                    [NSThread sleepForTimeInterval:0.6];
                }
            }
            
            if (batchProcessed == 0) hasMoreData = NO;
        }
        
        self.isRunning = NO;
        NSLog(@"[AwemeClear] 任务完成，共清空 %lu 个作品", (unsigned long)totalDeletedCount);
    });
}

@end

// ================================================================
// 动态库初始化加载器（多阶段延迟挂载，确保 100% 出现）
// ================================================================
@implementation NSObject (AwemeClearLikesLoader)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 监听 App 激活通知
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        }];
        
        // 延迟挂载双保险
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        });
    });
}

@end
