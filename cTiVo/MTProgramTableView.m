//
//  MTProgramList.m
//  myTivo
//
//  Created by Scott Buchanan on 12/7/12.
//  Copyright (c) 2012 Scott Buchanan. All rights reserved.
//

#import "MTProgramTableView.h"

#import "MTTiVoManager.h"
#import "MTMainWindowController.h"

#import "MTDownloadCheckTableCell.h"
#import "MTProgressCell.h"
#import "DragDropImageView.h"
#import "MTShowFolder.h"

@interface MTProgramTableView  ()

@property (nonatomic, assign) CGFloat imageRowHeight;
@property (weak) IBOutlet MTMainWindowController *myController;
@property (weak) IBOutlet NSButton *addToQueueButton;
@property (weak) IBOutlet NSButton *subscribeButton;

@property (nonatomic, strong) NSMutableDictionary <NSString *, MTShowFolder *> * oldFolders; //reuse from last reload (to avoid accidentally closing existing folders.)
@property (nonatomic, strong) NSArray <id> *sortedShows; //entries are either MTTiVoShows or, when hierarchical, folders
@property (nonatomic, strong) NSString *selectedTiVo;
@property (weak) IBOutlet NSSearchField *findText; //filter for displaying found subset of programs
@property (nonatomic, assign) BOOL viewAsFolders;

@end
@implementation MTProgramTableView


__DDLOGHERE__

#define kMTArtColumn @"Art"
-(id) initWithCoder:(NSCoder *)aDecoder
{
	self = [super initWithCoder:aDecoder];
	if (self) {
		[self setNotifications];
        DDLogVerbose(@"ProgramTable init");
        self.dataSource = self;
        self.delegate    = self;
        self.allowsMultipleSelection = YES;
        self.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
        self.selectedTiVo = [[NSUserDefaults standardUserDefaults] objectForKey:kMTSelectedTiVo];
        self.imageRowHeight = -1;
		self.oldFolders = [NSMutableDictionary dictionary];
	}
	return self;
}

-(void)setNotifications
{
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadEpisode:) name:kMTNotificationShowDownloadDidFinish object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadEpisode:) name:kMTNotificationDetailsLoaded object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadPicture:) name:kMTNotificationPictureLoaded object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:kMTNotificationTiVoShowsUpdated  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:kMTNotificationTiVoListUpdated object:nil];
 	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showTiVoColumn:) name:kMTNotificationFoundMultipleTiVos object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshAddToQueueButton:) name:kMTNotificationDownloadQueueUpdated object:nil];
	[[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:kMTShowCopyProtected options:NSKeyValueObservingOptionInitial context:nil];
	[[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:kMTShowSuggestions options:NSKeyValueObservingOptionInitial context:nil];
	[[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:kMTShowFolders options:NSKeyValueObservingOptionInitial context:nil];
    [[self tableColumnWithIdentifier:kMTArtColumn] addObserver:self forKeyPath:@"hidden" options:0 context:nil];
	[self  setDraggingSourceOperationMask:NSDragOperationMove forLocal:NO];
	[self  setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];

}

-(void)showTiVoColumn:(NSNotification *)notification {
    [self tableColumnWithIdentifier:@"TiVo"].hidden = NO;
}

-(void) reloadData {
    DDLogVerbose(@"Reload Program Table");
	//save selection to preserve after reloadData
	NSIndexSet *selectedRowIndexes = [self selectedRowIndexes];
	NSMutableArray <id> * oldSelection = [NSMutableArray arrayWithCapacity:selectedRowIndexes.count];
	[selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
		[oldSelection addObject: [self itemAtRow:idx]];
	}];

	self.sortedShows = nil;
	[self confirmColumns];

	[super reloadData];

	//now restore selection
	NSMutableIndexSet * showIndexes = [NSMutableIndexSet indexSet];
	for (id item in oldSelection) {
		NSUInteger row = [self rowForItem:item];
		if (row != NSNotFound) {
			MTShowFolder * parent = [self parentForItem:item];
			if (!parent || [self isItemExpanded:parent]) {
				//avoid formerly selected children that are no longer visible
				[showIndexes addIndex:row];
			}
		}
	}
    [self selectRowIndexes:showIndexes byExtendingSelection:NO];
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ([keyPath isEqualToString:kMTShowCopyProtected] ) {
		DDLogDetail(@"User changed ShowCopyProtected menu item");
 		[self reloadData];
	} else 	if ([keyPath isEqualToString:kMTShowSuggestions]) {
		DDLogDetail(@"User changed ShowSuggestions menu item");
		[self reloadData];
	} else 	if ([keyPath isEqualToString:kMTShowFolders]) {
		DDLogDetail(@"User changed showFolders menu item");
		[self reloadData];
    } else if ([keyPath isEqualToString:@"hidden"]){
        if (self.imageRowHeight > 0) [self columnChanged:object ];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

-(void)reloadEpisode:(NSNotification *)notification
{
    MTTiVoShow *thisShow = notification.object;
	NSInteger row = [self rowForItem:thisShow];
    if (row != NSNotFound) {
        NSRange columns = NSMakeRange(0,self.numberOfColumns);
        [self reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:columns]];
    }
}

-(void)reloadPicture:(NSNotification *)notification
{
    MTTiVoShow *thisShow = notification.object;
    NSInteger row = [self rowForItem:thisShow];
    if (row != NSNotFound) {
        [self reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:[self columnWithIdentifier:kMTArtColumn] ]];
    }
}

#pragma mark find/filter support

-(void) showFindField: (BOOL) show {
	[self.findText setHidden:!show];
	[self.findText setEnabled:show];
	if (!show) {
		self.findText.stringValue = @"";
		[self reloadData];
	}
}

- (BOOL)isTextFieldInFocus:(NSTextField *)textField
{
	NSResponder *firstResponder = [[textField window] firstResponder];
	BOOL inFocus = ([firstResponder isKindOfClass:[NSTextView class]]
			   && [[textField window] fieldEditor:NO forObject:nil]!=nil
			   && [textField isEqualTo:(id)((NSTextView *)firstResponder).delegate]
					 );
	
	return inFocus;
}

-(IBAction)findShows:(id)sender {
	if ([self isTextFieldInFocus:self.findText]) {
		[self.window makeFirstResponder:nil];
		[self showFindField:NO];
	} else {
		[self showFindField:YES];
		[self.window makeFirstResponder:self.findText];
	}
}
-(IBAction)changedSearchText:(id)sender {
	if (sender != self.findText) {
		DDLogMajor(@"Error invalid textField %@", sender);
		return;
	}
	DDLogVerbose(@"FindText = %@",self.findText.stringValue);
	[self reloadData];
}

-(void)textDidEndEditing:(NSNotification *) notification {
	if (notification.object != self.findText) {
		DDLogMajor(@"Error invalid textField %@", notification.object);
		return;
	}
	int movementCode = [notification.userInfo[@"NSTextMovement"] intValue];
	DDLogVerbose(@"Ending FindText = %@",self.findText.stringValue);
	if (movementCode == NSCancelTextMovement || [self.findText.stringValue isEqualToString:@""]) {
		[self showFindField:NO];
	}
}

#pragma mark - Table Delegate Protocol

-(IBAction)selectTivo:(id)sender {
    if (tiVoManager.tiVoList.count > 1) { //Nothing to change otherwise
        self.selectedTiVo = ((MTTiVo *)[(NSPopUpButton *)sender selectedItem].representedObject).tiVo.name;
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedTiVo forKey:kMTSelectedTiVo];
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationTiVoListUpdated object:_selectedTiVo];
    }
}

