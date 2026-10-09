#import "RV64FileStore.h"

#include <rvvm/rvvm_blk.h>

#include <sys/stat.h>
#include <unistd.h>

NSString *const RV64FileStoreFirmwareDir = @"firmware";
NSString *const RV64FileStoreDisksDir    = @"disks";
NSString *const RV64FileStoreIsosDir     = @"isos";
NSString *const RV64FileStoreSharesDir   = @"shares";
NSString *const RV64FileStoreLogsDir     = @"logs";

static const unsigned long long kMaxLogBytes = 4ULL << 20; // 4 MB per log file

@implementation RV64FileStore

+ (instancetype)shared
{
	static RV64FileStore *store;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		store = [[RV64FileStore alloc] init];
	});
	return store;
}

- (NSString *)documentsPath
{
	NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	return (docs.count > 0) ? docs.firstObject : NSTemporaryDirectory();
}

- (void)ensureLayout
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *base = [self documentsPath];
	for (NSString *cat in @[ RV64FileStoreFirmwareDir, RV64FileStoreDisksDir, RV64FileStoreIsosDir,
	                         RV64FileStoreSharesDir, RV64FileStoreLogsDir ]) {
		NSString *dir = [base stringByAppendingPathComponent:cat];
		if (![fm fileExistsAtPath:dir]) {
			[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
		}
	}
	// A starter share folder so virtio-fs always has something to bind
	NSString *shareDefault = [base stringByAppendingPathComponent:@"shares/shared"];
	if (![fm fileExistsAtPath:shareDefault]) {
		[fm createDirectoryAtPath:shareDefault withIntermediateDirectories:YES attributes:nil error:nil];
	}
}

- (NSString *)pathForCategory:(NSString *)category filename:(NSString *)filename
{
	return [[self documentsPath] stringByAppendingPathComponent:
	        [category stringByAppendingPathComponent:filename]];
}

- (NSString *)firmwarePath:(NSString *)filename
{
	return [self pathForCategory:RV64FileStoreFirmwareDir filename:filename];
}

- (NSString *)diskPath:(NSString *)filename
{
	return [self pathForCategory:RV64FileStoreDisksDir filename:filename];
}

- (NSString *)isoPath:(NSString *)filename
{
	return [self pathForCategory:RV64FileStoreIsosDir filename:filename];
}

- (NSString *)sharePath:(NSString *)subdir
{
	return [self pathForCategory:RV64FileStoreSharesDir filename:subdir];
}

- (NSString *)logPath:(NSString *)filename
{
	return [self pathForCategory:RV64FileStoreLogsDir filename:filename];
}

- (NSArray<NSString *> *)listDir:(NSString *)category filtered:(BOOL (^)(NSString *name))filter
{
	[self ensureLayout];
	NSString *dir = [[self documentsPath] stringByAppendingPathComponent:category];
	NSError *err = nil;
	NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&err];
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	if ([files isKindOfClass:[NSArray class]]) {
		for (NSString *f in files) {
			if (!filter || filter(f)) {
				[out addObject:f];
			}
		}
	}
	[out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	return out;
}

- (NSArray<NSString *> *)listFirmware
{
	return [self listDir:RV64FileStoreFirmwareDir filtered:^BOOL(NSString *name) {
		NSString *l = name.lowercaseString;
		return [l hasSuffix:@".bin"] || [l hasSuffix:@".elf"] || [l hasSuffix:@".img"] || [l hasSuffix:@".fw"];
	}];
}

- (NSArray<NSString *> *)listDisks
{
	return [self listDir:RV64FileStoreDisksDir filtered:^BOOL(NSString *name) {
		NSString *l = name.lowercaseString;
		return [l hasSuffix:@".img"] || [l hasSuffix:@".raw"] || [l hasSuffix:@".qcow2"] || [l hasSuffix:@".bin"];
	}];
}

- (NSArray<NSString *> *)listIsos
{
	return [self listDir:RV64FileStoreIsosDir filtered:^BOOL(NSString *name) {
		NSString *l = name.lowercaseString;
		return [l hasSuffix:@".iso"] || [l hasSuffix:@".img"];
	}];
}

- (NSArray<NSString *> *)listLogs
{
	return [self listDir:RV64FileStoreLogsDir filtered:^BOOL(NSString *name) {
		return [name.lowercaseString hasSuffix:@".log"] || [name.lowercaseString hasSuffix:@".txt"];
	}];
}

- (NSString *)importFileAtURL:(NSURL *)url
                     category:(NSString *)category
                         move:(BOOL)move
                        error:(NSString **)errorOut
{
	if (errorOut) {
		*errorOut = nil;
	}
	if (!url) {
		if (errorOut) {
			*errorOut = @"No file selected";
		}
		return nil;
	}
	[self ensureLayout];

	BOOL accessing = [url startAccessingSecurityScopedResource];

	NSString *name = url.lastPathComponent;
	if (name.length == 0) {
		name = @"imported.bin";
	}
	NSString *dst = [self pathForCategory:category filename:name];
	NSFileManager *fm = NSFileManager.defaultManager;

	// Never overwrite silently: add a numeric suffix
	NSString *base = [name stringByDeletingPathExtension];
	NSString *ext = name.pathExtension;
	NSUInteger idx = 1;
	while ([fm fileExistsAtPath:dst]) {
		NSString *candidate = [NSString stringWithFormat:@"%@-%lu", (unsigned long)idx,
		                      ext.length > 0 ? [base stringByAppendingFormat:@".%@", ext] : base];
		if (ext.length == 0) {
			candidate = [NSString stringWithFormat:@"%@-%lu", base, (unsigned long)idx];
		} else {
			candidate = [NSString stringWithFormat:@"%@-%lu.%@", base, (unsigned long)idx, ext];
		}
		dst = [self pathForCategory:category filename:candidate];
		name = candidate;
		idx++;
	}

	NSError *err = nil;
	BOOL ok = NO;
	if (move) {
		ok = [fm moveItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&err];
		if (!ok) {
			// Cross-volume moves fail: fall back to copy
			ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&err];
		}
	} else {
		ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&err];
	}

	if (accessing) {
		[url stopAccessingSecurityScopedResource];
	}

	if (!ok) {
		if (errorOut) {
			*errorOut = err.localizedDescription ?: @"Import failed";
		}
		return nil;
	}

	// Automatically sparsify imported disk images to save storage
	if ([category isEqualToString:RV64FileStoreDisksDir]) {
		uint64_t reclaimed = 0;
		(void)rvvm_blk_image_sparsify(dst.UTF8String, &reclaimed);
	}
	return name;
}

