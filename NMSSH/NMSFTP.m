#import "NMSFTP.h"
#import "NMSSH+Protected.h"

@interface NMSFTP ()

@property (nonatomic, strong) NMSSHSession *session;
@property (nonatomic, assign) LIBSSH2_SFTP *sftpSession;
@property (nonatomic, readwrite, getter = isConnected) BOOL connected;

/**
 Queue used for asynchronous requests.
 
 Note: GCD objects are not managed by ARC until iOS 6. Therefore, GCD objects
 must be managed by us manually if building for iOS 5.
 */
#if OS_OBJECT_USE_OBJC
@property (nonatomic, strong) dispatch_queue_t queue;
#else
@property (nonatomic, assign) dispatch_queue_t queue;
#endif

- (NSData *)contentsAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger, NSUInteger))progress async:(BOOL)async;
- (BOOL)writeStream:(NSInputStream *)inputStream toSFTPHandle:(LIBSSH2_SFTP_HANDLE *)handle;
- (BOOL)writeStream:(NSInputStream *)inputStream toSFTPHandle:(LIBSSH2_SFTP_HANDLE *)handle progress:(BOOL (^)(NSUInteger))progress;

@end

@implementation NMSFTP

// -----------------------------------------------------------------------------
#pragma mark - INITIALIZER
// -----------------------------------------------------------------------------

+ (instancetype)connectWithSession:(NMSSHSession *)session {
    NMSFTP *sftp = [[NMSFTP alloc] initWithSession:session];
    [sftp connect];

    return sftp;
}

- (instancetype)initWithSession:(NMSSHSession *)session {
    if ((self = [super init])) {
        [self setSession:session];

        // Make sure we were provided a valid session
        if (![session isKindOfClass:[NMSSHSession class]]) {
            @throw @"You have to provide a valid NMSSHSession!";
        }
        
        self.queue = dispatch_queue_create("NMSFTPQueue", DISPATCH_QUEUE_SERIAL);
    }

    return self;
}

#if !(OS_OBJECT_USE_OBJC)
- (void)dealloc {
    if (self.queue) {
        dispatch_release(self.queue);
    }
}
#endif

// -----------------------------------------------------------------------------
#pragma mark - CONNECTION
// -----------------------------------------------------------------------------

- (BOOL)connect {
    // Set blocking mode
    libssh2_session_set_blocking(self.session.rawSession, 1);

    [self setSftpSession:libssh2_sftp_init(self.session.rawSession)];

    if (!self.sftpSession) {
        NMSSHLogError(@"Unable to init SFTP session");
        return NO;
    }

    [self setConnected:YES];

    return self.isConnected;
}

- (void)disconnect {
    libssh2_sftp_shutdown(self.sftpSession);
    [self setConnected:NO];
}

// -----------------------------------------------------------------------------
#pragma mark - MANIPULATE FILE SYSTEM ENTRIES
// -----------------------------------------------------------------------------

- (BOOL)moveItemAtPath:(NSString *)sourcePath toPath:(NSString *)destPath {
    return libssh2_sftp_rename(self.sftpSession, [sourcePath UTF8String], [destPath UTF8String]) == 0;
}

- (void)moveItemAtPath:(NSString *)sourcePath toPath:(NSString *)destPath success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self moveItemAtPath:sourcePath toPath:destPath];
        // Perform delegate callbacks on main queue to allow delegate to update UI.
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

// -----------------------------------------------------------------------------
#pragma mark - MANIPULATE DIRECTORIES
// -----------------------------------------------------------------------------

- (LIBSSH2_SFTP_HANDLE *)openDirectoryAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_opendir(self.sftpSession, [path UTF8String]);

    if (!handle) {
        NSError *error = [self.session lastError];
        NMSSHLogError(@"Could not open directory at path %@ (Error %li: %@)", path, (long)error.code, error.localizedDescription);

        if ([error code] == LIBSSH2_ERROR_SFTP_PROTOCOL) {
            NMSSHLogError(@"SFTP error %lu", libssh2_sftp_last_error(self.sftpSession));
        }
    }

    return handle;
}

- (BOOL)directoryExistsAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path flags:LIBSSH2_FXF_READ mode:0];

    if (!handle) {
        return NO;
    }

    LIBSSH2_SFTP_ATTRIBUTES fileAttributes;
    int rc = libssh2_sftp_fstat(handle, &fileAttributes);
    libssh2_sftp_close(handle);

    return rc == 0 && LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions);
}