-(NSInteger)numberOfSelectedRows {
    NSIndexSet *currentSelectedRows = [self selectedRowIndexes];
    __block NSInteger numSelected = 0;
    [currentSelectedRows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop){
		id item = [self itemAtRow:row];
		if ([item isKindOfClass:[MTShowFolder class]]) {
			NSArray <MTTiVoShow *> *  shows = ((MTShowFolder *) item).folder;
			for (MTTiVoShow * show in shows) {
				if (![show.protectedShow boolValue]) {
					numSelected++;
				}
			}
		}  else if (![((MTTiVoShow *) item).protectedShow boolValue]) {
            numSelected++;
        }
    }];
    return numSelected;
}

-(NSArray <MTTiVoShow *> *) flattenShows: (NSArray *) shows {
	NSMutableArray *result = [[NSMutableArray alloc] init];
	for (id item in shows) {
		if ([item isKindOfClass:[MTShowFolder class]]) {
			[result addObjectsFromArray:((MTShowFolder *) item).folder];
		} else {
			[result addObject:item];
		}
	}
	return [result copy];
}

-(NSArray <MTTiVoShow *> *) selectedShows {
	NSIndexSet *selectedRowIndexes = [self selectedRowIndexes];
	NSMutableArray <MTTiVoShow *> * result = [NSMutableArray array];
	[selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
		id item = [self itemAtRow:idx];
		if ([item isKindOfClass:[MTShowFolder class]]) {
			[result addObjectsFromArray:((MTShowFolder *) item).folder];
		} else {
			[result addObject:item];
		}
	}];
	return [result copy];
}
  
