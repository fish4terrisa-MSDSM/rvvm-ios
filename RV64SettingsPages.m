#import "RV64SettingsPages.h"
#import "RV64FileStore.h"
#import "RV64Runner.h"
#import "RV64BackgroundKeeper.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kRVVMDefaultsBackgroundEnabled = @"rvvm.backgroundEnabled";
static NSString *const kRVVMDefaultsBackgroundMode = @"rvvm.backgroundMode";

#pragma mark - Shared helpers

static void RVVMAlert(UIViewController *vc, NSString *title, NSString *msg)
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title
	                                                           message:msg
	                                                    preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[vc presentViewController:a animated:YES completion:nil];
}

static NSString *RVVMHumanSize(unsigned long long bytes)
{
	if (bytes >= (1ULL << 30)) {
		return [NSString stringWithFormat:@"%.2f GB", (double)bytes / (double)(1ULL << 30)];
	}
	if (bytes >= (1ULL << 20)) {
		return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (double)(1ULL << 20)];
	}
	if (bytes >= (1ULL << 10)) {
		return [NSString stringWithFormat:@"%.1f KB", (double)bytes / (double)(1ULL << 10)];
	}
	return [NSString stringWithFormat:@"%llu B", bytes];
}

#pragma mark - Disks & ISOs

@interface RV64DisksViewController () <UIDocumentPickerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *attachments;
@property (nonatomic, strong) NSArray<NSString *> *diskFiles;
@property (nonatomic, strong) NSArray<NSString *> *isoFiles;
@property (nonatomic, assign) BOOL busy;
@end

@implementation RV64DisksViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Disks & ISOs";
	self.navigationItem.rightBarButtonItems = @[
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		                                              target:self
		                                              action:@selector(importPressed)],
		[[UIBarButtonItem alloc] initWithTitle:@"New"
		                                 style:UIBarButtonItemStylePlain
		                                target:self
		                                action:@selector(createPressed)],
	];
	[self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self reload];
}

- (void)reload
{
	self.attachments = [RV64Runner attachments];
	self.diskFiles = [[RV64FileStore shared] listDisks];
	self.isoFiles = [[RV64FileStore shared] listIsos];
	[self.tableView reloadData];
}

