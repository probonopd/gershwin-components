/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUEraseViewController.h"

#import <objc/runtime.h>

#import "AppearanceMetrics.h"
#import "DUErrors.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUOperationManager.h"
#import "DUEraseOperation.h"
#import "DUParsing.h"
#import "DUStorageBackend.h"
#import "DUStorageCapabilities.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"
#import "DUNotifications.h"
#import "DUStorageDevice.h"

static NSString * const kDefaultsConfirmDestructive =
    @"DUConfirmDestructiveOperations";

@interface DUEraseViewController ()
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;
@property (nonatomic, strong, readwrite) NSView *view;

@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *formatLabel;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSButton *securityOptionsButton;
@property (nonatomic, strong) NSButton *eraseButton;

@property (nonatomic, weak) DUStorageObject *currentObject;
@property (nonatomic, assign) NSString *selectedSecurityMethod;
@property (nonatomic, assign) BOOL operationRunning;
@property (nonatomic, strong) NSArray<NSButton *> *pendingSecurityRadios;
@end

@implementation DUEraseViewController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                               logView:(DUOperationLogView *)logView
{
    NSParameterAssert(manager != nil);
    NSParameterAssert(logView != nil);
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _storageManager = manager;
    _logView = logView;

    CGFloat width = 400.0;
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 180)];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _nameLabel = [self label:NSLocalizedString(@"Name:", nil)];
    _nameField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(0, 0, width - 2 * METRICS_CONTENT_SIDE_MARGIN - 90,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT)];

    _formatLabel = [self label:NSLocalizedString(@"Format:", nil)];
    _formatPopup = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(0, 0, width - 2 * METRICS_CONTENT_SIDE_MARGIN - 90, METRICS_BUTTON_HEIGHT)];
    [_formatPopup setTarget:self];
    [_formatPopup setAction:@selector(formatChanged:)];

    _securityOptionsButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _securityOptionsButton.title =
        NSLocalizedString(@"Security Options...", nil);
    _securityOptionsButton.bezelStyle = NSRoundedBezelStyle;
    _securityOptionsButton.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_securityOptionsButton sizeToFit];
    [_securityOptionsButton setTarget:self];
    [_securityOptionsButton setAction:@selector(showSecurityOptions:)];

    _eraseButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _eraseButton.title = NSLocalizedString(@"Erase", nil);
    _eraseButton.bezelStyle = NSRoundedBezelStyle;
    _eraseButton.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_eraseButton sizeToFit];
    [_eraseButton setTarget:self];
    [_eraseButton setAction:@selector(eraseClicked:)];
    _eraseButton.keyEquivalent = @"\r";

    for (NSView *subview in @[ _nameLabel, _nameField, _formatLabel,
                               _formatPopup, _securityOptionsButton,
                               _eraseButton ]) {
        [_view addSubview:subview];
    }
    [self layoutForWidth:NSWidth(_view.frame) height:NSHeight(_view.frame)];

    // Operation feedback reaches this pane through notifications; the
    // operation itself owns the worker thread.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationDidUpdate:)
               name:DUOperationDidUpdateNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationDidFinish:)
               name:DUOperationDidFinishNotification
             object:nil];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)operationDidUpdate:(NSNotification *)note
{
    DUStorageObject *target = note.userInfo[kDUUserInfoObjectKey];
    if (target != nil && target == self.currentObject) {
        NSString *message = [note.userInfo[kDUUserInfoOperationKey] message];
        [self.logView appendLine:message ?: @""];
    }
}

- (void)operationDidFinish:(NSNotification *)note
{
    DUStorageObject *target = note.userInfo[kDUUserInfoObjectKey];
    if (target != nil && target == self.currentObject) {
        [self operationFinished:note.userInfo[kDUUserInfoErrorKey]];
    }
}

