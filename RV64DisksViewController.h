#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Disk manager: which disk images are attached to the VM, in what order (rvvm.disks), plus import, export, create, and delete.
@interface RV64DisksViewController : UITableViewController

// Adds a disk to the end of the attached list (no-op when already attached). Used by other screens.
+ (void)attachDiskNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