- (BOOL)isAttached:(NSString *)category file:(NSString *)file
{
	for (NSDictionary *d in self.attachments) {
		if ([[d objectForKey:@"file"] isEqualToString:file] &&
		    [[d objectForKey:@"category"] isEqualToString:category]) {
			return YES;
		}
	}
	return NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	(void)tableView;
	return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	switch (section) {
		case 0: return (NSInteger)self.attachments.count;
		case 1: return (NSInteger)self.diskFiles.count;
		case 2: return (NSInteger)self.isoFiles.count;
	}
	return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	switch (section) {
		case 0: return @"Attached to the VM (boot order)";
		case 1: return @"Disk images (Documents/disks)";
		case 2: return @"ISO images (Documents/isos)";
	}
	return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	if (section == 0) {
		return @"Swipe an attachment to detach it. Tap to change its options. "
		       @"ISOs can be marked as the boot medium; multiple disks are "
		       @"attached as nvme0, nvme1, ... Imported images are sparsified automatically.";
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
		cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.accessoryView = nil;

	if (indexPath.section == 0) {
		NSDictionary *d = [self.attachments objectAtIndex:(NSUInteger)indexPath.row];
		NSString *file = [d objectForKey:@"file"] ?: @"?";
		NSString *cat = [d objectForKey:@"category"] ?: @"?";
		BOOL ro = [[d objectForKey:@"readonly"] boolValue];
		BOOL boot = [[d objectForKey:@"boot"] boolValue];
		NSString *categoryDir = [cat isEqualToString:@"isos"] ? RV64FileStoreIsosDir : RV64FileStoreDisksDir;
		unsigned long long sz = [[RV64FileStore shared] fileSizeInCategory:categoryDir filename:file];
		cell.textLabel.text = file;
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@%@",
		                            [cat isEqualToString:@"isos"] ? @"ISO" : @"Disk",
		                            RVVMHumanSize(sz),
		                            ro ? @"read-only" : @"read-write",
		                            boot ? @" · BOOT" : @""];
	} else {
		NSString *file = (indexPath.section == 1)
			? [self.diskFiles objectAtIndex:(NSUInteger)indexPath.row]
			: [self.isoFiles objectAtIndex:(NSUInteger)indexPath.row];
		NSString *cat = (indexPath.section == 1) ? RV64FileStoreDisksDir : RV64FileStoreIsosDir;
		unsigned long long sz = [[RV64FileStore shared] fileSizeInCategory:cat filename:file];
		unsigned long long du = [[RV64FileStore shared] diskUsageInCategory:cat filename:file];
		BOOL attached = [self isAttached:(indexPath.section == 1 ? @"disks" : @"isos") file:file];
		cell.textLabel.text = file;
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (on disk %@)%@",
		                            RVVMHumanSize(sz), RVVMHumanSize(du),
		                            attached ? @" · attached" : @""];
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	__weak RV64DisksViewController *weakSelf = self;
	if (indexPath.section == 0) {
		NSDictionary *d = [self.attachments objectAtIndex:(NSUInteger)indexPath.row];
		UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[d objectForKey:@"file"]
		                                                               message:@"Attachment options"
		                                                        preferredStyle:UIAlertControllerStyleActionSheet];
		[sheet addAction:[UIAlertAction actionWithTitle:@"Detach from VM" style:UIAlertActionStyleDestructive
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [NSMutableArray arrayWithArray:weakSelf.attachments];
			[arr removeObjectAtIndex:(NSUInteger)indexPath.row];
			[RV64Runner setAttachments:arr];
			[weakSelf reload];
		}]];
		if ([[d objectForKey:@"category"] isEqualToString:@"isos"]) {
			[sheet addAction:[UIAlertAction actionWithTitle:@"Set as boot ISO" style:UIAlertActionStyleDefault
			                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [NSMutableArray array];
			for (NSDictionary *x in weakSelf.attachments) {
				NSMutableDictionary *m = [x mutableCopy];
				[m setObject:@([[x objectForKey:@"file"] isEqual:[d objectForKey:@"file"]]) forKey:@"boot"];
				[arr addObject:m];
			}
			[RV64Runner setAttachments:arr];
			[weakSelf reload];
			}];
		}
		BOOL ro = [[d objectForKey:@"readonly"] boolValue];
		[sheet addAction:[UIAlertAction actionWithTitle:ro ? @"Make read-write" : @"Make read-only"
		                                          style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [NSMutableArray array];
			for (NSDictionary *x in weakSelf.attachments) {
				if ([[x objectForKey:@"file"] isEqual:[d objectForKey:@"file"]] &&
				    [[x objectForKey:@"category"] isEqual:[d objectForKey:@"category"]]) {
					NSMutableDictionary *m = [x mutableCopy];
					[m setObject:@(!ro) forKey:@"readonly"];
					[arr addObject:m];
				} else {
					[arr addObject:x];
				}
			}
			[RV64Runner setAttachments:arr];
			[weakSelf reload];
			}];
		[sheet addAction:[UIAlertAction actionWithTitle:@"Move earlier (boot order)" style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [weakSelf.attachments mutableCopy];
			NSUInteger i = (NSUInteger)indexPath.row;
			if (i > 0) {
				[arr exchangeObjectAtIndex:i withObjectAtIndex:i - 1];
				[RV64Runner setAttachments:arr];
				[weakSelf reload];
			}
		}]];
		[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		sheet.popoverPresentationController.sourceView = self.tableView;
		sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
		[self presentViewController:sheet animated:YES completion:nil];
		return;
	}

	// Media library row: offer the full action set
	NSString *file = (indexPath.section == 1)
		? [self.diskFiles objectAtIndex:(NSUInteger)indexPath.row]
		: [self.isoFiles objectAtIndex:(NSUInteger)indexPath.row];
	NSString *cat = (indexPath.section == 1) ? @"disks" : @"isos";
	BOOL attached = [self isAttached:cat file:file];

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:file
	                                                               message:nil
	                                                        preferredStyle:UIAlertControllerStyleActionSheet];
	if (!attached) {
		[sheet addAction:[UIAlertAction actionWithTitle:(indexPath.section == 2 ? @"Attach as ISO (bootable)" : @"Attach as disk (read-write)")
		                                          style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [NSMutableArray arrayWithArray:weakSelf.attachments];
			[arr addObject:@{ @"category": cat, @"file": file,
			                  @"readonly": @(indexPath.section == 2),
			                  @"boot": @(indexPath.section == 2 && weakSelf.attachments.count == 0) }];
			[RV64Runner setAttachments:arr];
			[weakSelf reload];
		}]];
		[sheet addAction:[UIAlertAction actionWithTitle:@"Attach read-only" style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSMutableArray *arr = [NSMutableArray arrayWithArray:weakSelf.attachments];
			[arr addObject:@{ @"category": cat, @"file": file, @"readonly": @YES, @"boot": @NO }];
			[RV64Runner setAttachments:arr];
			[weakSelf reload];
		}]];
	}
	if (indexPath.section == 1) {
		[sheet addAction:[UIAlertAction actionWithTitle:@"Expand image…" style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			[weakSelf promptResize:file];
		}]];
		[sheet addAction:[UIAlertAction actionWithTitle:@"Sparsify (reclaim zeros)" style:UIAlertActionStyleDefault
		                                        handler:^(UIAlertAction *a) {
			(void)a;
			NSString *err = nil;
			uint64_t reclaimed = 0;
			if ([[RV64FileStore shared] sparsifyDiskImage:file reclaimed:&reclaimed error:&err]) {
				RVVMAlert(weakSelf, @"Sparsified",
				          [NSString stringWithFormat:@"Reclaimed approximately %@.", RVVMHumanSize(reclaimed)]);
			} else {
				RVVMAlert(weakSelf, @"Sparsify failed", err ?: @"Unknown error");
			}
			[weakSelf reload];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Export…" style:UIAlertActionStyleDefault
	                                        handler:^(UIAlertAction *a) {
		(void)a;
		[weakSelf exportFile:file category:cat fromIndexPath:indexPath];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction *a) {
		(void)a;
		[[RV64FileStore shared] deleteFileInCategory:[cat isEqualToString:@"isos"] ? RV64FileStoreIsosDir : RV64FileStoreDisksDir
		                                     filename:file];
		[weakSelf reload];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = self.tableView;
	sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	if (indexPath.section == 0) {
		NSMutableArray *arr = [NSMutableArray arrayWithArray:self.attachments];
		[arr removeObjectAtIndex:(NSUInteger)indexPath.row];
		[RV64Runner setAttachments:arr];
	} else {
		NSString *file = (indexPath.section == 1)
			? [self.diskFiles objectAtIndex:(NSUInteger)indexPath.row]
			: [self.isoFiles objectAtIndex:(NSUInteger)indexPath.row];
		[[RV64FileStore shared] deleteFileInCategory:(indexPath.section == 1) ? RV64FileStoreDisksDir : RV64FileStoreIsosDir
		                                     filename:file];
	}
	[self reload];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	return (indexPath.section == 0) ? @"Detach" : @"Delete";
}

#pragma mark actions

- (void)importPressed
{
	// Import any file; ISOs land in isos/, everything else in disks/
	NSArray *types = @[ UTTypeData.identifier, UTTypeItem.identifier ];
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	for (NSURL *url in urls) {
		NSString *lower = url.lastPathComponent.lowercaseString;
		NSString *cat = [lower hasSuffix:@".iso"] ? RV64FileStoreIsosDir : RV64FileStoreDisksDir;
		NSString *err = nil;
		NSString *name = [[RV64FileStore shared] importFileAtURL:url category:cat move:NO error:&err];
		if (!name) {
			RVVMAlert(self, @"Import failed", err ?: @"Unknown error");
		}
	}
	[self reload];
}

- (void)createPressed
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Create disk image"
	                                                           message:@"A sparse raw image is created; storage is only used as the guest writes to it."
	                                                    preferredStyle:UIAlertControllerStyleAlert];
	[a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"filename.img";
		tf.text = @"new-disk.img";
	}];
	[a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"size (e.g. 8G, 512M, 2048)";
		tf.text = @"8G";
		tf.keyboardType = UIKeyboardTypeASCIICapable;
	}];
	__weak RV64DisksViewController *weakSelf = self;
	[a addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault
	                                    handler:^(UIAlertAction *act) {
		(void)act;
		NSString *name = a.textFields.firstObject.text ?: @"";
		NSString *sizeStr = a.textFields.lastObject.text ?: @"";
		if (name.length == 0) {
			return;
		}
		uint64_t size = RV64ParseSize(sizeStr);
		NSString *err = nil;
		if (size == 0 || ![[RV64FileStore shared] createDiskImage:name sizeBytes:size error:&err]) {
			RVVMAlert(weakSelf, @"Create failed", err ?: @"Invalid size");
		}
		[weakSelf reload];
	}]];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