- (NSTextField *)label:(NSString *)text
{
    NSTextField *label =
        [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.stringValue = text;
    label.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [label sizeToFit];
    return label;
}

- (void)layoutForWidth:(CGFloat)width height:(CGFloat)height
{
    CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat contentWidth = width - 2 * side;
    CGFloat rowGap = METRICS_SPACE_16;

    CGFloat eraseY = bottom;
    [_eraseButton setFrameOrigin:
        NSMakePoint(width - side - NSWidth(_eraseButton.frame), eraseY)];

    CGFloat securityY = eraseY + METRICS_BUTTON_HEIGHT + rowGap;
    [_securityOptionsButton setFrameOrigin:NSMakePoint(side, securityY)];

    CGFloat formatY = securityY + METRICS_BUTTON_HEIGHT + rowGap;
    _formatPopup.frame =
        NSMakeRect(side + 90, formatY, contentWidth - 90,
                   METRICS_BUTTON_HEIGHT);
    [_formatLabel setFrameOrigin:
        NSMakePoint(side, formatY +
                              (METRICS_BUTTON_HEIGHT -
                               NSHeight(_formatLabel.frame)) / 2.0)];

    CGFloat nameY = formatY + METRICS_TEXT_INPUT_FIELD_HEIGHT + rowGap;
    _nameField.frame =
        NSMakeRect(side + 90, nameY, contentWidth - 90,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [_nameLabel setFrameOrigin:
        NSMakePoint(side, nameY + (METRICS_TEXT_INPUT_FIELD_HEIGHT -
                                   NSHeight(_nameLabel.frame)) / 2.0)];
}

#pragma mark - Selection state

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities
{
    self.currentObject = object;

    [_formatPopup removeAllItems];
    if (object != nil) {
        NSArray<NSDictionary *> *formats =
            [self.storageManager supportedFormatsForObject:object];
        for (NSDictionary *format in formats) {
            if (![format[kDUFormatCanFormatKey] boolValue]) {
                continue;
            }
            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:format[kDUFormatDisplayNameKey]
                       action:nil
                keyEquivalent:@""];
            item.representedObject = format[kDUFormatIdentifierKey];
            [_formatPopup.menu addItem:item];
        }
        if (_formatPopup.itemArray.count > 0) {
            [_formatPopup selectItemAtIndex:0];
        }

        // Prefill with the current display name; users usually keep it.
        _nameField.stringValue = object.displayName ?: @"";
    } else {
        _nameField.stringValue = @"";
    }

    _securityOptionsButton.enabled =
        self.storageManager.eraseSecurityOptions.count > 0 &&
        object != nil;
    [self updateEnabledStates:capabilities];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    self.operationRunning = !enabled;
    [self updateEnabledStates:nil];
}

- (void)updateEnabledStates:(DUStorageCapabilities *)capabilities
{
    BOOL hasFormat = _formatPopup.selectedItem != nil &&
        _formatPopup.selectedItem.representedObject != nil;
    BOOL erasable = capabilities != nil ? capabilities.canErase : YES;
    _eraseButton.enabled = self.currentObject != nil && !self.operationRunning &&
        hasFormat && erasable;
}

#pragma mark - Actions

- (void)formatChanged:(id)sender
{
    (void)sender;
    [self updateEnabledStates:nil];
}

- (void)showSecurityOptions:(id)sender
{
    (void)sender;
    NSArray<NSDictionary *> *options =
        [self.storageManager eraseSecurityOptions];

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 320, 40 +
                                       (CGFloat)options.count * 20 + 50)
                  styleMask:NSTitledWindowMask
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = NSLocalizedString(@"Erase Security Options", nil);

    NSView *content = panel.contentView;
    NSMutableArray<NSButton *> *radios = [NSMutableArray array];
    CGFloat y = NSHeight(content.frame) - METRICS_CONTENT_TOP_MARGIN - 18;
    for (NSDictionary *option in options) {
        NSString *method = option[kDUEraseSecurityMethodKey];
        NSButton *radio = [[NSButton alloc]
            initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y, 260,
                                     METRICS_RADIO_BUTTON_SIZE)];
        radio.buttonType = NSRadioButton;
        radio.font = METRICS_FONT_SYSTEM_REGULAR_11;
        radio.title =
            [method isEqualToString:kDUEraseMethodZerosKey]
                ? NSLocalizedString(@"Overwrite with zeros", nil)
                : NSLocalizedString(@"Standard erase", nil);
        objc_setAssociatedObject(radio, "duMethod", method, OBJC_ASSOCIATION_COPY);
        if ([method isEqualToString:self.selectedSecurityMethod] ||
            (self.selectedSecurityMethod.length == 0 &&
             radios.count == 0)) {
            radio.state = NSOnState;
        }
        [content addSubview:radio];
        [radios addObject:radio];
        y -= METRICS_RADIO_BUTTON_LINE_SPACING;
    }

    NSButton *okButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(NSWidth(content.frame) -
                                     METRICS_CONTENT_SIDE_MARGIN - 100,
                                 METRICS_CONTENT_BOTTOM_MARGIN, 100,
                                 METRICS_BUTTON_HEIGHT)];
    okButton.title = NSLocalizedString(@"Done", nil);
    okButton.bezelStyle = NSRoundedBezelStyle;
    [okButton sizeToFit];
    okButton.keyEquivalent = @"\r";
    [okButton setTarget:self];
    [okButton setAction:@selector(securityDialogDone:)];
    [content addSubview:okButton];

    _pendingSecurityRadios = radios;
    NSApp = [NSApplication sharedApplication];
    [panel center];
    [NSApp runModalForWindow:panel];

    for (NSButton *radio in radios) {
        if (radio.state == NSOnState) {
            self.selectedSecurityMethod = objc_getAssociatedObject(radio, "duMethod");
            break;
        }
    }
    [panel orderOut:nil];
    _pendingSecurityRadios = nil;
}

