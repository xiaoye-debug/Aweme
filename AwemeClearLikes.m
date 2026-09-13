#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation NSObject (AwemeClearLikes)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[AwemeClearLikes] Dylib loaded successfully!");
        
        // 挂钩 UIViewController 的 viewDidLoad 展示注入成功提示/添加UI
        Class class = [UIViewController class];
        SEL originalSelector = @selector(viewDidLoad);
        SEL swizzledSelector = @selector(acl_viewDidLoad);

        Method originalMethod = class_getInstanceMethod(class, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);

        BOOL didAddMethod = class_addMethod(class,
                                            originalSelector,
                                            method_getImplementation(swizzledMethod),
                                            method_getTypeEncoding(swizzledMethod));

        if (didAddMethod) {
            class_replaceMethod(class,
                                swizzledSelector,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod));
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

- (void)acl_viewDidLoad {
    [self acl_viewDidLoad];
    
    // 逻辑：识别用户主页或特定 Controller 后注入功能
    if ([NSStringFromClass([self class]) containsString:@"AWEUserDetailViewController"]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(20, 100, 100, 40);
        [button setTitle:@"清空点赞" forState:UIControlStateNormal];
        [button setBackgroundColor:[UIColor systemRedColor]];
        button.layer.cornerRadius = 8.0;
        [self.view addSubview:button];
    }
}

@end