static uint64_t RV64ParseSize(NSString *s)
{
	s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].uppercaseString;
	if (s.length == 0) {
		return 0;
	}
	double value = s.doubleValue;
	NSString *suffix = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet]
	                     componentsJoinedByString:@""];
	uint64_t mult = 1;
	if ([suffix containsString:@"G"]) {
		mult = 1ULL << 30;
	} else if ([suffix containsString:@"M"]) {
		mult = 1ULL << 20;
	} else if ([suffix containsString:@"K"]) {
		mult = 1ULL << 10;
	} else if ([suffix containsString:@"T"]) {
		mult = 1ULL << 40;
	}
	if (value <= 0) {
		return 0;
	}
	return (uint64_t)(value * (double)mult);
}

- (void)promptResize:(NSString *)file
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Expand %@", file]
	                                                           message:@"New size (the image only grows; use sparsify afterwards to reclaim space)."
	                                                    preferredStyle:UIAlertControllerStyleAlert];
	[a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"e.g. 16G";
		tf.text = @"16G";
	}];
	__weak RV64DisksViewController *weakSelf = self;
	[a addAction:[UIAlertAction actionWithTitle:@"Resize" style:UIAlertActionStyleDefault
	                                    handler:^(UIAlertAction *act) {
		(void)act;
		uint64_t size = RV64ParseSize(a.textFields.firstObject.text ?: @"");
		NSString *err = nil;
		if (size == 0 || ![[RV64FileStore shared] resizeDiskImage:file sizeBytes:size error:&err]) {
			RVVMAlert(weakSelf, @"Resize failed", err ?: @"Invalid size");
		}
		[weakSelf reload];
	}]];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)exportFile:(NSString *)file category:(NSString *)cat fromIndexPath:(NSIndexPath *)indexPath
{
	NSString *dir = [cat isEqualToString:@"isos"] ? RV64FileStoreIsosDir : RV64FileStoreDisksDir;
	NSURL *url = [[RV64FileStore shared] exportURLForCategory:dir filename:file];
	if (!url) {
		RVVMAlert(self, @"Export", @"File not found");
		return;
	}
	UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
	                                                                          applicationActivities:nil];
	if (avc.popoverPresentationController) {
		avc.popoverPresentationController.sourceView = self.tableView;
		avc.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
	}
	[self presentViewController:avc animated:YES completion:nil];
}