- (void)securityDialogDone:(id)sender
{
    (void)sender;
    [NSApp stopModal];
}

- (void)eraseClicked:(id)sender
{
    (void)sender;
    DUStorageObject *object = self.currentObject;
    NSString *formatIdentifier = _formatPopup.selectedItem.representedObject;
    if (object == nil || formatIdentifier == nil || self.operationRunning) {
        return;
    }

    // Destructive confirmation identifying exactly what will be destroyed
    // (SPEC section 14.4); Cancel is the default button.
    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:kDefaultsConfirmDestructive]) {
        NSString *message = [NSString stringWithFormat:
            NSLocalizedString(
                @"Erasing \"%@\" will destroy all data on it. The volume "
                @"will be recreated as \"%@\" in %@ format. Continue?",
                nil),
            object.displayName ?: @"",
            _nameField.stringValue,
            _formatPopup.titleOfSelectedItem];
        NSInteger choice = NSRunAlertPanel(
            NSLocalizedString(@"Erase", nil),
            message,
            NSLocalizedString(@"Cancel", nil),
            NSLocalizedString(@"Erase", nil),
            nil);
        if (choice != NSAlertAlternateReturn) {
            return;
        }
    }

    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[@"name"] = _nameField.stringValue;
    options[kDUFormatIdentifierKey] = formatIdentifier;
    if (self.selectedSecurityMethod.length > 0) {
        options[kDUEraseSecurityMethodKey] = self.selectedSecurityMethod;
    }

    NSError *error = nil;
    [self.logView appendLine:[NSString stringWithFormat:
        NSLocalizedString(@"Erasing %@...", nil),
        object.displayName ?: @""]];
    self.operationRunning = YES;

    id<DUStorageBackend> backend = self.storageManager.backend;
    DUEraseOperation *operation =
        [[DUEraseOperation alloc] initWithBackend:backend
                                           object:object
                                          options:options];
    BOOL started =
        [self.storageManager.operationManager startOperation:operation
                                                       error:&error];
    if (!started) {
        self.operationRunning = NO;
        [self.logView appendLine:error.localizedDescription ?: @""];
        return;
    }
    [self updateEnabledStates:nil];
}

- (void)operationFinished:(NSError *)error
{
    __strong typeof(self) strongSelf = self;
    if (strongSelf == nil) {
        return;
    }
    strongSelf.operationRunning = NO;
    [strongSelf updateEnabledStates:nil];
    if (error == nil) {
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"Erase completed successfully.", nil)];
    } else if (error.code == DUErrorCancelled) {
        [strongSelf.logView appendLine:NSLocalizedString(@"Cancelled.", nil)];
    } else {
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"Erase failed.", nil)];
    }
}

@end
