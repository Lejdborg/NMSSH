#import "NMSFTP.h"
#import "NMSSHSession.h"

#import "libssh2.h"
#import "libssh2_sftp.h"

@interface NMSFTP () {
    LIBSSH2_SFTP *sftpSession;
}
@end

@implementation NMSFTP
@synthesize session, connected;

// -----------------------------------------------------------------------------
// PUBLIC SETUP API
// -----------------------------------------------------------------------------

+ (id)connectWithSession:(NMSSHSession *)aSession {
    NMSFTP *sftp = [[NMSFTP alloc] initWithSession:aSession];
    [sftp connect];

    return sftp;
}

- (id)initWithSession:(NMSSHSession *)aSession {
    if ((self = [super init])) {
        session = aSession;

        // Make sure we were provided a valid session
        if (![session isKindOfClass:[NMSSHSession class]]) {
            return nil;
        }
    }

    return self;
}

// -----------------------------------------------------------------------------
// HANDLE CONNECTIONS
// -----------------------------------------------------------------------------

- (BOOL)connect {
    libssh2_session_set_blocking([session rawSession], 1);
    sftpSession = libssh2_sftp_init([session rawSession]);

    if (!sftpSession) {
        NSLog(@"NMSFTP: Unable to init SFTP session");
        return NO;
    }

    connected = YES;
    return [self isConnected];
}

- (void)disconnect {
    libssh2_sftp_shutdown(sftpSession);
    connected = NO;
}

// -----------------------------------------------------------------------------
// MANIPULATE FILE SYSTEM ENTRIES
// -----------------------------------------------------------------------------

- (BOOL)moveItemAtPath:(NSString *)sourcePath toPath:(NSString *)destPath {
    long rc = libssh2_sftp_rename(sftpSession, [sourcePath UTF8String],
                                           [destPath UTF8String]);

    return rc == 0;
}

// -----------------------------------------------------------------------------
// MANIPULATE DIRECTORIES
// -----------------------------------------------------------------------------

- (BOOL)directoryExistsAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(sftpSession, [path UTF8String],
                                                    LIBSSH2_FXF_READ, 0);
    LIBSSH2_SFTP_ATTRIBUTES fileAttributes;

    if (!handle) {
        return NO;
    }

    long rc = libssh2_sftp_fstat(handle, &fileAttributes);
    libssh2_sftp_close(handle);

    return rc == 0 && LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions);
}

- (BOOL)createDirectoryAtPath:(NSString *)path {
    int rc = libssh2_sftp_mkdir(sftpSession, [path UTF8String],
                            LIBSSH2_SFTP_S_IRWXU|
                            LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IXGRP|
                            LIBSSH2_SFTP_S_IROTH|LIBSSH2_SFTP_S_IXOTH);

    return rc == 0;
}

- (BOOL)removeDirectoryAtPath:(NSString *)path {
    return libssh2_sftp_rmdir(sftpSession, [path UTF8String]) == 0;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_opendir(sftpSession, [path UTF8String]);

    if (!handle) {
        NSLog(@"NMSFTP: Could not open directory");
        return nil;
    }

    NSArray *ignoredFiles = @[@".", @".."];
    NSMutableArray *contents = [NSMutableArray array];

    int rc;
    do {
        char buffer[512];
        LIBSSH2_SFTP_ATTRIBUTES fileAttributes;

        rc = libssh2_sftp_readdir(handle, buffer, sizeof(buffer), &fileAttributes);
        if (rc <= 0) {
            break;
        }

        NSString *fileName = [NSString stringWithUTF8String:buffer];
        if (![ignoredFiles containsObject:fileName]) {
            // Append a "/" at the end of all directories
            if (LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions)) {
                fileName = [fileName stringByAppendingString:@"/"];
            }

            [contents addObject:fileName];
        }
    } while (1);

    libssh2_sftp_closedir(handle);

    return [contents sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

// -----------------------------------------------------------------------------
// MANIPULATE SYMLINKS AND FILES
// -----------------------------------------------------------------------------

- (BOOL)fileExistsAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(sftpSession, [path UTF8String],
                                                    LIBSSH2_FXF_READ, 0);
    LIBSSH2_SFTP_ATTRIBUTES fileAttributes;

    if (!handle) {
        return NO;
    }

    long rc = libssh2_sftp_fstat(handle, &fileAttributes);
    libssh2_sftp_close(handle);

    return rc == 0 && !LIBSSH2_SFTP_S_ISDIR(fileAttributes.permissions);
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)linkPath
             withDestinationPath:(NSString *)destPath {
    int rc = libssh2_sftp_symlink(sftpSession, [destPath UTF8String],
                                  (char *)[linkPath UTF8String]);

    return rc == 0;
}

- (BOOL)removeFileAtPath:(NSString *)path {
    return libssh2_sftp_unlink(sftpSession, [path UTF8String]) == 0;
}

- (NSData *)contentsAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(sftpSession, [path UTF8String],
                                                    LIBSSH2_FXF_READ, 0);

    char buffer[0x4000];
    long rc = libssh2_sftp_read(handle, buffer, (ssize_t)sizeof(buffer));
    libssh2_sftp_close(handle);

    if (rc < 0) {
        return nil;
    }

    return [NSData dataWithBytes:buffer length:rc];
}

- (BOOL)writeContents:(NSData *)contents toFileAtPath:(NSString *)path {
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(sftpSession, [path UTF8String],
                      LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_TRUNC,
                      LIBSSH2_SFTP_S_IRUSR|LIBSSH2_SFTP_S_IWUSR|
                      LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IROTH);

    long rc = libssh2_sftp_write(handle, [contents bytes], [contents length]);
    libssh2_sftp_close(handle);

    return rc > 0;
}

- (BOOL)appendContents:(NSData *)contents toFileAtPath:(NSString *)path {
    // The reason for reading, appending and writing instead of using the
    // LIBSSH2_FXF_APPEND flag on libssh2_sftp_open is because the flag doesn't
    // seem to be reliable accross a variety of hosts.
    NSData *originalContents = [self contentsAtPath:path];
    if (!originalContents) {
        return NO;
    }

    NSMutableData *newContents = [originalContents mutableCopy];
    [newContents appendData:contents];

    return [self writeContents:newContents toFileAtPath:path];
}

@end