@end

#pragma mark - Firmware

@interface RV64FirmwareViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSString *> *firmwareFiles;
@end

@implementation RV64FirmwareViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"OpenSBI Firmware";
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		                                             target:self
		                                             action:@selector(importPressed)];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	self.firmwareFiles = [[RV64FileStore shared] listFirmware];
	[self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)self.firmwareFiles.count + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"Boot firmware (OpenSBI)";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"fw_payload bundles OpenSBI + the kernel jump; fw_jump jumps to a "
	       @"kernel passed separately. Import your own builds (Documents/firmware) "
	       @"via the + button or the Files app.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	NSString *selected = [RV64Runner selectedFirmware];
	if (indexPath.row == 0) {
		cell.textLabel.text = @"Bundled (app default)";
		cell.detailTextLabel.text = @"fw_payload.bin / fw_jump.bin";
		cell.accessoryType = [selected isEqualToString:@"bundled"] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else {
		NSString *file = [self.firmwareFiles objectAtIndex:(NSUInteger)(indexPath.row - 1)];
		cell.textLabel.text = file;
		unsigned long long sz = [[RV64FileStore shared] fileSizeInCategory:RV64FileStoreFirmwareDir filename:file];
		cell.detailTextLabel.text = RVVMHumanSize(sz);
		cell.accessoryType = [selected isEqualToString:file] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.row == 0) {
		[RV64Runner setSelectedFirmware:@"bundled"];
	} else {
		NSString *file = [self.firmwareFiles objectAtIndex:(NSUInteger)(indexPath.row - 1)];
		[RV64Runner setSelectedFirmware:file];
	}
	[self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath
{
	if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.row == 0) {
		return;
	}
	(void)tableView;
	NSString *file = [self.firmwareFiles objectAtIndex:(NSUInteger)(indexPath.row - 1)];
	[[RV64FileStore shared] deleteFileInCategory:RV64FileStoreFirmwareDir filename:file];
	self.firmwareFiles = [[RV64FileStore shared] listFirmware];
	[self.tableView reloadData];
}

- (void)importPressed
{
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData.identifier, UTTypeItem.identifier ]
		                                                          asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	for (NSURL *url in urls) {
		NSString *err = nil;
		(void)[[RV64FileStore shared] importFileAtURL:url category:RV64FileStoreFirmwareDir move:NO error:&err];
	}
	self.firmwareFiles = [[RV64FileStore shared] listFirmware];
	[self.tableView reloadData];
}