- (void)directoryExistsAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self directoryExistsAtPath:path];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (BOOL)createDirectoryAtPath:(NSString *)path {
    int rc = libssh2_sftp_mkdir(self.sftpSession, [path UTF8String],
                                LIBSSH2_SFTP_S_IRWXU|
                                LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IXGRP|
                                LIBSSH2_SFTP_S_IROTH|LIBSSH2_SFTP_S_IXOTH);

    return rc == 0;
}

- (void)createDirectoryAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self createDirectoryAtPath:path];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (BOOL)removeDirectoryAtPath:(NSString *)path {
    return libssh2_sftp_rmdir(self.sftpSession, [path UTF8String]) == 0;
}

- (void)removeDirectoryAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self removeDirectoryAtPath:path];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = [self openDirectoryAtPath:path];

    if (!handle) {
        return nil;
    }

    NSArray *ignoredFiles = @[@".", @".."];
    NSMutableArray *contents = [NSMutableArray array];

    int rc;
    do {
        char buffer[512];
        LIBSSH2_SFTP_ATTRIBUTES fileAttributes;

        rc = libssh2_sftp_readdir(handle, buffer, sizeof(buffer), &fileAttributes);

        if (rc > 0) {
            NSString *fileName = [[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding];
            if (![ignoredFiles containsObject:fileName]) {
                // Append a "/" at the end of all directories
                if (LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions)) {
                    fileName = [fileName stringByAppendingString:@"/"];
                }

                NMSFTPFile *file = [[NMSFTPFile alloc] initWithFilename:fileName];
                [file populateValuesFromSFTPAttributes:fileAttributes];
                [contents addObject:file];
            }
        }
    } while (rc > 0);

    if (rc < 0) {
        NMSSHLogError(@"Unable to read directory");
    }

    rc = libssh2_sftp_closedir(handle);

    if (rc < 0) {
        NMSSHLogError(@"Failed to close directory");
    }

    return [contents sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [obj1 compare:obj2];
    }];
}

- (void)contentsOfDirectoryAtPath:(NSString *)path success:(void (^)(NSArray *))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        NSArray *contents = [self contentsOfDirectoryAtPath:path];
        if (contents && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(contents);
            });
        } else if (!contents && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

// -----------------------------------------------------------------------------
#pragma mark - MANIPULATE SYMLINKS AND FILES
// -----------------------------------------------------------------------------

- (NMSFTPFile *)infoForFileAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path flags:LIBSSH2_FXF_READ mode:0];

    if (!handle) {
        return nil;
    }

    LIBSSH2_SFTP_ATTRIBUTES fileAttributes;
    ssize_t rc = libssh2_sftp_fstat(handle, &fileAttributes);
    libssh2_sftp_close(handle);

    if (rc < 0) {
        return nil;
    }

    NMSFTPFile *file = [[NMSFTPFile alloc] initWithFilename:path.lastPathComponent];
    [file populateValuesFromSFTPAttributes:fileAttributes];

    return file;
}

- (void)infoForFileAtPath:(NSString *)path success:(void (^)(NMSFTPFile *))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        NMSFTPFile *file = [self infoForFileAtPath:path];
        if (file && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(file);
            });
        } else if (!file && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (LIBSSH2_SFTP_HANDLE *)openFileAtPath:(NSString *)path flags:(unsigned long)flags mode:(long)mode {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(self.sftpSession, [path UTF8String], flags, mode);

    if (!handle) {
        NSError *error = [self.session lastError];
        NMSSHLogError(@"Could not open file at path %@ (Error %li: %@)", path, (long)error.code, error.localizedDescription);

        if ([error code] == LIBSSH2_ERROR_SFTP_PROTOCOL) {
            NMSSHLogError(@"SFTP error %lu", libssh2_sftp_last_error(self.sftpSession));
        }
    }

    return handle;
}

- (BOOL)fileExistsAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path flags:LIBSSH2_FXF_READ mode:0];

    if (!handle) {
        return NO;
    }

    LIBSSH2_SFTP_ATTRIBUTES fileAttributes;
    int rc = libssh2_sftp_fstat(handle, &fileAttributes);
    libssh2_sftp_close(handle);

    return rc == 0 && !LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions);
}

- (void)fileExistsAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self fileExistsAtPath:path];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)linkPath
             withDestinationPath:(NSString *)destPath {
    int rc = libssh2_sftp_symlink(self.sftpSession, [destPath UTF8String], (char *)[linkPath UTF8String]);

    return rc == 0;
}

- (void)createSymbolicLinkAtPath:(NSString *)linkPath withDestinationPath:(NSString *)destPath success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self createSymbolicLinkAtPath:linkPath withDestinationPath:destPath];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (BOOL)removeFileAtPath:(NSString *)path {
    return libssh2_sftp_unlink(self.sftpSession, [path UTF8String]) == 0;
}

