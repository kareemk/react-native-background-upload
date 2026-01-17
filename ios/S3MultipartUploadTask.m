#import "S3MultipartUploadTask.h"

static NSString *const kStateKeyPrefix = @"S3MultipartUpload-";

@interface S3MultipartUploadTask ()

@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSString *uploadId;
@property (nonatomic, strong) NSString *objectKey;
@property (nonatomic, strong) NSString *presignedUrlEndpoint;
@property (nonatomic, strong) NSString *completeEndpoint;
@property (nonatomic, assign) int partSize;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, assign) long long fileSize;
@property (nonatomic, assign) int totalParts;
@property (nonatomic, assign) int currentPart;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *completedParts;
@property (nonatomic, assign) BOOL isUploading;
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, assign) long long currentPartBytesSent;

@end

@implementation S3MultipartUploadTask

- (instancetype)initWithClientId:(NSString *)clientId
                         fileURL:(NSURL *)fileURL
                        uploadId:(NSString *)uploadId
                       objectKey:(NSString *)objectKey
           presignedUrlEndpoint:(NSString *)presignedUrlEndpoint
               completeEndpoint:(NSString *)completeEndpoint
                       partSize:(int)partSize
                        headers:(NSDictionary *)headers {
    self = [super init];
    if (self) {
        _clientId = clientId;
        _fileURL = fileURL;
        _uploadId = uploadId;
        _objectKey = objectKey;
        _presignedUrlEndpoint = presignedUrlEndpoint;
        _completeEndpoint = completeEndpoint;
        _partSize = partSize > 0 ? partSize : 5 * 1024 * 1024; // Default 5MB
        _headers = headers ?: @{};
        _completedParts = [NSMutableArray array];
        _isUploading = NO;
        _isCancelled = NO;
        _currentPart = 1;
        _currentPartBytesSent = 0;
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:
                                             [NSString stringWithFormat:@"S3MultipartUpload-%@", clientId]];
        config.discretionary = NO;
        config.sessionSendsLaunchEvents = YES;
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)start {
    if (_isUploading) {
        return;
    }
    
    _isUploading = YES;
    _isCancelled = NO;
    
    NSError *error;
    NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[_fileURL path] error:&error];
    if (error) {
        [self failWithError:[NSString stringWithFormat:@"Failed to get file attributes: %@", error.localizedDescription]];
        return;
    }
    
    _fileSize = [fileAttrs fileSize];
    _totalParts = (int)ceil((double)_fileSize / (double)_partSize);
    
    [self persistState];
    [self uploadNextPart];
}

- (void)resume {
    if (_isUploading) {
        return;
    }
    
    NSDictionary *state = [S3MultipartUploadTask getUploadStatusForClientId:_clientId];
    if (!state) {
        [self failWithError:@"No saved state found for this upload"];
        return;
    }
    
    _uploadId = state[@"uploadId"];
    _objectKey = state[@"objectKey"];
    _completedParts = [NSMutableArray arrayWithArray:state[@"completedParts"]];
    _totalParts = [state[@"totalParts"] intValue];
    _currentPart = [state[@"currentPart"] intValue];
    _fileSize = [state[@"fileSize"] longLongValue];
    
    _isUploading = YES;
    _isCancelled = NO;
    
    [self uploadNextPart];
}

- (void)cancel {
    _isCancelled = YES;
    _isUploading = NO;
    [_urlSession invalidateAndCancel];
}

#pragma mark - State Persistence

+ (NSString *)stateKeyForClientId:(NSString *)clientId {
    return [NSString stringWithFormat:@"%@%@", kStateKeyPrefix, clientId];
}

