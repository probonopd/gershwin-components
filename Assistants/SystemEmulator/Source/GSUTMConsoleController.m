#import "GSUTMConsoleController.h"

@interface GSUTMConsoleController ()
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic) int consolePort;
@end

@implementation GSUTMConsoleController

- (instancetype)init
{
    self = [super initWithWindow:nil];
    if (self) {
        _consolePort = 5678;
        [self loadWindow];
    }
    return self;
}

- (void)loadWindow
{
    NSRect winRect = NSMakeRect(100, 100, 700, 400);
    NSUInteger style = NSTitledWindowMask | NSClosableWindowMask |
                       NSResizableWindowMask | NSMiniaturizableWindowMask;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:winRect
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Serial Console"];

    _scrollView = [[NSScrollView alloc] initWithFrame:[window contentRectForFrameRect:winRect]];
    [_scrollView setHasVerticalScroller:YES];
    [_scrollView setHasHorizontalScroller:YES];
    [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _textView = [[NSTextView alloc] initWithFrame:[_scrollView bounds]];
    [_textView setMinSize:NSMakeSize(0, 0)];
    [_textView setMaxSize:NSMakeSize(1e7, 1e7)];
    [_textView setVerticallyResizable:YES];
    [_textView setHorizontallyResizable:YES];
    [_textView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_textView setEditable:NO];
    [_textView setSelectable:YES];
    [_textView setFont:[NSFont fontWithName:@"Menlo" size:11]
                ?: [NSFont userFixedPitchFontOfSize:11]];
    [_textView setBackgroundColor:[NSColor whiteColor]];
    [_textView setTextColor:[NSColor blackColor]];
    [_textView setRichText:NO];
    [_textView setImportsGraphics:NO];

    [_scrollView setDocumentView:_textView];
    [window setContentView:_scrollView];
    [self setWindow:window];
}

- (void)dealloc
{
    [super dealloc];
}

- (void)appendData:(NSData *)data
{
    if (!_textView) return;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str) {
        str = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!str) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSTextStorage *storage = [self->_textView textStorage];
        [storage beginEditing];
        [storage appendAttributedString:
         [[NSAttributedString alloc] initWithString:str
                                         attributes:@{NSForegroundColorAttributeName: [NSColor blackColor],
                                                      NSFontAttributeName: [self->_textView font]}]];
        [storage endEditing];

        NSRange range = NSMakeRange([[self->_textView string] length], 0);
        [self->_textView scrollRangeToVisible:range];
    });
}

- (void)clear
{
    if (_textView) {
        [_textView setString:@""];
    }
}

- (void)setConsolePort:(int)port
{
    _consolePort = port;
    [[self window] setTitle:[NSString stringWithFormat:@"Serial Console (port %d)", port]];
}

- (void)showWindow:(id)sender
{
    [super showWindow:sender];
    [[self window] makeFirstResponder:_textView];
}

@end