- (void)removeFileAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        BOOL ret = [self removeFileAtPath:path];
        if (ret && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(ret);
            });
        } else if (!ret && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (NSData *)contentsAtPath:(NSString *)path {
    return [self contentsAtPath:path progress:nil];
}

- (void)contentsAtPath:(NSString *)path success:(void (^)(NSData *))success failure:(void (^)(NSError *))failure {
    [self contentsAtPath:path progress:nil success:success failure:failure];
}

- (NSData *)contentsAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger, NSUInteger))progress async:(BOOL)async {
    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path flags:LIBSSH2_FXF_READ mode:0];
    
    if (!handle) {
        // @fixme Set lastError?
        return nil;
    }
    
    NMSFTPFile *file = [self infoForFileAtPath:path];
    if (!file) {
        NMSSHLogWarn(@"contentsAtPath:progress: failed to get file attributes");
        return nil;
    }
    
    char buffer[kNMSSHBufferSize];
    NSMutableData *data = [[NSMutableData alloc] init];
    ssize_t rc;
    off_t got = 0;
    while ((rc = libssh2_sftp_read(handle, buffer, (ssize_t)sizeof(buffer))) > 0) {
        [data appendBytes:buffer length:rc];
        got += rc;
        __block BOOL cont = YES; // `cont` is short for continue
        // Not processing asynchronously.
        if (!async && progress) {
            cont = progress((NSUInteger)got, (NSUInteger)[file.fileSize integerValue]);
        // Execute the `progress` method on the main queue.
        } else if (async && progress) {
            // Notice `dispatch_sync` NOT `async`. Wait for the UI to update and
            // return a result before continuing.
            dispatch_sync(dispatch_get_main_queue(), ^{
                cont = progress((NSUInteger)got, (NSUInteger)[file.fileSize integerValue]);
            });
        }
        if (!cont) {
            libssh2_sftp_close(handle);
            return nil;
        }
    }
    
    libssh2_sftp_close(handle);
    
    if (rc < 0) {
        return nil;
    }
    
    return [data copy];
}

- (NSData *)contentsAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger, NSUInteger))progress {
    return [self contentsAtPath:path progress:progress async:NO];
}

- (void)contentsAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger, NSUInteger))progress success:(void (^)(NSData *))success failure:(void (^)(NSError *))failure {
    dispatch_async(self.queue, ^{
        NSData *data = [self contentsAtPath:path progress:progress async:YES];
        if (data && success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success(data);
            });
        } else if (!data && failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(self.session.lastError);
            });
        }
    });
}

- (BOOL)writeContents:(NSData *)contents toFileAtPath:(NSString *)path {
    return [self writeContents:contents toFileAtPath:path progress:nil];
}

- (void)writeContents:(NSString *)contents toFileAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)writeContents:(NSData *)contents toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress {
    return [self writeStream:[NSInputStream inputStreamWithData:contents] toFileAtPath:path progress:progress];
}

- (void)writeContents:(NSString *)contents toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)writeFileAtPath:(NSString *)localPath toFileAtPath:(NSString *)path {
    return [self writeFileAtPath:localPath toFileAtPath:path progress:nil];
}

- (void)writeFileAtPath:(NSString *)localPath toFileAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)writeFileAtPath:(NSString *)localPath toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress {
    return [self writeStream:[NSInputStream inputStreamWithFileAtPath:localPath] toFileAtPath:path progress:progress];
}

- (void)writeFileAtPath:(NSString *)localPath toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)writeStream:(NSInputStream *)inputStream toFileAtPath:(NSString *)path {
    return [self writeStream:inputStream toFileAtPath:path progress:nil];
}

- (void)writeStream:(NSInputStream *)inputStream toFileAtPath:(NSString *)path success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)writeStream:(NSInputStream *)inputStream toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress {
    if ([inputStream streamStatus] == NSStreamStatusNotOpen) {
        [inputStream open];
    }

    if (![inputStream hasBytesAvailable]) {
        NMSSHLogWarn(@"No bytes available in the stream");
        return NO;
    }

    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path
                                                 flags:LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_TRUNC
                                                  mode:LIBSSH2_SFTP_S_IRUSR|LIBSSH2_SFTP_S_IWUSR|LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IROTH];

    if (!handle) {
        [inputStream close];
        return NO;
    }

    BOOL success = [self writeStream:inputStream toSFTPHandle:handle progress:progress];

    libssh2_sftp_close(handle);
    [inputStream close];

    return success;
}

