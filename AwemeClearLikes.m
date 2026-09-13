#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface AwemeFloatingManager : NSObject
+ (instancetype)sharedManager;
- (void)showFloatingButton;
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

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floatingButton) return;

        // 1. 创建悬浮按钮
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
        
        // 2. 添加点击事件与拖拽手势
        [button addTarget:self action:@selector(buttonClicked) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [button addGestureRecognizer:pan];
        
        self->_floatingButton = button;

        // 3. 寻找当前主 Window 并挂载
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *window in scene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                }
            }
        }
        
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }

        [keyWindow addSubview:button];
        [keyWindow bringSubviewToFront:button];
        NSLog(@"[AwemeClearLikes] Global floating button added to keyWindow successfully!");
    });
}

// 点击按钮响应
- (void)buttonClicked {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空点赞" 
                                                                   message:@"确定开始批量清空点赞作品吗？" 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"[AwemeClearLikes] 执行清空点赞逻辑...");
    }]];
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// 拖拽手势响应（贴边限制防走出屏幕）
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *button = pan.view;
    CGPoint translation = [pan translationInView:button.superview];
    
    CGPoint newCenter = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    
    // 边界限制
    CGFloat minX = button.frame.size.width / 2.0;
    CGFloat maxX = button.superview.bounds.size.width - minX;
    CGFloat minY = button.frame.size.height / 2.0 + 40; // 避开顶部状态栏
    CGFloat maxY = button.superview.bounds.size.height - minY;
    
    newCenter.x = MIN(MAX(newCenter.x, minX), maxX);
    newCenter.y = MIN(MAX(newCenter.y, minY), maxY);
    
    button.center = newCenter;
    [pan setTranslation:CGPointZero inView:button.superview];
}

@end

// 动态库初始化时调用
@implementation NSObject (AwemeClearLikesLoader)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 监听 App 启动完成通知，确保 Window 初始化后再挂载
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        }];
        
        // 容错机制：若已经启动完则延迟 2 秒直接展示
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AwemeFloatingManager sharedManager] showFloatingButton];
        });
    });
}

@end