- (void)persistState {
    NSDictionary *state = @{
        @"uploadId": _uploadId ?: @"",
        @"objectKey": _objectKey ?: @"",
        @"completedParts": _completedParts ?: @[],
        @"totalParts": @(_totalParts),
        @"currentPart": @(_currentPart),
        @"fileSize": @(_fileSize),
        @"filePath": [_fileURL absoluteString] ?: @""
    };
    
    [[NSUserDefaults standardUserDefaults] setObject:state forKey:[S3MultipartUploadTask stateKeyForClientId:_clientId]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSDictionary *)getUploadStatusForClientId:(NSString *)clientId {
    return [[NSUserDefaults standardUserDefaults] objectForKey:[self stateKeyForClientId:clientId]];
}

+ (void)clearUploadStateForClientId:(NSString *)clientId {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self stateKeyForClientId:clientId]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Upload Logic

- (BOOL)isPartCompleted:(int)partNumber {
    for (NSDictionary *part in _completedParts) {
        if ([part[@"partNumber"] intValue] == partNumber) {
            return YES;
        }
    }
    return NO;
}

- (void)uploadNextPart {
    if (_isCancelled) {
        return;
    }
    
    // Skip completed parts
    while (_currentPart <= _totalParts && [self isPartCompleted:_currentPart]) {
        _currentPart++;
    }
    
    if (_currentPart > _totalParts) {
        [self completeUpload];
        return;
    }
    
    _currentPartBytesSent = 0;
    [self fetchPresignedUrlForPart:_currentPart];
}

- (void)fetchPresignedUrlForPart:(int)partNumber {
    NSString *urlString = [NSString stringWithFormat:@"%@?partNumber=%d&uploadId=%@&objectKey=%@",
                          _presignedUrlEndpoint,
                          partNumber,
                          [_uploadId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                          [_objectKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    
    // Add auth headers
    [_headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) return;
        
        if (error) {
            [strongSelf failWithError:[NSString stringWithFormat:@"Failed to get presigned URL: %@", error.localizedDescription]];
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            [strongSelf failWithError:[NSString stringWithFormat:@"Presigned URL request failed with status %ld", (long)httpResponse.statusCode]];
            return;
        }
        
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || !json[@"presignedUrl"]) {
            [strongSelf failWithError:@"Invalid presigned URL response"];
            return;
        }
        
        NSString *presignedUrl = json[@"presignedUrl"];
        [strongSelf uploadPartToUrl:presignedUrl partNumber:partNumber];
    }];
    [task resume];
}

- (void)uploadPartToUrl:(NSString *)presignedUrl partNumber:(int)partNumber {
    if (_isCancelled) return;
    
    long long startByte = (long long)(partNumber - 1) * _partSize;
    long long endByte = MIN(startByte + _partSize, _fileSize);
    long long chunkSize = endByte - startByte;
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:[_fileURL path]];
    if (!fileHandle) {
        [self failWithError:@"Failed to open file for reading"];
        return;
    }
    
    @try {
        [fileHandle seekToFileOffset:startByte];
        NSData *chunkData = [fileHandle readDataOfLength:(NSUInteger)chunkSize];
        [fileHandle closeFile];
        
        if (!chunkData || chunkData.length == 0) {
            [self failWithError:@"Failed to read file chunk"];
            return;
        }
        
        // Write chunk to temp file for background upload
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"s3-part-%@-%d.tmp", _clientId, partNumber]];
        [chunkData writeToFile:tempPath atomically:YES];
        NSURL *tempFileURL = [NSURL fileURLWithPath:tempPath];
        
        NSURL *url = [NSURL URLWithString:presignedUrl];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setHTTPMethod:@"PUT"];
        [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"%lld", chunkSize] forHTTPHeaderField:@"Content-Length"];
        
        NSURLSessionUploadTask *uploadTask = [_urlSession uploadTaskWithRequest:request fromFile:tempFileURL];
        uploadTask.taskDescription = [NSString stringWithFormat:@"%d", partNumber];
        [uploadTask resume];
        
    } @catch (NSException *exception) {
        [fileHandle closeFile];
        [self failWithError:[NSString stringWithFormat:@"Exception reading file: %@", exception.reason]];
    }
}

