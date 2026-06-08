/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "NetworkBrowser.h"

@implementation NetworkBrowser

- (id)init
{
  self = [super init];
  if (self)
    {
      types = [[NSMutableArray alloc] init];
      services = [[NSMutableArray alloc] init];
      typeBrowser = nil;
      serviceBrowser = nil;
    }
  return self;
}

- (void)dealloc
{
  if (typeBrowser)
    {
      [typeBrowser stop];
      RELEASE(typeBrowser);
    }
  if (serviceBrowser)
    {
      [serviceBrowser stop];
      RELEASE(serviceBrowser);
    }
  RELEASE(types);
  RELEASE(services);
  RELEASE(window);
  [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  /* Create menus */
  [self createMenu];
  
  /* Check if mDNS-SD support is available */
  Class netServiceBrowserClass = NSClassFromString(@"NSNetServiceBrowser");
  if (!netServiceBrowserClass)
    {
      NSAlert *alert = [[NSAlert alloc] init];
      [alert setAlertStyle: NSWarningAlertStyle];
      [alert setMessageText: @"mDNS-SD Support Not Available"];
      [alert setInformativeText: 
        @"This GNUstep installation was not built with mDNS-SD (DNS-SD) support. "
        @"Network service discovery will not work.\n\n"
        @"To enable this feature, you need to:\n"
        @"1. Install libdns_sd development files (libavahi-compat-libdnssd-dev on Debian)\n"
        @"2. Rebuild GNUstep with DNS-SD support\n\n"
        @"The application will continue but service discovery is unavailable."];
      [alert addButtonWithTitle: @"Continue"];
      [alert addButtonWithTitle: @"Quit"];
      
      NSInteger result = [alert runModal];
      [alert release];
      
      if (result != NSAlertFirstButtonReturn)
        {
          [NSApp terminate: nil];
          return;
        }
    }

  /* Create main window */
  NSRect windowFrame = NSMakeRect(100, 100, 1000, 600);
  window = [[NSWindow alloc]
    initWithContentRect: windowFrame
    styleMask: (NSTitledWindowMask | NSClosableWindowMask |
                NSMiniaturizableWindowMask | NSResizableWindowMask)
    backing: NSBackingStoreBuffered
    defer: NO];

  [window setTitle: @"Network Browser"];
  [window setMinSize: NSMakeSize(800, 400)];
  [window setDelegate: self];

  /* Create main content view */
  NSView *contentView = [window contentView];
  NSRect contentRect = [contentView bounds];

  /* Left pane: Service Types */
  NSRect leftRect = NSMakeRect(0, 0, 250, contentRect.size.height);
  NSScrollView *typesScroll = [[NSScrollView alloc] initWithFrame: leftRect];
  [typesScroll setAutoresizingMask: NSViewHeightSizable | NSViewMaxXMargin];
  [typesScroll setHasVerticalScroller: YES];
  [typesScroll setHasHorizontalScroller: NO];

  typesTable = [[NSTableView alloc] initWithFrame: NSZeroRect];
  [typesTable setDataSource: self];
  [typesTable setDelegate: self];
  [typesTable setAllowsEmptySelection: YES];
  [typesTable setAllowsMultipleSelection: NO];

  NSTableColumn *typesCol = [[NSTableColumn alloc] initWithIdentifier: @"type"];
  [[typesCol headerCell] setStringValue: @"Service Types"];
  [typesCol setWidth: 250 - 20];
  [typesTable addTableColumn: typesCol];
  RELEASE(typesCol);

  [typesScroll setDocumentView: typesTable];
  [contentView addSubview: typesScroll];
  RELEASE(typesScroll);

  /* Middle pane: Services */
  NSRect midRect = NSMakeRect(250, 0, 300, contentRect.size.height);
  NSScrollView *servicesScroll = [[NSScrollView alloc] initWithFrame: midRect];
  [servicesScroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [servicesScroll setHasVerticalScroller: YES];
  [servicesScroll setHasHorizontalScroller: NO];

  servicesTable = [[NSTableView alloc] initWithFrame: NSZeroRect];
  [servicesTable setDataSource: self];
  [servicesTable setDelegate: self];
  [servicesTable setAllowsEmptySelection: YES];
  [servicesTable setAllowsMultipleSelection: NO];

  NSTableColumn *servicesCol = [[NSTableColumn alloc] initWithIdentifier: @"service"];
  [[servicesCol headerCell] setStringValue: @"Services"];
  [servicesCol setWidth: 300 - 20];
  [servicesTable addTableColumn: servicesCol];
  RELEASE(servicesCol);

  [servicesScroll setDocumentView: servicesTable];
  [contentView addSubview: servicesScroll];
  RELEASE(servicesScroll);

  /* Right pane: Details */
  NSRect rightRect = NSMakeRect(550, 0, contentRect.size.width - 550, contentRect.size.height);
  NSScrollView *detailsScroll = [[NSScrollView alloc] initWithFrame: rightRect];
  [detailsScroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [detailsScroll setHasVerticalScroller: YES];
  [detailsScroll setHasHorizontalScroller: NO];

  NSRect detailsFrame = NSMakeRect(0, 0,
    [detailsScroll contentSize].width,
    [detailsScroll contentSize].height);
  detailsText = [[NSTextView alloc] initWithFrame: detailsFrame];
  [detailsText setEditable: NO];
  [detailsText setSelectable: YES];
  [detailsText setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];

  [detailsScroll setDocumentView: detailsText];
  [contentView addSubview: detailsScroll];
  RELEASE(detailsScroll);

  [window makeKeyAndOrderFront: nil];

  /* Start browsing for service types */
  typeBrowser = [[NSNetServiceBrowser alloc] init];
  [typeBrowser setDelegate: self];
  [typeBrowser searchForServicesOfType: @"_services._dns-sd._udp"
                               inDomain: @"local"];
}

/* NSTableViewDataSource methods */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  if (tableView == typesTable)
    return [types count];
  else if (tableView == servicesTable)
    return [services count];
  return 0;
}

- (id)tableView:(NSTableView *)tableView
  objectValueForTableColumn:(NSTableColumn *)tableColumn
  row:(NSInteger)row
{
  if (tableView == typesTable && row >= 0 && row < (NSInteger)[types count])
    {
      NSNetService *type = [types objectAtIndex: row];
      return [type name];
    }
  else if (tableView == servicesTable && row >= 0 && row < (NSInteger)[services count])
    {
      NSNetService *service = [services objectAtIndex: row];
      return [service name];
    }
  return nil;
}

/* NSTableViewDelegate methods */

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
  NSTableView *table = [aNotification object];

  if (table == typesTable)
    {
      NSInteger selectedRow = [typesTable selectedRow];
      [services removeAllObjects];
      [servicesTable reloadData];
      [detailsText setString: @""];

      if (selectedRow >= 0 && selectedRow < (NSInteger)[types count])
        {
          NSNetService *typeService = [types objectAtIndex: selectedRow];
          NSString *typeName = [typeService name];

          NSDebugLLog(@"gwcomp", @"Selected type row %ld: %@", selectedRow, typeName);

          if (serviceBrowser)
            {
              [serviceBrowser stop];
              RELEASE(serviceBrowser);
            }

          NSString *searchType = [NSString stringWithFormat: @"%@._tcp", typeName];
          NSDebugLLog(@"gwcomp", @"Starting search for type: %@", searchType);

          serviceBrowser = [[NSNetServiceBrowser alloc] init];
          [serviceBrowser setDelegate: self];
          [serviceBrowser searchForServicesOfType: searchType inDomain: @"local"];
        }
    }
  else if (table == servicesTable)
    {
      [self updateDetailsForSelectedService];
    }
}

/**
 * Build and display details for the currently selected service.
 * Called on selection change and when a service finishes resolving.
 */
- (void)updateDetailsForSelectedService
{
  NSInteger selectedRow = [servicesTable selectedRow];
  NSMutableString *details = [[NSMutableString alloc] init];

  if (selectedRow >= 0 && selectedRow < (NSInteger)[services count])
    {
      NSNetService *service = [services objectAtIndex: selectedRow];
      [details appendFormat: @"Name: %@\n", [service name]];
      [details appendFormat: @"Type: %@\n", [service type]];
      [details appendFormat: @"Domain: %@\n", [service domain]];

      int port = [service port];
      if (port > 0)
        [details appendFormat: @"Port: %d\n", port];
      else
        [details appendString: @"Port: (resolving...)\n"];

      NSString *host = [service hostName];
      if (host)
        [details appendFormat: @"Host: %@\n", host];
      else
        [details appendString: @"Host: (resolving...)\n"];

      NSArray *addresses = [service addresses];
      if ([addresses count] > 0)
        {
          [details appendString: @"Addresses:\n"];
          for (NSData *addr in addresses)
            {
              struct sockaddr *sa = (struct sockaddr *)[addr bytes];
              char addrStr[INET6_ADDRSTRLEN];
              if (sa->sa_family == AF_INET)
                {
                  struct sockaddr_in *sin = (struct sockaddr_in *)sa;
                  inet_ntop(AF_INET, &sin->sin_addr, addrStr, INET6_ADDRSTRLEN);
                  [details appendFormat: @"  %s\n", addrStr];
                }
              else if (sa->sa_family == AF_INET6)
                {
                  struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)sa;
                  inet_ntop(AF_INET6, &sin6->sin6_addr, addrStr, INET6_ADDRSTRLEN);
                  [details appendFormat: @"  [%s]\n", addrStr];
                }
              else
                {
                  [details appendFormat: @"  %@\n", addr];
                }
            }
        }

      /* Display TXT records */
      NSData *txtData = [service TXTRecordData];
      if (txtData)
        {
          NSDictionary *txtDict = [NSNetService dictionaryFromTXTRecordData: txtData];
          if (txtDict && [txtDict count] > 0)
            {
              [details appendString: @"\nTXT Records:\n"];
              for (NSString *key in [txtDict allKeys])
                {
                  NSData *valueData = [txtDict objectForKey: key];
                  NSString *valueStr = [[NSString alloc] initWithData: valueData
                                                             encoding: NSUTF8StringEncoding];
                  if (valueStr == nil)
                    {
                      valueStr = [[NSString alloc] initWithFormat: @"<binary: %lu bytes>",
                                           (unsigned long)[valueData length]];
                    }
                  [details appendFormat: @"  %@: %@\n", key, valueStr];
                  RELEASE(valueStr);
                }
            }
        }
    }
  else
    {
      [details appendString: @"(No service selected)"];
    }

  [detailsText setString: details];
  RELEASE(details);
}

