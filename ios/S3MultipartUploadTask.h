#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol S3MultipartUploadTaskDelegate <NSObject>
- (void)uploadTaskDidProgress:(NSString *)clientId progress:(float)progress;
- (void)uploadTaskDidCompletePart:(NSString *)clientId partNumber:(int)partNumber totalParts:(int)totalParts etag:(NSString *)etag;
- (void)uploadTaskDidComplete:(NSString *)clientId objectKey:(NSString *)objectKey;
- (void)uploadTaskDidFail:(NSString *)clientId error:(NSString *)error;
@end

@interface S3MultipartUploadTask : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property (nonatomic, weak) id<S3MultipartUploadTaskDelegate> delegate;
@property (nonatomic, readonly) NSString *clientId;
@property (nonatomic, readonly) BOOL isUploading;

- (instancetype)initWithClientId:(NSString *)clientId
                         fileURL:(NSURL *)fileURL
                        uploadId:(NSString *)uploadId
                       objectKey:(NSString *)objectKey
           presignedUrlEndpoint:(NSString *)presignedUrlEndpoint
               completeEndpoint:(NSString *)completeEndpoint
                       partSize:(int)partSize;

- (void)start;
- (void)resume;
- (void)cancel;

+ (NSDictionary * _Nullable)getUploadStatusForClientId:(NSString *)clientId;
+ (void)clearUploadStateForClientId:(NSString *)clientId;

@end

NS_ASSUME_NONNULL_END