-(NSArray *)sortedShows {
	if (!_sortedShows) {
		DDLogVerbose(@"Re-sorting Program table");
		NSPredicate *yesPredicate =	[NSPredicate predicateWithValue:YES];

		NSPredicate *protectedPredicate = yesPredicate;
		if ( ! [[[NSUserDefaults standardUserDefaults] objectForKey:kMTShowCopyProtected] boolValue]) {
			protectedPredicate = [NSPredicate predicateWithFormat:@"protectedShow == %@",[NSNumber numberWithBool:NO]];
		}
		
		NSPredicate *suggestedPredicate = yesPredicate;
		if ( ! [[[NSUserDefaults standardUserDefaults] objectForKey:kMTShowSuggestions] boolValue]) {
			suggestedPredicate = [NSPredicate predicateWithFormat:@"isSuggestion == NO"];
		}
		
		NSPredicate *findPredicate = yesPredicate;
		if (self.findText.stringValue.length > 0) {
			findPredicate = [NSPredicate predicateWithFormat:@"showTitle contains[cd] %@",self.findText.stringValue];
		}
		
		NSPredicate *tiVoPredicate = yesPredicate;
		if (self.selectedTiVo && [tiVoManager foundTiVoNamed:self.selectedTiVo] && [self.selectedTiVo compare:kMTAllTiVos] != NSOrderedSame) { //We need a predicate for filtering
			tiVoPredicate = [NSPredicate predicateWithFormat:@"tiVo.tiVo.name == %@",self.selectedTiVo];
		}
		NSArray * whichShows = [[[[tiVoManager.tiVoShows filteredArrayUsingPredicate:tiVoPredicate]
								   filteredArrayUsingPredicate:findPredicate]
								  filteredArrayUsingPredicate:protectedPredicate]
								 filteredArrayUsingPredicate:suggestedPredicate];
		if ([[NSUserDefaults standardUserDefaults] boolForKey:kMTShowFolders]) {
			NSMutableDictionary * showsDict = [NSMutableDictionary new];
			for (MTTiVoShow * show in whichShows) {
				NSMutableArray * series = showsDict[show.seriesTitle];
				if (series) {
					[series addObject:show];
				} else {
					showsDict[show.seriesTitle] = [NSMutableArray arrayWithObject:show];
				}
			}
			NSMutableArray * folderArray = [NSMutableArray new];
			for (NSString * key in showsDict.allKeys ) {
				NSArray * seriesShows = showsDict[key];
				if (seriesShows.count == 1) {
					[folderArray addObject:seriesShows[0]];
				} else {
					MTShowFolder * folderHolder = self.oldFolders[key];
					if (!folderHolder){
						folderHolder = [MTShowFolder new];
						self.oldFolders[key] = folderHolder;
					}
					folderHolder.folder = seriesShows;
					[folderArray addObject:folderHolder];
				}
			}
			self.sortedShows = [folderArray sortedArrayUsingDescriptors:self.sortDescriptors];
		} else {
			NSMutableArray * newArray = [NSMutableArray arrayWithCapacity:whichShows.count];
			for (MTTiVoShow * show in whichShows) {
				[newArray addObject:show];
			}
			self.sortedShows = [newArray sortedArrayUsingDescriptors:self.sortDescriptors];
		}
	}
	return _sortedShows;
}

- (void) refreshAddToQueueButton: (NSNotification *) notification {
	if (tiVoManager.processingPaused.boolValue || [tiVoManager anyShowsWaiting]) {
		self.addToQueueButton.title =@"Add to Queue";
	} else {
		self.addToQueueButton.title = @"Download";
	}
}

-(void)outlineViewSelectionDidChange:(NSNotification *)notification {
	DDLogVerbose(@"selection did change");
	NSInteger numRows = [self numberOfSelectedRows];
	[self.addToQueueButton setEnabled:numRows != 0];
	[self.subscribeButton setEnabled: numRows != 0];
    if (numRows == 1) {
		NSArray *selectedRows = [self selectedShows];
        [self.myController setValue:selectedRows[0] forKey:@"showForDetail"];
    }
}

-(void) outlineViewItemDidExpand:(NSNotification *)notification {
	[self outlineViewItemDidCollapse:notification];
}

-(void) outlineViewItemDidCollapse:(NSNotification *)notification {
	MTShowFolder * folder = (MTShowFolder *) notification.userInfo[@"NSObject"];
	[self noteHeightOfRowsWithIndexesChanged:
	 [NSIndexSet indexSetWithIndex:[self rowForItem:folder]]];
	[self reloadItem:folder];
}

-(void) outlineViewColumnDidResize:(NSNotification *)notification {
	NSTableColumn * column = notification.userInfo[@"NSTableColumn"];
    CGFloat oldWidth = ((NSNumber *)notification.userInfo[@"NSOldWidth"]).floatValue;
    if ([column.identifier isEqualToString:@"icon" ]  ||
         [column.identifier isEqualToString:kMTArtColumn ]  ) {
        DDLogVerbose(@"changed column width for %@ from %0.1f to %0.1f", column.identifier, oldWidth, column.width );
        if (ABS(column.width - oldWidth) < 3.0) return; //patch to prevent height/width looping in High Sierra
        NSIndexSet * allRows = [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(0, self.sortedShows.count) ];
       if ( [column.identifier isEqualToString:kMTArtColumn ] && self.imageRowHeight > 0) {
            self.imageRowHeight = -self.imageRowHeight;  //use as trigger to recalculate, but remember old size in case it hasn't changed.
           [self noteHeightOfRowsWithIndexesChanged: allRows ];
		   [self reloadData];
	   } else {
        	[self reloadDataForRowIndexes: allRows
                            columnIndexes:[NSIndexSet indexSetWithIndex: [[self tableColumns] indexOfObject:column]]];
	   }
    }
}