@end

#pragma mark - virtio-fs shares

@interface RV64SharesViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *shares;
@end

@implementation RV64SharesViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Shared Folders (virtio-fs)";
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
		                                             target:self
		                                             action:@selector(addPressed)];
	self.shares = [NSMutableArray arrayWithArray:[RV64Runner shares]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)self.shares.count + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"Folders shared into the guest";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"Each entry is exposed to the guest as a virtio-fs mount named by its "
	       @"tag (mount -t virtiofs <tag> /mnt). Documents is always shared as "
	       @"'share' when no custom shares exist. External folders are accessed "
	       @"with security-scoped bookmarks and keep working after a restart.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	if (indexPath.row == (NSInteger)self.shares.count) {
		cell.textLabel.text = @"Documents (default, tag: share)";
		cell.detailTextLabel.text = [[RV64FileStore shared] documentsPath];
		cell.accessoryType = UITableViewCellAccessoryNone;
	} else {
		NSDictionary *d = [self.shares objectAtIndex:(NSUInteger)indexPath.row];
		cell.textLabel.text = [d objectForKey:@"tag"] ?: @"share";
		cell.detailTextLabel.text = [d objectForKey:@"path"] ?: @"";
		cell.accessoryType = UITableViewCellAccessoryNone;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.row == (NSInteger)self.shares.count) {
		return;
	}
	__weak RV64SharesViewController *weakSelf = self;
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Share"
	                                                               message:nil
	                                                        preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Remove share" style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction *a) {
		(void)a;
		[weakSelf.shares removeObjectAtIndex:(NSUInteger)indexPath.row];
		[RV64Runner setShares:weakSelf.shares];
		[weakSelf.tableView reloadData];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = self.tableView;
	sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)addPressed
{
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	NSUInteger idx = self.shares.count;
	for (NSURL *url in urls) {
		BOOL scoped = [url startAccessingSecurityScopedResource];
		NSData *bookmark = nil;
		NSError *err = nil;
		bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
		                 includingResourceValuesForKeys:nil
		                                  relativeToURL:nil
		                          bookmarkDataIsStale:nil
		                                        error:&err];
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		NSString *tag = [NSString stringWithFormat:@"share%lu", (unsigned long)idx];
		NSString *name = url.lastPathComponent;
		if (name.length > 0) {
			tag = [NSString stringWithFormat:@"share-%@", name];
		}
		NSMutableDictionary *entry = [NSMutableDictionary dictionary];
		[entry setObject:tag forKey:@"tag"];
		[entry setObject:url.path forKey:@"path"];
		if (bookmark) {
			[entry setObject:bookmark forKey:@"bookmark"];
		}
		[self.shares addObject:entry];
		idx++;
	}
	[RV64Runner setShares:self.shares];
	[self.tableView reloadData];
}