- (void)writeStream:(NSInputStream *)inputStream toFileAtPath:(NSString *)path progress:(BOOL (^)(NSUInteger))progress success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo
}

- (BOOL)appendContents:(NSData *)contents toFileAtPath:(NSString *)path {
    return [self appendStream:[NSInputStream inputStreamWithData:contents] toFileAtPath:path];
}

- (BOOL)appendStream:(NSInputStream *)inputStream toFileAtPath:(NSString *)path {
    if ([inputStream streamStatus] == NSStreamStatusNotOpen) {
        [inputStream open];
    }

    if (![inputStream hasBytesAvailable]) {
        NMSSHLogWarn(@"No bytes available in the stream");
        return NO;
    }

    LIBSSH2_SFTP_HANDLE *handle = [self openFileAtPath:path
                                                 flags:LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_READ
                                                  mode:LIBSSH2_SFTP_S_IRUSR|LIBSSH2_SFTP_S_IWUSR|LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IROTH];

    if (!handle) {
        [inputStream close];
        return NO;
    }

    LIBSSH2_SFTP_ATTRIBUTES attributes;
    if (libssh2_sftp_fstat(handle, &attributes) < 0) {
        [inputStream close];
        NMSSHLogError(@"Unable to get attributes of file %@", path);
        return NO;
    }

    libssh2_sftp_seek64(handle, attributes.filesize);
    NMSSHLogVerbose(@"Seek to position %ld", (long)attributes.filesize);

    BOOL success = [self writeStream:inputStream toSFTPHandle:handle];

    libssh2_sftp_close(handle);
    [inputStream close];

    return success;
}

- (BOOL)writeStream:(NSInputStream *)inputStream toSFTPHandle:(LIBSSH2_SFTP_HANDLE *)handle {
    return [self writeStream:inputStream toSFTPHandle:handle progress:nil];
}

- (BOOL)writeStream:(NSInputStream *)inputStream toSFTPHandle:(LIBSSH2_SFTP_HANDLE *)handle progress:(BOOL (^)(NSUInteger))progress {
    uint8_t buffer[kNMSSHBufferSize];
    NSInteger bytesRead = -1;
    long rc = 0;
    NSUInteger total = 0;
    while (rc >= 0 && [inputStream hasBytesAvailable]) {
        bytesRead = [inputStream read:buffer maxLength:kNMSSHBufferSize];

        if (bytesRead > 0) {
            rc = libssh2_sftp_write(handle, (const char *)buffer, bytesRead);
            total += rc;
            if (progress && !progress(total))
            {
                return NO;
            }
        }
    }

    if (bytesRead < 0 || rc < 0) {
        return NO;
    }

    return YES;
}

- (BOOL)copyContentsOfPath:(NSString *)fromPath toFileAtPath:(NSString *)toPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress
{
    // Open handle for reading.
    LIBSSH2_SFTP_HANDLE *fromHandle = [self openFileAtPath:fromPath flags:LIBSSH2_FXF_READ mode:0];
    
    // Open handle for writing.
    LIBSSH2_SFTP_HANDLE *toHandle = [self openFileAtPath:toPath
                                                 flags:LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_READ
                                                  mode:LIBSSH2_SFTP_S_IRUSR|LIBSSH2_SFTP_S_IWUSR|LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IROTH];
    
    // Get information about the file to copy.
    NMSFTPFile *file = [self infoForFileAtPath:fromPath];
    if (!file) {
        NMSSHLogWarn(@"contentsAtPath:progress: failed to get file attributes");
        return NO;
    }
    
    char buffer[kNMSSHBufferSize];
    NSMutableData *data = [[NSMutableData alloc] init];
    ssize_t rc;
    off_t copied = 0;
    while ((rc = libssh2_sftp_read(fromHandle, buffer, (ssize_t)sizeof(buffer))) > 0) {
        [data appendBytes:buffer length:rc];
        libssh2_sftp_write(toHandle, (const char *)buffer, (NSInteger)rc);
        copied += rc;
        if (progress && !progress((NSUInteger)copied, (NSUInteger)[file.fileSize integerValue])) {
            libssh2_sftp_close(fromHandle);
            libssh2_sftp_close(toHandle);
            return NO;
        }
    }
    
    libssh2_sftp_close(fromHandle);
    libssh2_sftp_close(toHandle);
    
    return YES;
}

- (void)copyContentsOfPath:(NSString *)fromPath toFileAtPath:(NSString *)toPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress success:(void (^)(BOOL))success failure:(void (^)(NSError *))failure {
    // @todo 
}

@end