-(void) outlineViewColumnDidMove:(NSNotification *)notification {
    //called when column added or deleted
	NSTableColumn * column = notification.userInfo[@"NSTableColumn"];
	[self columnChanged:column];
}

-(void) confirmColumns {
	NSTableColumn * oldOutline = self.outlineTableColumn;
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kMTShowFolders] &&
		oldOutline.isHidden) {
		NSTableColumn * combo = [self tableColumnWithIdentifier: @"Programs"];
		NSTableColumn * series = [self tableColumnWithIdentifier: @"Series"];
		NSTableColumn * episode = [self tableColumnWithIdentifier: @"Title"];
		if (oldOutline == combo && !series.isHidden) {
			self.outlineTableColumn = series;
		} else if (oldOutline == series && !combo.isHidden) {
			self.outlineTableColumn = combo;
		} else if (episode.isHidden) {
			combo.hidden = NO;
			self.outlineTableColumn = combo;
		} else {
			series.hidden = NO;
			self.outlineTableColumn = series;
		}
	}
}

-(void) columnChanged: (NSTableColumn *) column {
    if ([column.identifier isEqualToString: kMTArtColumn]) {
        //have to confirm height changed
        if (column.isHidden) {
            //free up memory from images
            for (MTTiVoShow * show in tiVoManager.tiVoShows) {
                show.thumbnailImage = nil;
            }
        }
        if (self.imageRowHeight > 0) {
            self.imageRowHeight = -self.imageRowHeight;  //use as trigger to recalculate, but remember old size in case it hasn't changed.
        } else if (self.imageRowHeight == 0){
            self.imageRowHeight = -1;
        }
        [self reloadData];
	} else {
		[self confirmColumns];
	}
}

#pragma mark - Table Data Source Protocol

-(void)outlineView:(NSOutlineView *)outlineView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
	[self reloadData];
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item {
    //use negative numbers to indicate we need to recalculate, but save old one as negative to see if we need to reload or not.
    //Yes, it's ugly.
    //even worse, sometimes imageColumn.hidden is incorrectly NO the first time after relaunch;
    //and then sometimes hidden correctly changes back to YES but without notifying columndidChange,
    //so we have to add a special observer on the hidden keypath!

    if (self.imageRowHeight < 0) {
        NSTableColumn *imageColumn = [self tableColumnWithIdentifier:kMTArtColumn];
        CGFloat newRowHeight = [super rowHeight];
        if  (!imageColumn.hidden ) {
           newRowHeight =  MAX(newRowHeight, 9.0/16.0*imageColumn.width);
        }
        DDLogVerbose(@"rowHeight calculation: %0.1f => %0.1f .", -self.imageRowHeight, newRowHeight);
        if (newRowHeight != -self.imageRowHeight) {
            //now preserve the current first row.
            CGPoint scroll = self.enclosingScrollView.contentView.bounds.origin;
            NSInteger spacing = [self intercellSpacing].height;
            scroll.y = scroll.y/(-self.imageRowHeight+spacing) * (newRowHeight+spacing);
            [self scrollPoint:scroll];
        }
        self.imageRowHeight = newRowHeight;
    }
//	if ([self isItemExpanded:item]) return [super rowHeight];
	return self.imageRowHeight;
}

-(void) outlineView:(NSOutlineView *)outlineView didAddRowView:(nonnull NSTableRowView *)rowView forRow:(NSInteger)row {
	id item = [self itemAtRow:row];
	MTTiVoShow * thisShow = nil;
	if ([item isKindOfClass:[MTShowFolder class]]) {
		thisShow = ((MTShowFolder *) item).folder[0];
	} else {
		thisShow = item;
	}
	if ([thisShow.protectedShow boolValue]) {
        rowView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    } else {
        rowView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    }
}

-(NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
	if (item) {
		if ([item isKindOfClass:[MTShowFolder class]]) {
			NSArray <MTTiVoShow *> *  shows = ((MTShowFolder *) item).folder;
			return shows.count;
		} else {
			return 0;
		}
	} else {
		return self.sortedShows.count;
	}
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id) item {
	if (item) {
		if ([item isKindOfClass:[MTShowFolder class]]) {
			NSArray <MTTiVoShow *> *  shows = ((MTShowFolder *) item).folder;
			return  shows[(NSUInteger)index < shows.count ? index : shows.count-1];;
		} else {
			return item;
		}
	} else {
		return self.sortedShows[index];
	}
}

