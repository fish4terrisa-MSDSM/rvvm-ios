#import "RV64DisksViewController.h"
#import "RV64Runner.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kRVVMDefaultsDisks = @"rvvm.disks";
static NSString *const kRVVMDefaultsDiskFilename = @"rvvm.diskFilename";
static NSString *const kRVVMDefaultsExtraDisks = @"rvvm.extraDisks";

static NSString *DocumentsPath(void)
{
	return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static BOOL IsDiskImageName(NSString *name)
{
	NSString *lower = name.lowercaseString;
	return [lower hasSuffix:@".img"] || [lower hasSuffix:@".raw"] || [lower hasSuffix:@".qcow2"];
}

// Current attached list, migrating legacy primary/extra keys on first use.
static NSMutableArray<NSString *> *LoadAttachedDisks(void)
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSArray<NSString *> *stored = [d arrayForKey:kRVVMDefaultsDisks];
	NSMutableArray<NSString *> *list = [NSMutableArray array];
	if (stored) {
		[list addObjectsFromArray:stored];
		return list;
	}
	NSString *primary = [d stringForKey:kRVVMDefaultsDiskFilename];
	if (primary.length > 0) {
		[list addObject:primary];
	}
	for (NSString *name in [d arrayForKey:kRVVMDefaultsExtraDisks] ?: @[]) {
		if (![list containsObject:name]) {
			[list addObject:name];
		}
	}
	return list;
}

static void StoreAttachedDisks(NSArray<NSString *> *list)
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	[d setObject:list forKey:kRVVMDefaultsDisks];
	// The legacy keys are superseded; drop them so they cannot override the list.
	[d removeObjectForKey:kRVVMDefaultsDiskFilename];
	[d removeObjectForKey:kRVVMDefaultsExtraDisks];
}

static NSString *UniqueName(NSString *name)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSString *docs = DocumentsPath();
	if (![fm fileExistsAtPath:[docs stringByAppendingPathComponent:name]]) {
		return name;
	}
	NSString *base = name.stringByDeletingPathExtension;
	NSString *ext = name.pathExtension;
	for (int i = 2; i < 1000; i++) {
		NSString *candidate = [NSString stringWithFormat:@"%@ %d.%@", base, i, ext];
		if (![fm fileExistsAtPath:[docs stringByAppendingPathComponent:candidate]]) {
			return candidate;
		}
	}
	return [NSString stringWithFormat:@"%@ %@.%@", base, NSUUID.UUID.UUIDString, ext];
}

@interface RV64DisksViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *attached; // boot order
@property (nonatomic, strong) NSMutableArray<NSString *> *available;
@end

@implementation RV64DisksViewController

+ (void)attachDiskNamed:(NSString *)name
{
	NSMutableArray<NSString *> *list = LoadAttachedDisks();
	if (![list containsObject:name]) {
		[list addObject:name];
		StoreAttachedDisks(list);
	}
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Disks";
	self.navigationItem.rightBarButtonItems = @[
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addTapped:)],
		self.editButtonItem,
	];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self reload];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
	[super setEditing:editing animated:animated];
	[self.tableView setEditing:editing animated:animated];
}

- (void)reload
{
	NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:DocumentsPath() error:nil] ?: @[];
	NSMutableArray<NSString *> *stored = LoadAttachedDisks();
	self.attached = [NSMutableArray array];
	for (NSString *name in stored) {
		if ([files containsObject:name] && ![self.attached containsObject:name]) {
			[self.attached addObject:name];
		}
	}
	self.available = [NSMutableArray array];
	for (NSString *name in [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
		if (IsDiskImageName(name) && ![self.attached containsObject:name]) {
			[self.available addObject:name];
		}
	}
	[self.tableView reloadData];
}

- (void)persist
{
	StoreAttachedDisks(self.attached);
}

