#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface AwemeLikeCleaner : NSObject
@property (nonatomic, assign) BOOL isRunning;
+ (instancetype)sharedCleaner;
- (void)startBatchClearWithTarget:(id)dataController;
- (void)stopTask;
@end

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
    if (!dataController) {
        NSLog(@"[AwemeClear] 错误：Target DataController 为 nil");
        return;
    }
    
    if (self.isRunning) {
        NSLog(@"[AwemeClear] 任务正在运行中，请勿重复发起");
        return;
    }
    
    self.isRunning = YES;
    
    // 放入子线程后台循环执行，避免阻塞主 UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger totalDeletedCount = 0;
        BOOL hasMoreData = YES;
        
        NSLog(@"[AwemeClear] 🚀 开始执行自动分页批量取消点赞任务...");
        
        while (self.isRunning && hasMoreData) {
            
            // ----------------------------------------------------------------
            // Step 1: 触发 loadMoreWithFilteredCompletion: 分页拉取数据
            // ----------------------------------------------------------------
            SEL loadMoreSel = NSSelectorFromString(@"loadMoreWithFilteredCompletion:");
            if ([dataController respondsToSelector:loadMoreSel]) {
                dispatch_semaphore_t sema = dispatch_semaphore_create(0);
                __block NSError *loadError = nil;
                
                // 构造 Block 回调 ( completion: ^(id response, NSError *error) )
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
                
                // 等待接口异步回调，超时设置为 8 秒
                intptr_t result = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));
                if (result != 0 || loadError) {
                    NSLog(@"[AwemeClear] 加载更多失败或超时，停止或尝试直接读取现有列表");
                }
            }
            
            // ----------------------------------------------------------------
            // Step 2: 反射获取当前数据源列表 (dataSource / awemeList)
            // ----------------------------------------------------------------
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
                NSLog(@"[AwemeClear] 当前列表无更多数据，任务结束");
                hasMoreData = NO;
                break;
            }
            
            // ----------------------------------------------------------------
            // Step 3: 遍历列表，逐个获取 videoID 并调用 changeVideoDiggedStatus:videoID:
            // ----------------------------------------------------------------
            NSUInteger batchProcessed = 0;
            
            for (id item in [currentItems copy]) {
                if (!self.isRunning) break;
                
                // 提取 item 中的 videoID / itemID / item_id / awemeID
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
                
                // 执行取消点赞 API: changeVideoDiggedStatus:0 videoID:videoID
                SEL changeStatusSel = NSSelectorFromString(@"changeVideoDiggedStatus:videoID:");
                if ([dataController respondsToSelector:changeStatusSel]) {
                    NSMethodSignature *sig = [dataController methodSignatureForSelector:changeStatusSel];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                    [invocation setTarget:dataController];
                    [invocation setSelector:changeStatusSel];
                    
                    NSInteger status = 0; // 0 代表取消点赞 (1 代表点赞)
                    [invocation setArgument:&status atIndex:2];
                    [invocation setArgument:&videoID atIndex:3];
                    [invocation invoke];
                    
                    // 同步从本地集合中移除该 Item（避免重复读取）
                    SEL removeSel = NSSelectorFromString(@"removeWithItemID:");
                    if ([dataController respondsToSelector:removeSel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [dataController performSelector:removeSel withObject:videoID];
                        #pragma clang diagnostic pop
                    }
                    
                    totalDeletedCount++;
                    batchProcessed++;
                    NSLog(@"[AwemeClear] [%lu] 已成功取消点赞 VideoID: %@", (unsigned long)totalDeletedCount, videoID);
                    
                    // 防封频控：设置 0.6 秒间隔时间，平滑请求频次
                    [NSThread sleepForTimeInterval:0.6];
                }
            }
            
            // 本轮如果一个都没处理成功，说明数据无法解析，防止死循环
            if (batchProcessed == 0) {
                NSLog(@"[AwemeClear] 本轮未成功处理任何视频，终止循环");
                hasMoreData = NO;
            }
        }
        
        self.isRunning = NO;
        NSLog(@"[AwemeClear] 🎉 批量取消点赞任务完成！共计清空 %lu 个作品", (unsigned long)totalDeletedCount);
    });
}

@end