-(BOOL) outlineView:(NSOutlineView *) outlineView isItemExpandable:(nonnull id)item {
	if ([item isKindOfClass:[MTShowFolder class]]) {
		return YES;
	} else {
		return NO;
	}
}
-(NSString *) textForShow:(MTTiVoShow *) thisShow atColumn: (NSTableColumn *) column {
	NSString * identifier = column.identifier;
	if ([identifier isEqualToString:@"Programs"]) {
		return thisShow.showTitle?: @"" ;
	} else if ([identifier isEqualToString:@"TiVo"]) {
		return thisShow.tiVoName?: @"";
	} else if ([identifier isEqualToString:@"Date"]) {
		if ([column width] > 135) {
			return thisShow.showMediumDateString?: @"";
		} else {
			return thisShow.showDateString?: @"";
		}
	} else if ([identifier isEqualToString:@"Length"]) {
		return thisShow.lengthString?: @"";
	} else if ([identifier isEqualToString:@"Series"]) {
		return thisShow.seriesTitle?: @"";
	} else if ([identifier isEqualToString:@"Episode"]) {
		return thisShow.seasonEpisode?: @"";
	} else if ([identifier isEqualToString:@"Queued"]) {
		return thisShow.isQueuedString?: @"";
	} else if ([identifier isEqualToString:@"OnDisk"]) {
		return thisShow.isOnDiskString?: @"";
	} else if ([identifier isEqualToString:@"HD"]) {
		return thisShow.isHDString?: @"";
	} else if ([identifier isEqualToString:@"Folder"]) {
		return @""; //shows aren't folders
	} else if ([identifier isEqualToString:@"Channel"]) {
		return thisShow.channelString?: @"";
	} else if ([identifier isEqualToString:@"Size"]) {
		return thisShow.sizeString?: @"";
	} else if ([identifier isEqualToString:@"TiVoID"]) {
		return thisShow.idString?: @"";
	} else if ([identifier isEqualToString:@"EpisodeID"]) {
		return thisShow.episodeID?: @"";
	} else if ([identifier isEqualToString:@"Title"]) {
		return thisShow.episodeTitle?: @"";
	} else if ([identifier isEqualToString:@"Station"]) {
		return thisShow.stationCallsign?: @"";
	} else if ([identifier isEqualToString:@"Genre"]) {
		return thisShow.episodeGenre?: @"";
	} else if ([identifier isEqualToString:@"AgeRating"]) {
		return thisShow.ageRatingString?: @"";
	} else if ([identifier isEqualToString:@"StarRating"]) {
		return thisShow.starRatingString?: @"";
	} else if ([identifier isEqualToString:@"FirstAirDate"]) {
		return thisShow.originalAirDateNoTime?: @"";
	} else if ([identifier isEqualToString:@"H.264"]) {
		return thisShow.h264String?: @"";
	} else {
		DDLogReport(@"Invalid Column: %@", identifier);
		return @"";
	}
}

-(MTProgressCell *) configureArtCell: (MTProgressCell *) cell forShow: (MTTiVoShow *) thisShow withWidth:(CGFloat) width {
	DragDropImageView * imageView = (DragDropImageView *) cell.imageView;
	imageView.delegate = thisShow; //drag drop support
	CGRect rect = CGRectMake(0, 0, width, fabs(self.imageRowHeight));
	cell.frame = rect;
	cell.imageView.frame = rect;
	cell.progressIndicator.frame = rect;
	NSImage * image = thisShow.thumbnailImage;
	if (image) {
		DDLogVerbose(@"got image for %@: %@",thisShow, NSStringFromRect(cell.bounds));
		imageView.image = image ;
		imageView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin| NSViewMinYMargin |NSViewMaxYMargin;
		imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
		cell.progressIndicator.hidden = YES;
		[cell.progressIndicator stopAnimation:self];
	} else if (thisShow.noImageAvailable) {
		//no image, and it's never coming
		DDLogVerbose(@"No image for %@",thisShow);
		imageView.image = nil ;
		cell.progressIndicator.hidden = YES;
		[cell.progressIndicator stopAnimation:self];
	} else {
		//no image, but it may be coming
		DDLogVerbose(@"Waiting for image for %@",thisShow);
		imageView.image = nil ;
		cell.progressIndicator.hidden = NO;
		[cell.progressIndicator startAnimation:self];
	}
	return cell;
}

