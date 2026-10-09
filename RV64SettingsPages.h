#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Storage & media manager: import/remove/attach ISOs & disks, create images,
 * expand, sparsify, export (items 2, 3, 4, 12). */
@interface RV64DisksViewController : UITableViewController
@end

/* OpenSBI firmware picker/importer (item 10) */
@interface RV64FirmwareViewController : UITableViewController
@end

/* virtio-fs folder share manager (item 5) */
@interface RV64SharesViewController : UITableViewController
@end

/* GPU backend picker: none / rutabaga-gfxstream / virgl / venus (item 8) */
@interface RV64GPUViewController : UITableViewController
@end

/* JIT status & StikDebug helper (item 6) */
@interface RV64JITViewController : UITableViewController
@end

/* Background keep-alive: toggle + strategy picker (item 14) */
@interface RV64BackgroundViewController : UITableViewController
@end

/* Files.app / logs manager (item 11) */
@interface RV64FilesLogsViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
