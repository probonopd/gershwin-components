/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TOCPanelController.h"

@interface TOCPanelController ()
@property (nonatomic, strong) NSDrawer *drawer;
@property (nonatomic, strong) NSOutlineView *outline;
@end

@implementation TOCPanelController

- (NSDrawer *)ensureDrawer
{
  if (_drawer) return _drawer;
  NSRect r = NSMakeRect(0, 0, 280, 420);
  _drawer = [[NSDrawer alloc] initWithContentSize:r.size preferredEdge:NSMinXEdge];
  NSView *cv = [[NSView alloc] initWithFrame:r];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, r.size.width - 16, r.size.height - 16)];
  [sv setHasVerticalScroller:YES];
  [sv setBorderType:NSBezelBorder];
  _outline = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, r.size.width - 32, r.size.height - 32)];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"title"];
  [col setWidth:r.size.width - 40];
  [_outline addTableColumn:col];
  [_outline setOutlineTableColumn:col];
  [_outline setDataSource:self];
  [_outline setDelegate:self];
  [sv setDocumentView:_outline];
  [cv addSubview:sv];
  [_drawer setContentView:cv];
  return _drawer;
}

- (BOOL)isVisible
{
  return (_drawer != nil && [_drawer state] == NSDrawerOpenState);
}

- (void)toggleWithTOC:(NSArray<EPUBTOCEntry *> *)toc relativeToView:(NSView *)view
{
  if ([self isVisible])
    [self hide];
  else
    [self showWithTOC:toc relativeToView:view];
}

- (void)showWithTOC:(NSArray<EPUBTOCEntry *> *)toc relativeToView:(NSView *)view
{
  self.toc = toc;
  [self ensureDrawer];
  NSWindow *host = [view window];
  if (host != nil)
    [_drawer setParentWindow:host];
  [_outline reloadData];
  [_outline expandItem:nil expandChildren:YES];
  [_drawer open];
}

- (void)hide
{
  [_drawer close];
}

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{
  if (item == nil) return (NSInteger)[self.toc count];
  if ([item isKindOfClass:[EPUBTOCEntry class]])
    return (NSInteger)[(EPUBTOCEntry *)item children].count;
  return 0;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item
{
  if (item == nil) return self.toc[index];
  return [(EPUBTOCEntry *)item children][index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{
  return [self outlineView:ov numberOfChildrenOfItem:item] > 0;
}

- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item
{
  if ([item isKindOfClass:[EPUBTOCEntry class]])
    return [(EPUBTOCEntry *)item title];
  return @"";
}

- (void)outlineViewSelectionDidChange:(NSNotification *)note
{
  id item = [_outline itemAtRow:[_outline selectedRow]];
  if ([item isKindOfClass:[EPUBTOCEntry class]] && _delegate &&
      [_delegate respondsToSelector:@selector(tocDidSelectEntry:)])
    [_delegate tocDidSelectEntry:item];
}

@end