@end

#pragma mark - GPU backend

@interface RV64GPUViewController ()
@property (nonatomic, strong) NSArray<NSString *> *backends;
@end

@implementation RV64GPUViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"GPU Backend";
	self.backends = @[ @"none", @"rutabaga", @"virgl", @"venus", @"virgl-venus" ];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)self.backends.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"3D acceleration backend for virtio-gpu";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"\"none\" is 2D only (bochs-style scanout).\n"
	       @"\"rutabaga\" uses the rutabaga gfxstream host (GLES/Vulkan forwarding).\n"
	       @"\"virgl\" / \"venus\" use virglrenderer: virgl = GLES (glmark2), "
	       @"venus = Vulkan on MoltenVK (vkmark). \"virgl-venus\" enables both.\n"
	       @"If the 3D backend library is missing, the display keeps working in 2D mode.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	NSString *b = [self.backends objectAtIndex:(NSUInteger)indexPath.row];
	cell.textLabel.text = ({
		NSString *t = b;
		if ([b isEqualToString:@"none"]) t = @"3D disabled (2D only)";
		if ([b isEqualToString:@"rutabaga"]) t = @"Rutabaga Gfxstream";
		if ([b isEqualToString:@"virgl"]) t = @"Virgl (virglrenderer / GLES)";
		if ([b isEqualToString:@"venus"]) t = @"Venus (virglrenderer / Vulkan on MoltenVK)";
		if ([b isEqualToString:@"virgl-venus"]) t = @"Virgl + Venus";
		t;
	});
	cell.detailTextLabel.text = b;
	cell.accessoryType = [[RV64Runner gpuBackend] isEqualToString:b] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[RV64Runner setGpuBackend:[self.backends objectAtIndex:(NSUInteger)indexPath.row]];
	[self.tableView reloadData];
}

@end

#pragma mark - JIT

@interface RV64JITViewController ()
@end

