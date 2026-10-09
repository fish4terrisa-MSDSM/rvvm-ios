#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * RV64FileStore
 *
 * Manages the on-disk layout inside the app's Documents directory, which is
 * exposed to the system Files app via UIFileSharingEnabled +
 * LSSupportsOpeningDocumentsInPlace (same approach iSH uses):
 *
 *   Documents/
 *     firmware/       OpenSBI firmware images (fw_jump.bin, fw_payload.bin, ...)
 *     disks/          Disk images (raw, sparse)
 *     isos/           ISO images
 *     shares/         Default virtio-fs share roots
 *     logs/           UART / virtio-fs / app logs (visible in Files app)
 *
 * All disk-image tooling is backed by RVVM's sparse image API
 * (rvvm_blk_image_create/resize/sparsify): newly created and imported images
 * are converted to sparse files to save storage.
 */

extern NSString *const RV64FileStoreFirmwareDir;
extern NSString *const RV64FileStoreDisksDir;
extern NSString *const RV64FileStoreIsosDir;
extern NSString *const RV64FileStoreSharesDir;
extern NSString *const RV64FileStoreLogsDir;

@interface RV64FileStore : NSObject

+ (instancetype)shared;

/* Paths */
- (NSString *)documentsPath;
- (NSString *)pathForCategory:(NSString *)category filename:(NSString *)filename;
- (NSString *)firmwarePath:(NSString *)filename;
- (NSString *)diskPath:(NSString *)filename;
- (NSString *)isoPath:(NSString *)filename;
- (NSString *)sharePath:(NSString *)subdir;
- (NSString *)logPath:(NSString *)filename;

/* Directory creation + Files.app visibility */
- (void)ensureLayout;

/* Listing */
- (NSArray<NSString *> *)listFirmware;
- (NSArray<NSString *> *)listDisks;
- (NSArray<NSString *> *)listIsos;
- (NSArray<NSString *> *)listLogs;

/* Import: copies/moves a picked file into the category directory.
 * Disk images are automatically sparsified after import. */
- (nullable NSString *)importFileAtURL:(NSURL *)url
                              category:(NSString *)category
                                  move:(BOOL)move
                                 error:(NSString * _Nullable * _Nullable)errorOut;

/* Delete a managed file */
- (BOOL)deleteFileInCategory:(NSString *)category filename:(NSString *)filename;

/* Export helper: returns a shareable file URL (inside Documents) */
- (nullable NSURL *)exportURLForCategory:(NSString *)category filename:(NSString *)filename;

/* Disk image tooling (backed by RVVM sparse image API) */
- (BOOL)createDiskImage:(NSString *)filename sizeBytes:(uint64_t)size error:(NSString * _Nullable * _Nullable)errorOut;
- (BOOL)resizeDiskImage:(NSString *)filename sizeBytes:(uint64_t)size error:(NSString * _Nullable * _Nullable)errorOut;
- (BOOL)sparsifyDiskImage:(NSString *)filename reclaimed:(uint64_t * _Nullable)reclaimedOut error:(NSString * _Nullable * _Nullable)errorOut;
- (unsigned long long)fileSizeInCategory:(NSString *)category filename:(NSString *)filename;
- (unsigned long long)diskUsageInCategory:(NSString *)category filename:(NSString *)filename;

/* Logs: append text to Documents/logs/<name>, kept bounded */
- (void)appendLog:(NSString *)line toFile:(NSString *)filename;
- (void)clearLog:(NSString *)filename;

@end

NS_ASSUME_NONNULL_END
