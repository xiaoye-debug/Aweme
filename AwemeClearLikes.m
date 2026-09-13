#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface AwemeFloatingManager : NSObject
+ (instancetype)sharedManager;
- (void)showFloatingButton;
@end

@implementation AwemeFloatingManager {
    UIButton *_floatingButton;
    BOOL _isProcessing; // 防止重复点击
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

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floatingButton) return;

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
        }
    });
}

// ----------------------------------------------------------------
// 核心逻辑：获取最顶层的 Controller 用于弹出提示框
// ----------------------------------------------------------------
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

// ----------------------------------------------------------------
// 按钮点击响应：确认后开始异步执行清空逻辑
// ----------------------------------------------------------------
- (void)buttonClicked {
    if (self->_isProcessing) {
        [self showAlertWithTitle:@"提示" message:@"任务正在执行中，请勿重复操作..."];
        return;
    }

    UIViewController *topVC = [self topViewController];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空点赞" 
                                                                   message:@"确定要开始批量取消点赞吗？过程无法撤销。" 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self executeClearLikesTask];
    }]];
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ----------------------------------------------------------------
// 核心业务：反射调用抖音私有数据管理器（DataController）
// ----------------------------------------------------------------
- (void)executeClearLikesTask {
    self->_isProcessing = YES;
    [self updateButtonTitle:@"清空中..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 通过 Runtime 寻找抖音点赞数据控制类 (AWELikeDataController)
        Class dataControllerClass = NSClassFromString(@"AWELikeDataController");
        if (!dataControllerClass) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"错误" message:@"未能获取抖音 API 实例，可能当前版本类名已变更。"];
                [self resetTaskState];
            });
            return;
        }

        // 2. 实例化或获取 DataController 单例
        id manager = nil;
        if ([dataControllerClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            manager = [dataControllerClass performSelector:NSSelectorFromString(@"sharedInstance")];
            #pragma clang diagnostic pop
        } else {
            manager = [[dataControllerClass alloc] init];
        }

        if (!manager) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"错误" message:@"初始化数据管理器失败。"];
                [self resetTaskState];
            });
            return;
        }

        // 3. 循环调用 API 取消点赞
        BOOL hasMore = YES;
        NSUInteger deletedCount = 0;

        while (hasMore) {
            // 获取 dataSource 数组
            NSMutableArray *dataSource = nil;
            if ([manager respondsToSelector:NSSelectorFromString(@"dataSource")]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                dataSource = [manager performSelector:NSSelectorFromString(@"dataSource")];
                #pragma clang diagnostic pop
            }

            if (dataSource.count == 0) {
                // 如果本地没有更多，尝试触发 loadMore
                if ([manager respondsToSelector:NSSelectorFromString(@"loadMoreWithCompletion:")]) {
                    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
                    void (^loadCompletion)(id, NSError *) = ^(id response, NSError *error) {
                        dispatch_semaphore_signal(sema);
                    };
                    
                    NSMethodSignature *sig = [manager methodSignatureForSelector:NSSelectorFromString(@"loadMoreWithCompletion:")];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                    [invocation setTarget:manager];
                    [invocation setSelector:NSSelectorFromString(@"loadMoreWithCompletion:")];
                    [invocation setArgument:&loadCompletion atIndex:2];
                    [invocation invoke];
                    
                    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
                } else {
                    hasMore = NO;
                    break;
                }
            }

            // 再次获取数据并执行删除
            if (dataSource && dataSource.count > 0) {
                id awemeModel = [dataSource firstObject];
                
                if ([manager respondsToSelector:NSSelectorFromString(@"deleteLikeWorkWithAweme:completion:")]) {
                    dispatch_semaphore_t delSema = dispatch_semaphore_create(0);
                    __block BOOL isSuccess = NO;

                    void (^deleteCompletion)(id, NSError *) = ^(id response, NSError *error) {
                        if (!error) {
                            isSuccess = YES;
                        }
                        dispatch_semaphore_signal(delSema);
                    };

                    NSMethodSignature *sig = [manager methodSignatureForSelector:NSSelectorFromString(@"deleteLikeWorkWithAweme:completion:")];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                    [invocation setTarget:manager];
                    [invocation setSelector:NSSelectorFromString(@"deleteLikeWorkWithAweme:completion:")];
                    [invocation setArgument:&awemeModel atIndex:2];
                    [invocation setArgument:&deleteCompletion atIndex:3];
                    [invocation invoke];

                    dispatch_semaphore_wait(delSema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));

                    if (isSuccess && dataSource.count > 0) {
                        [dataSource removeObjectAtIndex:0];
                        deletedCount++;
                    }
                }

                // 频率限制：每次请求间隔 0.6 秒，防止被限流/封号
                [NSThread sleepForTimeInterval:0.6];
            } else {
                hasMore = NO;
            }
        }

        // 4. 完成任务
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:@"完成" message:[NSString stringWithFormat:@"已成功清空 %lu 个点赞作品！", (unsigned long)deletedCount]];
            [self resetTaskState];
        });
    });
}

// ----------------------------------------------------------------
// 辅助工具方法
// ----------------------------------------------------------------
- (void)resetTaskState {
    self->_isProcessing = NO;
    [self updateButtonTitle:@"清空点赞"];
}

- (void)updateButtonTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floatingButton) {
            [self->_floatingButton setTitle:title forState:UIControlStateNormal];
        }
    });
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIViewController *topVC = [self topViewController];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title 
                                                                   message:message 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
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

@implementation NSObject (AwemeClearLikesLoader)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        }];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        });
    });
}

@end