@implementation RV64JITViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"JIT";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"RVJIT (RISC-V dynamic recompiler)";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"The JIT is always compiled in and always requested at runtime. "
	       @"When executable pages cannot be allocated (no JIT enabler attached), "
	       @"RVVM automatically falls back to the interpreter - the app never "
	       @"disables the JIT, since JIT may also be enabled by methods the app "
	       @"cannot detect.\n\n"
	       @"To enable the JIT on iOS 17+, attach a JIT enabler such as StikDebug "
	       @"(pair it with your device, then tap 'Request JIT below) or sideload "
	       @"with a signer that grants dynamic-codesigning.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.accessoryType = UITableViewCellAccessoryNone;
	switch (indexPath.row) {
		case 0:
			cell.textLabel.text = @"JIT compiled in";
			cell.detailTextLabel.text = [RV64Runner jitCompiledIn] ? @"Yes" : @"No";
			break;
		case 1:
			cell.textLabel.text = @"Runtime behaviour";
			cell.detailTextLabel.text = @"Always request JIT; auto-fallback to interpreter";
			break;
		case 2:
			cell.textLabel.text = @"Open StikDebug";
			cell.detailTextLabel.text = @"Ask the JIT enabler to grant RWX to rvvm";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		case 3:
			cell.textLabel.text = @"Open SideJITServer";
			cell.detailTextLabel.text = @"Fallback enabler on the local network";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.row == 2) {
		// StikDebug registers a URL scheme; opening it starts the JIT flow
		NSURL *url = [NSURL URLWithString:@"stikdebug://"];
		if (url && [UIApplication.sharedApplication canOpenURL:url]) {
			[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
		} else {
			RVVMAlert(self, @"StikDebug not found",
			          @"Install StikDebug (or SideJITServer), pair it with this device, "
			          @"then retry. The VM itself never disables the JIT: with the "
			          @"enabler attached, RVJIT comes up automatically on next start.");
		}
	} else if (indexPath.row == 3) {
		NSURL *url = [NSURL URLWithString:@"http://localhost:8080/"];
		[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
	}
}

@end

#pragma mark - Background keep-alive

@interface RV64BackgroundViewController ()
@property (nonatomic, strong) NSArray<NSString *> *modes;
@end

@implementation RV64BackgroundViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Background";
	self.modes = @[ @"none", @"audio", @"task", @"location", @"combo" ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	(void)tableView;
	return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	return (section == 0) ? 1 : (NSInteger)self.modes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	return (section == 0) ? @"Keep the VM alive" : @"Method";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	if (section == 1) {
		return @"audio: silent audio loop (UIBackgroundModes: audio) - most reliable.\n"
		       @"task: chained background-task renewal (grace periods, then expiry).\n"
		       @"location: significant-change monitoring heartbeat (needs permission).\n"
		       @"combo: all of the above at once.\n\n"
		       @"iOS may still suspend apps under memory pressure or after prolonged "
		       @"background time; combo maximizes the odds. When suspended, the VM "
	       @"resumes from where it left off on next foreground.";
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	if (indexPath.section == 0) {
		cell.textLabel.text = @"Run in background";
		cell.detailTextLabel.text = [[RV64BackgroundKeeper shared] statusText];
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *sw = [UISwitch new];
		sw.on = [NSUserDefaults.standardUserDefaults boolForKey:kRVVMDefaultsBackgroundEnabled];
		[sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		return cell;
	}
	cell.accessoryView = nil;
	NSString *mode = [self.modes objectAtIndex:(NSUInteger)indexPath.row];
	cell.textLabel.text = ({
		NSString *t = mode;
		if ([mode isEqualToString:@"none"]) t = @"None (system default)";
		if ([mode isEqualToString:@"audio"]) t = @"Silent audio loop";
		if ([mode isEqualToString:@"task"]) t = @"Background task renewal";
		if ([mode isEqualToString:@"location"]) t = @"Location heartbeat";
		if ([mode isEqualToString:@"combo"]) t = @"Combo (audio + task + location)";
		t;
	});
	NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:kRVVMDefaultsBackgroundMode] ?: @"none";
	cell.accessoryType = [current isEqualToString:mode] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return cell;
}

- (void)toggleChanged:(UISwitch *)sw
{
	[NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kRVVMDefaultsBackgroundEnabled];
	[NSUserDefaults.standardUserDefaults synchronize];
	if (sw.isOn) {
		[self applyMode];
		[[RV64BackgroundKeeper shared] start];
	} else {
		[[RV64BackgroundKeeper shared] stop];
	}
	[self.tableView reloadData];
}

- (void)applyMode
{
	NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:kRVVMDefaultsBackgroundMode] ?: @"none";
	RV64BackgroundStrategy strategy = RV64BackgroundStrategyNone;
	if ([mode isEqualToString:@"audio"]) strategy = RV64BackgroundStrategyAudio;
	else if ([mode isEqualToString:@"task"]) strategy = RV64BackgroundStrategyTask;
	else if ([mode isEqualToString:@"location"]) strategy = RV64BackgroundStrategyLocation;
	else if ([mode isEqualToString:@"combo"]) strategy = RV64BackgroundStrategyCombo;
	[RV64BackgroundKeeper shared].strategy = strategy;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section != 1) {
		return;
	}
	NSString *mode = [self.modes objectAtIndex:(NSUInteger)indexPath.row];
	[NSUserDefaults.standardUserDefaults setObject:mode forKey:kRVVMDefaultsBackgroundMode];
	[NSUserDefaults.standardUserDefaults synchronize];
	[self applyMode];
	if ([NSUserDefaults.standardUserDefaults boolForKey:kRVVMDefaultsBackgroundEnabled]) {
		[[RV64BackgroundKeeper shared] start];
	}
	[self.tableView reloadData];
}