/* NSNetServiceDelegate methods */

- (void)netServiceDidResolveAddress:(NSNetService *)sender
{
  NSDebugLLog(@"gwcomp", @"Service resolved: %@", [sender name]);

  /* Refresh details if this is the currently selected service */
  NSInteger selectedRow = [servicesTable selectedRow];
  if (selectedRow >= 0 && selectedRow < (NSInteger)[services count])
    {
      NSNetService *selected = [services objectAtIndex: selectedRow];
      if ([selected isEqual: sender])
        {
          [self updateDetailsForSelectedService];
        }
    }
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict
{
  NSDebugLLog(@"gwcomp", @"Service did not resolve: %@ - %@",
        [sender name], errorDict);
}

/* NSNetServiceBrowserDelegate methods */

- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser *)aNetServiceBrowser
{
  NSDebugLLog(@"gwcomp", @"Starting to search for network services...");
}

- (void)netServiceBrowserDidStopSearch:(NSNetServiceBrowser *)aNetServiceBrowser
{
  NSDebugLLog(@"gwcomp", @"Stopped searching for network services");
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser
           didFindService:(NSNetService *)aNetService
               moreComing:(BOOL)moreComing
{
  if (aNetServiceBrowser == typeBrowser)
    {
      NSDebugLLog(@"gwcomp", @"Found service type: %@", [aNetService name]);
      for (NSNetService *existing in types)
        {
          if ([[existing name] isEqual: [aNetService name]])
            return;
        }
      [types addObject: aNetService];
      [typesTable reloadData];
    }
  else if (aNetServiceBrowser == serviceBrowser)
    {
      NSDebugLLog(@"gwcomp", @"Found service: %@", [aNetService name]);
      [aNetService setDelegate: self];
      [aNetService resolveWithTimeout: 5.0];
      for (NSNetService *existing in services)
        {
          if ([[existing name] isEqual: [aNetService name]])
            return;
        }
      [services addObject: aNetService];
      [servicesTable reloadData];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser
         didRemoveService:(NSNetService *)aNetService
               moreComing:(BOOL)moreComing
{
  if (aNetServiceBrowser == typeBrowser)
    {
      NSDebugLLog(@"gwcomp", @"Service type removed: %@", [aNetService name]);
      for (NSNetService *existing in [NSArray arrayWithArray: types])
        {
          if ([[existing name] isEqual: [aNetService name]])
            {
              [types removeObject: existing];
            }
        }
      [typesTable reloadData];
    }
  else if (aNetServiceBrowser == serviceBrowser)
    {
      NSDebugLLog(@"gwcomp", @"Service removed: %@", [aNetService name]);
      for (NSNetService *existing in [NSArray arrayWithArray: services])
        {
          if ([[existing name] isEqual: [aNetService name]])
            {
              [services removeObject: existing];
            }
        }
      [servicesTable reloadData];
      [detailsText setString: @""];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser
  didNotSearch:(NSDictionary *)errorDict
{
  NSDebugLLog(@"gwcomp", @"Error searching for services: %@", errorDict);
}

- (void)createMenu
{
  NSMenu *mainMenu = [[NSMenu alloc] init];
  
  /* Application menu */
  NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"NetworkBrowser" action:NULL keyEquivalent:@""];
  [mainMenu addItem:appMenuItem];
  
  NSMenu *appMenu = [[NSMenu alloc] init];
  [appMenuItem setSubmenu:appMenu];
  
  [appMenu addItemWithTitle:@"About Network Browser" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Network Browser" action:@selector(terminate:) keyEquivalent:@"q"];
  
  RELEASE(appMenu);
  RELEASE(appMenuItem);
  
  /* File menu */
  NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
  [mainMenu addItem:fileMenuItem];
  
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [fileMenuItem setSubmenu:fileMenu];
  
  [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
  
  RELEASE(fileMenu);
  RELEASE(fileMenuItem);
  
  /* Edit menu */
  NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
  [mainMenu addItem:editMenuItem];
  
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenuItem setSubmenu:editMenu];
  
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  
  RELEASE(editMenu);
  RELEASE(editMenuItem);
  
  /* Help menu */
  NSMenuItem *helpMenuItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:NULL keyEquivalent:@""];
  [mainMenu addItem:helpMenuItem];
  
  NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
  [helpMenuItem setSubmenu:helpMenu];
  
  [helpMenu addItemWithTitle:@"About Network Browser" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  
  RELEASE(helpMenu);
  RELEASE(helpMenuItem);
  
  [NSApp setMainMenu:mainMenu];
  RELEASE(mainMenu);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApp
{
  return YES;
}

- (void)windowWillClose:(NSNotification *)aNotification
{
  if ([aNotification object] == window)
    {
      [NSApp terminate: self];
    }
}

@end