-(NSTableCellView *) configureIconCell: (NSTableCellView *) cell forShow: (MTTiVoShow *) thisShow withWidth:(CGFloat) width {
	NSImageView * imageView = cell.imageView;
	NSString * imageName = thisShow.imageString;
	imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
	imageView.image = [NSImage imageNamed: imageName];
	CGFloat height = MIN(width, MIN(self.imageRowHeight, 24));
	CGFloat leftMargin = (width -height)/2;
	CGFloat topMargin = (self.imageRowHeight-height)/2;
	imageView.frame = CGRectMake(leftMargin, topMargin, height, height);
	imageView.animates = YES;
	cell.toolTip = [[imageName stringByReplacingOccurrencesOfString:@"-" withString:@" "] capitalizedString];
	return cell;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    // get an existing cell with the MyView identifier if it exists
    NSTableCellView *result = [outlineView makeViewWithIdentifier:tableColumn.identifier owner:self];
	
	NSString* identifier = tableColumn.identifier;
	CGFloat rowHeight = ABS(self.imageRowHeight);
//	if ([self isItemExpanded:item]) {
//		rowHeight = [super rowHeight];
//	}
	result.frame =CGRectMake(0,0, tableColumn.width, rowHeight);

    NSString * textVal = nil;
    result.toolTip = @"";
	MTTiVoShow *thisShow = nil;
	result.imageView.image = nil ;

	if ([identifier isEqualToString: kMTArtColumn]) {
		MTProgressCell * cell = (MTProgressCell *) result;
		if ([item isKindOfClass:[MTShowFolder class]]) {
			if ([self isItemExpanded:item]) {
				cell.progressIndicator.hidden = YES;
				[cell.progressIndicator stopAnimation:self];
				return cell;
			} else {
				thisShow = ((MTShowFolder *) item).folder[0];
			}
		} else {
			thisShow = (MTTiVoShow *) item;
		}
		return [self configureArtCell: cell forShow: thisShow withWidth: tableColumn.width];
	} else if ( [identifier isEqualToString: @"icon"])  {
		if ([item isKindOfClass:[MTShowFolder class]]) {
			if ( [self isItemExpanded:item]) {
				return result; //no icon when expanded
			} else {
				NSString * commonName =  nil;
				MTShowFolder * folderHolder = item;
				for (MTTiVoShow * show in folderHolder.folder) {
					NSString * imageName = show.imageString;
					if (!commonName) {
						commonName = imageName ; //remember first one
					} else if (!imageName || ![imageName isEqualToString:commonName]){
						//not all the show are the same.
						commonName = nil;
						break;
					}
				}
				if (commonName) {
					return [self configureIconCell: result forShow: folderHolder.folder[0] withWidth: tableColumn.width];
				} else {
					return result;
				}
			}
		} else {
			return [self configureIconCell: result forShow: (MTTiVoShow *) item withWidth: tableColumn.width];
		}
	}
	
	//Otherwise text box
	if ([item isKindOfClass:[MTShowFolder class]]) {
		//do any special handling here for folders
		//if generic text result, set textVal (e.g. cumulative folder size)
		//else if relying on a subshow for content, set thisShow
		//else return
		MTShowFolder * folderHolder = (MTShowFolder *) item;
		if (tableColumn == [self outlineTableColumn]) {
			textVal = [NSString stringWithFormat:@"%@ (%d)", folderHolder.folder[0].seriesTitle, (int)folderHolder.folder.count];
		} else if ([identifier isEqualToString:@"Folder"]) {
			textVal = @"✔"; //we know this is a folder
		} else if ([self isItemExpanded:item]) {
			//for most fields, don't show when expanded
			textVal = @"";
		} else if ([identifier isEqualToString:@"Size"]) {
			textVal = folderHolder.sizeString;   //cumulative
		} else if ([identifier isEqualToString:@"Length"]) {
			textVal = folderHolder.lengthString;  //cumulative
		} else if ([identifier isEqualToString:@"Programs"] ||
				   [identifier isEqualToString:@"Series"] ||
				   [identifier isEqualToString:@"Date"]) {
			//for date, always show latest
			thisShow = folderHolder.folder[0];
		} else {
			//check if all the same, if so, display common else "various"
			NSString * commonString =  nil;
			for (MTTiVoShow * show in folderHolder.folder) {
				NSString * showText = [self textForShow:show atColumn:tableColumn] ?: @"";
				if (!commonString) {
					commonString = showText ; //remember first one
				} else if (![commonString isEqualToString:showText]){
					//not all the show are the same.
					commonString = nil;
					break;
				}
			}
			textVal = commonString ?: @"~~";
		}
	} else {
		thisShow = (MTTiVoShow *) item;
	}
	if (!textVal) textVal = [self textForShow:thisShow atColumn:tableColumn];

	if ([identifier isEqualToString:@"Programs" ] ||
		[identifier isEqualToString:@"TiVo"     ] ||
		[identifier isEqualToString:@"Date"     ] ||
		[identifier isEqualToString:@"Length"   ] ||
		[identifier isEqualToString:@"Series"   ] ||
		[identifier isEqualToString:@"Episode"  ] ||
		[identifier isEqualToString:@"Title"    ] ||
		[identifier isEqualToString:@"Genre"    ] ||
		[identifier isEqualToString:@"AgeRating"]) {
		result.toolTip = textVal;
	}

	if ([identifier isEqualToString:@"HD"]) {
		result.textField.alignment = NSCenterTextAlignment;
	} else if ([identifier isEqualToString:@"H.264"]) {
		result.textField.alignment = NSCenterTextAlignment;
		result.toolTip =@"Does this channel use H.264 compression?";
	} else if ([identifier isEqualToString:@"OnDisk"]) {
		result.toolTip =@"Is program already downloaded and still on disk?";
	}

	if ([thisShow isOnDisk]){
		result.textField.font = [[NSFontManager sharedFontManager] convertFont:result.textField.font toHaveTrait:NSFontBoldTrait];
	} else {
		result.textField.font = [[NSFontManager sharedFontManager] convertFont:result.textField.font toNotHaveTrait:NSFontBoldTrait];
	}
	
	result.textField.textColor = [NSColor blackColor];
	if ([thisShow.protectedShow boolValue]) {
		result.textField.textColor = [NSColor grayColor];
	} else if (thisShow && [identifier isEqualToString:@"TiVo"] && !thisShow.tiVo.isReachable) {
		result.textField.textColor = [NSColor redColor];
	}
	
	//make sure textfield is properly centered
	result.textField.stringValue = textVal ?: @"";
	CGFloat textSize = MIN(result.textField.font.pointSize + 4, rowHeight);
	result.textField.frame = CGRectMake(0, round((rowHeight-textSize)/2), tableColumn.width, textSize );
	result.textField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
	result.textField.translatesAutoresizingMaskIntoConstraints = YES;
	
    return result;
}
#pragma mark Drag N Drop support