- (BOOL)deleteFileInCategory:(NSString *)category filename:(NSString *)filename
{
	NSString *path = [self pathForCategory:category filename:filename];
	if (path.length == 0) {
		return NO;
	}
	return [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

- (NSURL *)exportURLForCategory:(NSString *)category filename:(NSString *)filename
{
	NSString *path = [self pathForCategory:category filename:filename];
	if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
		return nil;
	}
	return [NSURL fileURLWithPath:path];
}

- (BOOL)createDiskImage:(NSString *)filename sizeBytes:(uint64_t)size error:(NSString **)errorOut
{
	if (errorOut) {
		*errorOut = nil;
	}
	if (filename.length == 0 || size == 0) {
		if (errorOut) {
			*errorOut = @"Filename and size are required";
		}
		return NO;
	}
	[self ensureLayout];
	NSString *path = [self diskPath:filename];
	if (!rvvm_blk_image_create(path.UTF8String, size)) {
		if (errorOut) {
			*errorOut = @"Failed to create image";
		}
		return NO;
	}
	return YES;
}

- (BOOL)resizeDiskImage:(NSString *)filename sizeBytes:(uint64_t)size error:(NSString **)errorOut
{
	if (errorOut) {
		*errorOut = nil;
	}
	NSString *path = [self diskPath:filename];
	if (path.length == 0 || size == 0) {
		if (errorOut) {
			*errorOut = @"Filename and size are required";
		}
		return NO;
	}
	if (!rvvm_blk_image_resize(path.UTF8String, size)) {
		if (errorOut) {
			*errorOut = @"Failed to resize image";
		}
		return NO;
	}
	return YES;
}

- (BOOL)sparsifyDiskImage:(NSString *)filename reclaimed:(uint64_t *)reclaimedOut error:(NSString **)errorOut
{
	if (errorOut) {
		*errorOut = nil;
	}
	NSString *path = [self diskPath:filename];
	if (path.length == 0) {
		if (errorOut) {
			*errorOut = @"Unknown image";
		}
		return NO;
	}
	uint64_t reclaimed = 0;
	if (!rvvm_blk_image_sparsify(path.UTF8String, &reclaimed)) {
		if (errorOut) {
			*errorOut = @"Failed to sparsify image";
		}
		return NO;
	}
	if (reclaimedOut) {
		*reclaimedOut = reclaimed;
	}
	return YES;
}

- (unsigned long long)fileSizeInCategory:(NSString *)category filename:(NSString *)filename
{
	NSString *path = [self pathForCategory:category filename:filename];
	struct stat st;
	if (stat(path.UTF8String, &st) != 0) {
		return 0;
	}
	return (unsigned long long)st.st_size;
}

- (unsigned long long)diskUsageInCategory:(NSString *)category filename:(NSString *)filename
{
	NSString *path = [self pathForCategory:category filename:filename];
	struct stat st;
	if (stat(path.UTF8String, &st) != 0) {
		return 0;
	}
	// st_blocks is in 512-byte units on Darwin
	return (unsigned long long)st.st_blocks * 512ULL;
}

- (void)appendLog:(NSString *)line toFile:(NSString *)filename
{
	if (line.length == 0 || filename.length == 0) {
		return;
	}
	[self ensureLayout];
	NSString *path = [self logPath:filename];
	NSFileManager *fm = NSFileManager.defaultManager;
	if (![fm fileExistsAtPath:path]) {
		[fm createFileAtPath:path contents:nil attributes:nil];
	}
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!fh) {
		return;
	}
	@try {
		[fh seekToEndOfFile];
		NSData *data = [[line dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]];
		[fh writeData:data];
		if (fh.offsetInFile > kMaxLogBytes) {
			// Rotate: keep the last half
			[fh closeFile];
			NSData *all = [NSData dataWithContentsOfFile:path];
			if (all.length > kMaxLogBytes / 2) {
				NSData *tail = [all subdataWithRange:NSMakeRange(all.length - kMaxLogBytes / 2, kMaxLogBytes / 2)];
				[fm removeItemAtPath:path error:nil];
				[fm createFileAtPath:path contents:tail attributes:nil];
			}
			return;
		}
	} @catch (NSException *e) {
		// Ignore log write failures
	}
	@try {
		[fh closeFile];
	} @catch (NSException *e) {
	}
}

- (void)clearLog:(NSString *)filename
{
	NSString *path = [self logPath:filename];
	[NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@end