- (void)completeUpload {
    if (_isCancelled) return;
    
    // Sort parts by part number
    NSArray *sortedParts = [_completedParts sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"partNumber"] compare:b[@"partNumber"]];
    }];
    
    NSDictionary *body = @{
        @"uploadId": _uploadId,
        @"objectKey": _objectKey,
        @"parts": sortedParts
    };
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        [self failWithError:@"Failed to serialize complete request"];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:_completeEndpoint];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:jsonData];
    
    // Add auth headers
    [_headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) return;
        
        if (error) {
            [strongSelf failWithError:[NSString stringWithFormat:@"Complete upload failed: %@", error.localizedDescription]];
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            [strongSelf failWithError:[NSString stringWithFormat:@"Complete upload failed with status %ld", (long)httpResponse.statusCode]];
            return;
        }
        
        [S3MultipartUploadTask clearUploadStateForClientId:strongSelf.clientId];
        [strongSelf cleanupTempFiles];
        strongSelf.isUploading = NO;
        
        if ([strongSelf.delegate respondsToSelector:@selector(uploadTaskDidComplete:objectKey:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.delegate uploadTaskDidComplete:strongSelf.clientId objectKey:strongSelf.objectKey];
            });
        }
    }];
    [task resume];
}

- (void)cleanupTempFiles {
    for (int i = 1; i <= _totalParts; i++) {
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"s3-part-%@-%d.tmp", _clientId, i]];
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    }
}

- (void)failWithError:(NSString *)error {
    _isUploading = NO;
    if ([_delegate respondsToSelector:@selector(uploadTaskDidFail:error:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate uploadTaskDidFail:self.clientId error:error];
        });
    }
}

- (void)reportProgress {
    if (_fileSize == 0) return;
    
    long long completedBytes = (long long)_completedParts.count * _partSize;
    completedBytes += _currentPartBytesSent;
    
    // Cap at file size
    if (completedBytes > _fileSize) {
        completedBytes = _fileSize;
    }
    
    float progress = (float)completedBytes / (float)_fileSize * 100.0f;
    
    if ([_delegate respondsToSelector:@selector(uploadTaskDidProgress:progress:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate uploadTaskDidProgress:self.clientId progress:progress];
        });
    }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_isCancelled) return;
    
    int partNumber = [task.taskDescription intValue];
    
    // Clean up temp file
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"s3-part-%@-%d.tmp", _clientId, partNumber]];
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    
    if (error) {
        if (error.code != NSURLErrorCancelled) {
            [self failWithError:[NSString stringWithFormat:@"Part %d upload failed: %@", partNumber, error.localizedDescription]];
        }
        return;
    }
    
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        [self failWithError:[NSString stringWithFormat:@"Part %d upload failed with status %ld", partNumber, (long)httpResponse.statusCode]];
        return;
    }
    
    // Get ETag from response headers
    NSString *etag = [httpResponse.allHeaderFields objectForKey:@"ETag"];
    if (!etag) {
        etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
    }
    if (!etag) {
        etag = [httpResponse.allHeaderFields objectForKey:@"etag"];
    }
    
    if (!etag) {
        [self failWithError:[NSString stringWithFormat:@"No ETag in response for part %d", partNumber]];
        return;
    }
    
    // Remove quotes from ETag if present
    etag = [etag stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    
    NSDictionary *partInfo = @{
        @"partNumber": @(partNumber),
        @"etag": etag
    };
    [_completedParts addObject:partInfo];
    
    _currentPart = partNumber + 1;
    [self persistState];
    
    if ([_delegate respondsToSelector:@selector(uploadTaskDidCompletePart:partNumber:totalParts:etag:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate uploadTaskDidCompletePart:self.clientId partNumber:partNumber totalParts:self.totalParts etag:etag];
        });
    }
    
    [self uploadNextPart];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    _currentPartBytesSent = totalBytesSent;
    [self reportProgress];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!_responseData) {
        _responseData = [NSMutableData data];
    }
    [_responseData appendData:data];
}

@end