/*// What kind of drag operation should I perform?
- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id )info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
    return op == NSTableViewDropOn ? NSDragOperationCopy : NSDragOperationNone; // Specifies that the drop should occur on the specified row.
}

// The mouse button was released over a row in the table view, should I accept the drop?
- (BOOL)tableView:(NSTableView *) tv acceptDrop:(id )info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
    MTTiVoShow * show = self.sortedShows[row];
    NSLog(@"Dragged Show: %@", show);
    return YES;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    if ([[[sender draggingPasteboard] types] containsObject:NSFilenamesPboardType]) {
        return NSDragOperationCopy;
    }
    
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
    NSPasteboard *pboard;
    pboard = [sender draggingPasteboard];
    NSPoint windowDropPoint = [sender draggingLocation];
    NSPoint tableDropPoint = [self convertPoint:windowDropPoint fromView:nil];
    NSUInteger row = [self rowAtPoint:tableDropPoint];
    if (row >= self.sortedShows.count) return NO;
    MTTiVoShow * show = self.sortedShows[row];
    NSImage * image = [[NSImage alloc] initWithPasteboard:pboard];
    if (image) {
        [show setArtworkFromImage: image];
        return YES;
    } else {
        return NO;
    }
}
*/

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    switch(context) {
        case NSDraggingContextOutsideApplication:
            return NSDragOperationCopy;  //could theoretically allow, as completed shows are also here.
            break;
			
        case NSDraggingContextWithinApplication:
        default:
            return NSDragOperationGeneric | NSDragOperationCopy |NSDragOperationLink;
            break;
	}
}

-(void) mouseDown:(NSEvent *)event {
    //pass drag drop to ArtColumn if present
    NSPoint p = [self convertPoint: event.locationInWindow fromView:nil];
    NSInteger c = [self columnAtPoint:p];
    NSInteger r = [self rowAtPoint:p];
    if (c >= 0 && r >= 0 && [self.tableColumns[c].identifier isEqualToString:kMTArtColumn]){
        NSTableCellView *showCellView = [self viewAtColumn:c row:r makeIfNecessary:NO];
        [showCellView.imageView mouseDown:event];
    } else {
        [super mouseDown:event];
    }

}

-(NSDragOperation) draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