- (void)alert:(NSString *)title message:(NSString *)message
{
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)refuseIfRunning
{
	if ([RV64Runner isRunning]) {
		[self alert:@"VM running" message:@"Stop the VM before changing disks."];
		return YES;
	}
	return NO;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return section == 0 ? @"Attached (boot order, top first)" : @"Available disk images";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	if (section == 0) {
		return self.attached.count == 0 ? @"No disks attached. Tap an available image to attach it. Use Edit to reorder." : nil;
	}
	return @"Import or create images with +. Images are stored sparse, so they only use the space they fill.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return section == 0 ? self.attached.count : self.available.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"disk"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"disk"];
	}
	NSString *name = indexPath.section == 0 ? self.attached[indexPath.row] : self.available[indexPath.row];
	cell.textLabel.text = name;
	NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:[DocumentsPath() stringByAppendingPathComponent:name] error:nil][NSFileSize];
	NSString *sizeText = [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile];
	if (indexPath.section == 0) {
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1, sizeText];
		cell.accessoryType = UITableViewCellAccessoryCheckmark;
	} else {
		cell.detailTextLabel.text = sizeText;
		cell.accessoryType = UITableViewCellAccessoryNone;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if ([self refuseIfRunning]) {
		return;
	}
	if (indexPath.section == 0) {
		[self.attached removeObjectAtIndex:indexPath.row];
	} else {
		[self.attached addObject:self.available[indexPath.row]];
	}
	[self persist];
	[self reload];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
	return indexPath.section == 0;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed
{
	if (proposed.section != 0) {
		return [NSIndexPath indexPathForRow:self.attached.count - 1 inSection:0];
	}
	return proposed;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination
{
	NSString *name = self.attached[source.row];
	[self.attached removeObjectAtIndex:source.row];
	[self.attached insertObject:name atIndex:destination.row];
	[self persist];
	[tableView reloadData];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSString *name = indexPath.section == 0 ? self.attached[indexPath.row] : self.available[indexPath.row];
	UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
		(void)a; (void)v;
		if ([self refuseIfRunning]) {
			done(NO);
			return;
		}
		[NSFileManager.defaultManager removeItemAtPath:[DocumentsPath() stringByAppendingPathComponent:name] error:nil];
		[self.attached removeObject:name];
		[self persist];
		[self reload];
		done(YES);
	}];
	UIContextualAction *exp = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Export" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
		(void)a; (void)v;
		NSURL *url = [NSURL fileURLWithPath:[DocumentsPath() stringByAppendingPathComponent:name]];
		UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
		UIPopoverPresentationController *ppc = avc.popoverPresentationController;
		if (ppc) {
			ppc.sourceView = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
			ppc.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
		}
		[self presentViewController:avc animated:YES completion:nil];
		done(YES);
	}];
	exp.backgroundColor = UIColor.systemBlueColor;
	return [UISwipeActionsConfiguration configurationWithActions:@[del, exp]];
}

#pragma mark - Add

- (void)addTapped:(UIBarButtonItem *)sender
{
	if ([self refuseIfRunning]) {
		return;
	}
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add disk" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Import disk image..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		(void)a;
		UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
		picker.delegate = self;
		picker.allowsMultipleSelection = NO;
		[self presentViewController:picker animated:YES completion:nil];
	}]];
	NSArray<NSNumber *> *sizes = @[@1, @4, @16, @32, @64];
	for (NSNumber *g in sizes) {
		[sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"New %@ GiB disk (sparse)", g] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			(void)a;
			[self createDiskGiB:g.unsignedLongLongValue];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	UIPopoverPresentationController *ppc = sheet.popoverPresentationController;
	if (ppc) {
		ppc.barButtonItem = sender;
	}
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)createDiskGiB:(unsigned long long)gib
{
	NSString *name = UniqueName([NSString stringWithFormat:@"disk-%llug.img", gib]);
	NSString *err = nil;
	if (![RV64Runner createDiskImageNamed:name sizeBytes:(gib << 30) error:&err]) {
		[self alert:@"New disk" message:err ?: @"Failed to create the disk image."];
		return;
	}
	[self.attached addObject:name];
	[self persist];
	[self reload];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	NSURL *url = urls.firstObject;
	if (!url) {
		return;
	}
	BOOL access = [url startAccessingSecurityScopedResource];
	NSString *name = UniqueName(url.lastPathComponent);
	NSString *err = nil;
	// Imported images are copied in sparse, so holes in the source stay holes on disk.
	BOOL ok = [RV64Runner importDiskImageFromPath:url.path asName:name error:&err];
	if (access) {
		[url stopAccessingSecurityScopedResource];
	}
	if (!ok) {
		[self alert:@"Import disk" message:err ?: @"Import failed."];
		return;
	}
	[self.attached addObject:name];
	[self persist];
	[self reload];
}

@end