@end

#pragma mark - Files & logs

@interface RV64FilesLogsViewController () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) NSArray<NSString *> *logs;
@end

@implementation RV64FilesLogsViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Files & Logs";
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	self.logs = [[RV64FileStore shared] listLogs];
	[self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)self.logs.count + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"Logs (Documents/logs)";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return @"All VM files (disks, ISOs, firmware, shared folders and logs) live "
	       @"in this app's Documents folder and are visible in the system Files "
	       @"app under 'On My iPhone/iPad → rvvm' (iSH-style). Import by copying "
	       @"files there, export by dragging them out or via the share sheet in "
	       @"Disks & ISOs.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.accessoryView = nil;
	if (indexPath.row == (NSInteger)self.logs.count) {
		cell.textLabel.text = @"Open Documents in Files app";
		cell.detailTextLabel.text = [[RV64FileStore shared] documentsPath];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		return cell;
	}
	NSString *file = [self.logs objectAtIndex:(NSUInteger)indexPath.row];
	cell.textLabel.text = file;
	unsigned long long sz = [[RV64FileStore shared] fileSizeInCategory:RV64FileStoreLogsDir filename:file];
	cell.detailTextLabel.text = RVVMHumanSize(sz);
	cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.row == (NSInteger)self.logs.count) {
		// Reveal via share sheet (Files app entry point)
		NSURL *url = [NSURL fileURLWithPath:[[RV64FileStore shared] documentsPath]];
		UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
		                                                                          applicationActivities:nil];
		avc.popoverPresentationController.sourceView = self.tableView;
		avc.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
		[self presentViewController:avc animated:YES completion:nil];
		return;
	}
	NSString *file = [self.logs objectAtIndex:(NSUInteger)indexPath.row];
	NSString *path = [[RV64FileStore shared] logPath:file];
	NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"(empty)";
	UIViewController *viewer = [UIViewController new];
	viewer.title = file;
	viewer.view.backgroundColor = UIColor.systemBackgroundColor;
	UITextView *tv = [[UITextView alloc] initWithFrame:viewer.view.bounds];
	tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	tv.editable = NO;
	tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	tv.text = content;
	[viewer.view addSubview:tv];
	[self.navigationController pushViewController:viewer animated:YES];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath
{
	if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.row == (NSInteger)self.logs.count) {
		return;
	}
	(void)tableView;
	NSString *file = [self.logs objectAtIndex:(NSUInteger)indexPath.row];
	[[RV64FileStore shared] clearLog:file];
	self.logs = [[RV64FileStore shared] listLogs];
	[self.tableView reloadData];
}

@end