-(BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pboard {
	
	if (![[NSUserDefaults standardUserDefaults]boolForKey:kMTDisableDragSelect] ) {
        //if user wants drag-to-select, then check if we're selecting new rows or not
        //drag/drop if current row is  already selected OR we're over name of show
        //this is parallel to Finder behavior.
		NSPoint windowPoint = [self.window mouseLocationOutsideOfEventStream];
		NSPoint p = [outlineView convertPoint:windowPoint fromView:nil];
		NSInteger r = [outlineView rowAtPoint:p];
		NSInteger c = [outlineView columnAtPoint:p];
		if (c >= 0 && r >=0 ) {
            BOOL isSelectedRow = [outlineView isRowSelected:r];
            BOOL isOverText = NO;
            NSTableCellView *showCellView = [outlineView viewAtColumn:c row:r makeIfNecessary:NO];
            NSTextAlignment alignment = showCellView.textField.alignment;
            NSTextField *showField = showCellView.textField;
            if (showField) {
                NSPoint clickInText = [showField convertPoint:windowPoint fromView:nil];
                NSSize stringSize = [showField.stringValue sizeWithAttributes:@{NSFontAttributeName : showField.font}];
                NSSize cellSize = showCellView.frame.size;
                switch (alignment) {
                    case NSLeftTextAlignment:
                    case NSNaturalTextAlignment:
                        if (clickInText.x < stringSize.width) {
                            isOverText = YES;
                        }
                        break;
                    case NSRightTextAlignment:
                        if (clickInText.x > cellSize.width - stringSize.width) {
                            isOverText = YES;
                        }
                        break;
                    case NSCenterTextAlignment:
                        if (clickInText.x < (cellSize.width + stringSize.width)/2.0 && clickInText.x > (cellSize.width - stringSize.width)/2.0) {
                            isOverText = YES;
                        }
                        break;
                    default:
                        break;
                }
            }
            if (!isSelectedRow && !isOverText) {
                return NO;
            }
        }
	}
	// Drag and drop support
	NSArray	*selectedObjects = [self flattenShows:items]; ;
	DDLogVerbose(@"Dragging Objects: %@", selectedObjects);
	[pboard writeObjects:selectedObjects];
   return (selectedObjects.count > 0);
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem{
    if ([menuItem action]==@selector(copy:)) {
        return (self.numberOfSelectedRows >0);
    }
    BOOL deleteItem = [menuItem action]==@selector(delete:);
    BOOL stopItem =   [menuItem action]==@selector(stopRecording:);
    if (deleteItem || stopItem ) {
        if (deleteItem) menuItem.title = @"Delete from TiVo"; //alternates with remove from Queue
        NSArray	*selectedShows = [self selectedShows ];
        for (MTTiVoShow * show in selectedShows) {
            if (show.rpcData && show.tiVo.rpcActive) {
                if (stopItem) {
                    if (show.inProgress.boolValue) return YES;
                } else {
                    return YES;
                }
            }
        }
        return NO;
    }
    return YES;
}

-(BOOL)playVideo {
	for (MTTiVoShow *show in self.selectedShows) {
		if (show.isOnDisk) {
			[show playVideo:[show copiesOnDisk][0]];
			return YES;
		}
	}
	return NO;
}

-(BOOL)revealInFinder {
	NSMutableArray <NSURL *> * showURLs = [NSMutableArray array];
	for (MTTiVoShow *show in self.selectedShows) {
		if (show.isOnDisk) {
			for (NSString * path in show.copiesOnDisk) {
				[showURLs addObject:[NSURL fileURLWithPath:path]];
			}
		}
	}
	if (showURLs.count > 0) {
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:showURLs];
		return YES;
	} else{
		return NO;
	}
}

-(BOOL)selectionContainsCompletedShows {
	for (MTTiVoShow * show in self.selectedShows) {
		if (show.isOnDisk) return YES;
	}
	return NO;
}


-(IBAction)copy: (id) sender {

    NSArray	*selectedShows = [self selectedShows ];

    if (selectedShows.count > 0) {
        MTTiVoShow * firstShow = selectedShows[0];

        NSPasteboard * pboard = [NSPasteboard generalPasteboard];
        [pboard declareTypes:[firstShow writableTypesForPasteboard:pboard] owner:nil];
        [[NSPasteboard generalPasteboard] writeObjects:selectedShows];
   }
}

-(BOOL) confirmBehavior: (NSString *) behavior preposition:(NSString *) prep forShows:(NSArray <MTTiVoShow *> *) shows {
    NSString * msg = nil;
    if (shows.count == 1) {
        msg = [NSString stringWithFormat:@"Are you sure you want to %@ '%@' %@ TiVo %@?", behavior, shows[0].showTitle, prep, shows[0].tiVoName ];
    } else if (shows.count == 2) {
        msg = [NSString stringWithFormat:@"Are you sure you want to %@ '%@' and '%@' %@ your TiVo?",behavior, shows[0].showTitle, shows[1].showTitle, prep ];
    } else {
        msg = [NSString stringWithFormat:@"Are you sure you want to %@ '%@' and %d others %@ your TiVo?", behavior, shows[0].showTitle, (int)shows.count -1, prep ];
    }

    NSAlert *myAlert = [NSAlert alertWithMessageText:msg defaultButton:@"No" alternateButton:@"Yes" otherButton:nil informativeTextWithFormat:@"This cannot be undone."];
    myAlert.alertStyle = NSCriticalAlertStyle;
    NSInteger result = [myAlert runModal];
    return (result == NSAlertAlternateReturn);
}

-(IBAction)delete:(id)sender {
    NSArray	<MTTiVoShow *> *selectedShows = [self selectedShows ];
	if (selectedShows.count > 0)
		if ([self confirmBehavior:@"delete" preposition: @"from" forShows:selectedShows]) {
			[tiVoManager deleteTivoShows:selectedShows];
		}
}

-(IBAction)stopRecording:(id)sender {
	NSArray	<MTTiVoShow *> *selectedShows = [self selectedShows ];
	if (selectedShows.count > 0)
    	if ([self confirmBehavior:@"stop recording" preposition:@"on" forShows:selectedShows]) {
        	[tiVoManager stopRecordingShows:selectedShows];
    	}
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[self tableColumnWithIdentifier:kMTArtColumn] removeObserver:self forKeyPath:@"hidden" ];
	[[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kMTShowCopyProtected ];
	[[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kMTShowSuggestions ];
}


@end
