/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBParser.h"
#import "EPUBBook.h"
#import "EPUBTOCEntry.h"

static NSString *LocalName(NSString *name)
{
    NSRange r = [name rangeOfString:@":"];
    if (r.location != NSNotFound)
    {
        return [name substringFromIndex:r.location + 1];
    }
    return name;
}

static NSString *Trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// WHY: EPUB RS 3.3, 5.3 requires stripping AND collapsing ASCII whitespace
// from Dublin Core and meta element values before processing. A plain trim is
// not enough (internal runs of whitespace must collapse to a single space).
static NSString *CollapseASCIIWhitespace(NSString *s)
{
    if (s == nil)
    {
        return nil;
    }
    NSMutableString *out = [NSMutableString string];
    BOOL inSpace = YES; // treat leading edge as whitespace so it is stripped
    for (NSUInteger i = 0; i < [s length]; i++)
    {
        unichar c = [s characterAtIndex:i];
        BOOL isWS = (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0c);
        if (isWS)
        {
            inSpace = YES;
        }
        else
        {
            if (inSpace && [out length] > 0)
            {
                [out appendString:@" "];
            }
            [out appendString:[NSString stringWithCharacters:&c length:1]];
            inSpace = NO;
        }
    }
    return out;
}

#pragma mark - ZIP container validation (EPUB RS 3.3, 4.2)

// WHY a manual scan instead of relying on `unzip`: 4.2 requires treating
// encrypted archives, unsupported compression methods and unexpected "version
// needed to extract" values as fatal errors. We inspect each local file header
// so we reject such containers before extraction rather than failing mid-way or,
// worse, silently mis-handling them.
static BOOL EPUBLocalHeaderRead32(const uint8_t *p, NSUInteger len, NSUInteger off, uint32_t *out)
{
    if (off + 4 > len) return NO;
    *out = (uint32_t)p[off] | ((uint32_t)p[off + 1] << 8) |
           ((uint32_t)p[off + 2] << 16) | ((uint32_t)p[off + 3] << 24);
    return YES;
}
static BOOL EPUBLocalHeaderRead16(const uint8_t *p, NSUInteger len, NSUInteger off, uint16_t *out)
{
    if (off + 2 > len) return NO;
    *out = (uint16_t)p[off] | ((uint16_t)p[off + 1] << 8);
    return YES;
}

static BOOL EPUBZipIsValidContainer(NSData *data, NSError **error)
{
    const uint8_t *p = [data bytes];
    NSUInteger len = [data length];
    NSUInteger off = 0;
    while (off + 4 <= len)
    {
        uint32_t sig;
        if (!EPUBLocalHeaderRead32(p, len, off, &sig)) break;
        if (sig != 0x04034b50) break; // no more local headers
        uint16_t version, flags, method, fnLen, exLen;
        uint32_t compSize;
        if (!EPUBLocalHeaderRead16(p, len, off + 4, &version)) break;
        if (!EPUBLocalHeaderRead16(p, len, off + 6, &flags)) break;
        if (!EPUBLocalHeaderRead16(p, len, off + 8, &method)) break;
        if (!EPUBLocalHeaderRead32(p, len, off + 18, &compSize)) break;
        if (!EPUBLocalHeaderRead16(p, len, off + 26, &fnLen)) break;
        if (!EPUBLocalHeaderRead16(p, len, off + 28, &exLen)) break;

        if (flags & 0x0001)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:@"EPUBParser" code:6
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"EPUB container is encrypted (encryption not supported)"}];
            }
            return NO;
        }
        if (method != 0 && method != 8)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:@"EPUBParser" code:7
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"EPUB container uses an unsupported compression method"}];
            }
            return NO;
        }
        if (version != 10 && version != 20 && version != 45)
        {
            if (error)
            {
                *error = [NSError errorWithDomain:@"EPUBParser" code:8
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"EPUB container uses an unsupported ZIP version"}];
            }
            return NO;
        }
        // ZIP64 uses 0xFFFFFFFF/0xFFFF as sentinels; we cannot reliably skip
        // those entries, so stop scanning (the container is still extracted).
        if (compSize == 0xFFFFFFFFU || fnLen == 0xFFFF || exLen == 0xFFFF) break;
        NSUInteger advance = 30 + (NSUInteger)fnLen + (NSUInteger)exLen + (NSUInteger)compSize;
        if (flags & 0x0001) advance += 12; // encryption header
        if (advance == 0 || off + advance > len + 0xFFFFFFFFU) break;
        off += advance;
    }
    return YES;
}

/* src may carry a #fragment; resolve relative to baseDir, then make it
   relative to extractRoot so the book can re-resolve via absolutePathForContent:. */
static NSString *ResolveRelativeToExtractRoot(NSString *src, NSString *baseDir, NSString *extractRoot)
{
    if (src == nil)
    {
        return nil;
    }
    NSRange frag = [src rangeOfString:@"#"];
    if (frag.location != NSNotFound)
    {
        src = [src substringToIndex:frag.location];
    }
    if ([src length] == 0)
    {
        return nil;
    }
    NSString *abs = [baseDir stringByAppendingPathComponent:src];
    abs = [abs stringByStandardizingPath];
    NSString *rel = abs;
    if ([abs hasPrefix:extractRoot])
    {
        rel = [abs substringFromIndex:[extractRoot length]];
        if ([rel hasPrefix:@"/"])
        {
            rel = [rel substringFromIndex:1];
        }
    }
    return rel;
}

#pragma mark - container.xml

@interface _ContainerParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *opfPath;
@end

@implementation _ContainerParser
{
    BOOL _found;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    if (_found)
    {
        return;
    }
    NSString *localNameTmp = LocalName(elementName);
    if ([localNameTmp isEqualToString:@"rootfile"])
    {
        NSString *fp = attributes[@"full-path"];
        if (fp != nil)
        {
            _opfPath = fp;
            _found = YES;
        }
    }
}
@end

#pragma mark - OPF

@interface _OPFParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *publisher;
@property (nonatomic, copy) NSString *spineTocId;
@property (nonatomic, copy) NSString *metaCoverId;
@property (nonatomic, copy) NSString *pageProgressionDirection;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *manifest;
@property (nonatomic, strong) NSMutableArray<NSString *> *manifestOrder;
@property (nonatomic, strong) NSMutableArray<NSString *> *spineIds;
@end

@implementation _OPFParser
{
    NSMutableString *_text;
    NSString *_creatorRole;
    BOOL _authorSet;
}
- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _manifest = [NSMutableDictionary dictionary];
        _manifestOrder = [NSMutableArray array];
        _spineIds = [NSMutableArray array];
        _text = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    NSString *local = LocalName(elementName);
    [_text setString:@""];
    if ([local isEqualToString:@"item"])
    {
        NSString *ident = attributes[@"id"];
        NSString *href = attributes[@"href"];
        NSString *mt = attributes[@"media-type"];
        NSString *props = attributes[@"properties"];
        NSString *fb = attributes[@"fallback"];
        if (ident != nil && href != nil)
        {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            if (mt) d[@"media-type"] = mt;
            if (props) d[@"properties"] = props;
            if (fb) d[@"fallback"] = fb;
            d[@"href"] = href;
            _manifest[ident] = d;
            [_manifestOrder addObject:ident];
        }
    }
    else if ([local isEqualToString:@"itemref"])
    {
        NSString *idref = attributes[@"idref"];
        if (idref != nil)
        {
            [_spineIds addObject:idref];
        }
    }
    else if ([local isEqualToString:@"spine"])
    {
        NSString *toc = attributes[@"toc"];
        if (toc != nil)
        {
            _spineTocId = toc;
        }
        // EPUB RS 3.3, 5.5: if the creator does not specify
        // page-progression-direction, the reading system MUST assume "default".
        NSString *ppd = attributes[@"page-progression-direction"];
        if (ppd != nil)
        {
            _pageProgressionDirection = ppd;
        }
    }
    else if ([local isEqualToString:@"meta"])
    {
        NSString *name = attributes[@"name"];
        NSString *content = attributes[@"content"];
        if (name != nil && content != nil &&
            [name caseInsensitiveCompare:@"cover"] == NSOrderedSame)
        {
            _metaCoverId = content;
        }
    }
    else if ([local isEqualToString:@"creator"] || [local isEqualToString:@"contributor"])
    {
        _creatorRole = attributes[@"role"];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    NSString *local = LocalName(elementName);
    NSString *value = CollapseASCIIWhitespace(_text);
    if ([local isEqualToString:@"title"])
    {
        if (_title == nil && [value length] > 0)
        {
            _title = value;
        }
    }
    else if ([local isEqualToString:@"identifier"])
    {
        if (_identifier == nil && [value length] > 0)
        {
            _identifier = value;
        }
    }
    else if ([local isEqualToString:@"language"])
    {
        if (_language == nil && [value length] > 0)
        {
            _language = value;
        }
    }
    else if ([local isEqualToString:@"publisher"])
    {
        if (_publisher == nil && [value length] > 0)
        {
            _publisher = value;
        }
    }
    else if ([local isEqualToString:@"creator"] || [local isEqualToString:@"contributor"])
    {
        if ([value length] > 0)
        {
            BOOL isAut = (_creatorRole != nil &&
                          [_creatorRole caseInsensitiveCompare:@"aut"] == NSOrderedSame);
            if (!_authorSet || isAut)
            {
                _author = value;
                _authorSet = YES;
            }
        }
        _creatorRole = nil;
    }
    [_text setString:@""];
}
@end

#pragma mark - NCX (EPUB2)

@interface _NCXParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<EPUBTOCEntry *> *roots;
@property (nonatomic, copy) NSString *opfDir;
@property (nonatomic, copy) NSString *extractRoot;
@end

@implementation _NCXParser
{
    NSMutableArray *_stack;
    EPUBTOCEntry *_current;
    NSMutableString *_text;
    BOOL _inLabel;
    NSUInteger _playCounter;
}
- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _roots = [NSMutableArray array];
        _stack = [NSMutableArray array];
        _text = [NSMutableString string];
        _playCounter = 1;
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    NSString *local = LocalName(elementName);
    if ([local isEqualToString:@"navPoint"])
    {
        EPUBTOCEntry *entry = [[EPUBTOCEntry alloc] init];
        NSString *po = attributes[@"playOrder"];
        NSUInteger order = 0;
        if (po != nil)
        {
            order = (NSUInteger)[po integerValue];
        }
        if (order == 0)
        {
            order = _playCounter;
        }
        entry.playOrder = order;
        _playCounter++;
        if ([_stack count] == 0)
        {
            [_roots addObject:entry];
        }
        else
        {
            EPUBTOCEntry *parent = [_stack lastObject];
            parent.children = [parent.children arrayByAddingObject:entry];
        }
        [_stack addObject:entry];
        _current = entry;
        _inLabel = NO;
        [_text setString:@""];
    }
    else if ([local isEqualToString:@"navLabel"])
    {
        _inLabel = YES;
        [_text setString:@""];
    }
    else if ([local isEqualToString:@"text"] && _inLabel)
    {
        [_text setString:@""];
    }
    else if ([local isEqualToString:@"content"])
    {
        if (_current != nil)
        {
            NSString *src = attributes[@"src"];
            _current.contentPath = ResolveRelativeToExtractRoot(src, _opfDir, _extractRoot);
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (_inLabel)
    {
        [_text appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    NSString *local = LocalName(elementName);
    if ([local isEqualToString:@"text"] && _inLabel)
    {
        if (_current != nil)
        {
            _current.title = Trimmed(_text);
        }
    }
    else if ([local isEqualToString:@"navLabel"])
    {
        _inLabel = NO;
    }
    else if ([local isEqualToString:@"navPoint"])
    {
        [_stack removeLastObject];
        _current = [_stack lastObject];
    }
}
@end

#pragma mark - Nav (EPUB3)

@interface _NavParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<EPUBTOCEntry *> *roots;
@property (nonatomic, copy) NSString *navDocDir;
@property (nonatomic, copy) NSString *extractRoot;
@end

@implementation _NavParser
{
    NSMutableArray *_stack;
    EPUBTOCEntry *_current;
    NSMutableString *_text;
    BOOL _inTocNav;
    BOOL _inAnchor;
    BOOL _inLi;
}
- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _roots = [NSMutableArray array];
        _stack = [NSMutableArray array];
        _text = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    NSString *local = LocalName(elementName);
    if ([local isEqualToString:@"nav"])
    {
        NSString *type = attributes[@"type"];
        if (type == nil)
        {
            type = attributes[@"epub:type"];
        }
        if (type != nil &&
            [type rangeOfString:@"toc" options:NSCaseInsensitiveSearch].location != NSNotFound)
        {
            _inTocNav = YES;
        }
    }
    else if (_inTocNav && [local isEqualToString:@"li"])
    {
        EPUBTOCEntry *entry = [[EPUBTOCEntry alloc] init];
        if ([_stack count] == 0)
        {
            [_roots addObject:entry];
        }
        else
        {
            EPUBTOCEntry *parent = [_stack lastObject];
            parent.children = [parent.children arrayByAddingObject:entry];
        }
        [_stack addObject:entry];
        _current = entry;
        _inLi = YES;
        [_text setString:@""];
    }
    else if (_inTocNav && _inLi && [local isEqualToString:@"a"])
    {
        _inAnchor = YES;
        [_text setString:@""];
        NSString *href = attributes[@"href"];
        _current.contentPath = ResolveRelativeToExtractRoot(href, _navDocDir, _extractRoot);
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (_inAnchor)
    {
        [_text appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    NSString *local = LocalName(elementName);
    if ([local isEqualToString:@"nav"])
    {
        _inTocNav = NO;
    }
    else if (_inTocNav && [local isEqualToString:@"a"])
    {
        if (_current != nil)
        {
            _current.title = Trimmed(_text);
        }
        _inAnchor = NO;
    }
    else if (_inTocNav && [local isEqualToString:@"li"])
    {
        _inLi = NO;
        [_stack removeLastObject];
        _current = [_stack lastObject];
    }
}
@end

#pragma mark - EPUBParser

@implementation EPUBParser

- (EPUBBook *)parseEPUBAtPath:(NSString *)epubPath error:(NSError **)error
{
    if (epubPath == nil)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"EPUBParser" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"epub path is nil"}];
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:epubPath])
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"EPUBParser" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"epub file not found"}];
        }
        return nil;
    }

    /* EPUB RS 3.3, 4.2: validate the OCF ZIP container (encryption, compression
       method, ZIP version) before extracting anything. */
    NSData *zipData = [NSData dataWithContentsOfFile:epubPath];
    if (!EPUBZipIsValidContainer(zipData, error))
    {
        return nil;
    }

    NSString *tmp = NSTemporaryDirectory();
    NSString *extractDir = [tmp stringByAppendingPathComponent:
        [@"epub-" stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]]];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:&err])
    {
        if (error) { *error = err; }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/unzip"];
    [task setArguments:@[@"-o", @"-q", epubPath, @"-d", extractDir]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    @try
    {
        [task launch];
        [task waitUntilExit];
    }
    @catch (NSException *e)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"EPUBParser" code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [@"unzip failed: " stringByAppendingString:[e reason]]}];
        }
        return nil;
    }
    if ([task terminationStatus] != 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"EPUBParser" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"unzip returned non-zero status"}];
        }
        return nil;
    }
    /* Read pipe so it cannot block; output is tiny with -q. */
    (void)[[pipe fileHandleForReading] readDataToEndOfFile];

    extractDir = [extractDir stringByStandardizingPath];

    /* container.xml -> OPF path */
    NSString *containerPath = [extractDir stringByAppendingPathComponent:@"META-INF/container.xml"];
    _ContainerParser *cp = [[_ContainerParser alloc] init];
    NSXMLParser *cxml = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:containerPath]];
    [cxml setDelegate:cp];
    [cxml setShouldResolveExternalEntities:NO];
    [cxml parse];
    if (cp.opfPath == nil)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"EPUBParser" code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"could not locate OPF path in container.xml"}];
        }
        return nil;
    }
    NSString *opfPath = [extractDir stringByAppendingPathComponent:cp.opfPath];
    opfPath = [opfPath stringByStandardizingPath];
    NSString *opfDir = [opfPath stringByDeletingLastPathComponent];

    /* OPF metadata + manifest + spine */
    _OPFParser *op = [[_OPFParser alloc] init];
    NSXMLParser *oxml = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:opfPath]];
    [oxml setDelegate:op];
    [oxml setShouldResolveExternalEntities:NO];
    [oxml parse];

    NSMutableDictionary<NSString *, NSDictionary *> *absManifest = [NSMutableDictionary dictionary];
    for (NSString *ident in op.manifestOrder)
    {
        NSDictionary *d = op.manifest[ident];
        NSString *href = d[@"href"];
        NSString *abs = [opfDir stringByAppendingPathComponent:href];
        abs = [abs stringByStandardizingPath];
        NSMutableDictionary *nd = [NSMutableDictionary dictionaryWithDictionary:d];
        nd[@"abs"] = abs;
        absManifest[ident] = nd;
    }

    NSMutableArray<NSString *> *spine = [NSMutableArray array];
    for (NSString *idref in op.spineIds)
    {
        // EPUB RS 3.3, 5.4: traverse the manifest fallback chain when a spine
        // item's media type is not directly renderable, terminating at the
        // first manifest item already visited (cycle guard).
        NSString *resolved = [self spineResourceForId:idref manifest:absManifest];
        if (resolved != nil)
        {
            [spine addObject:resolved];
        }
    }
    if ([spine count] == 0)
    {
        for (NSString *ident in op.manifestOrder)
        {
            NSDictionary *d = absManifest[ident];
            NSString *mt = d[@"media-type"];
            if (mt != nil &&
                [mt rangeOfString:@"html" options:NSCaseInsensitiveSearch].location != NSNotFound)
            {
                [spine addObject:d[@"abs"]];
            }
        }
    }

    /* cover */
    NSString *coverPath = nil;
    for (NSString *ident in op.manifestOrder)
    {
        NSDictionary *d = absManifest[ident];
        NSString *props = d[@"properties"];
        if (props != nil &&
            [props rangeOfString:@"cover-image" options:NSCaseInsensitiveSearch].location != NSNotFound)
        {
            coverPath = d[@"abs"];
            break;
        }
    }
    if (coverPath == nil && op.metaCoverId != nil)
    {
        NSDictionary *d = absManifest[op.metaCoverId];
        if (d != nil)
        {
            coverPath = d[@"abs"];
        }
    }
    if (coverPath == nil)
    {
        for (NSString *ident in op.manifestOrder)
        {
            NSDictionary *d = absManifest[ident];
            NSString *mt = d[@"media-type"];
            if (mt != nil &&
                [mt rangeOfString:@"image/" options:NSCaseInsensitiveSearch].location != NSNotFound)
            {
                coverPath = d[@"abs"];
                break;
            }
        }
    }

    /* TOC: prefer EPUB3 nav, fall back to EPUB2 NCX */
    NSMutableArray<EPUBTOCEntry *> *toc = [NSMutableArray array];

    NSString *navId = nil;
    for (NSString *ident in op.manifestOrder)
    {
        NSDictionary *d = absManifest[ident];
        NSString *props = d[@"properties"];
        if (props != nil &&
            [props rangeOfString:@"nav" options:NSCaseInsensitiveSearch].location != NSNotFound)
        {
            navId = ident;
            break;
        }
    }
    if (navId != nil)
    {
        NSDictionary *d = absManifest[navId];
        NSString *navPath = d[@"abs"];
        NSString *navDir = [navPath stringByDeletingLastPathComponent];
        _NavParser *np = [[_NavParser alloc] init];
        np.navDocDir = navDir;
        np.extractRoot = extractDir;
        NSXMLParser *nxml = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:navPath]];
        [nxml setDelegate:np];
    [nxml setShouldResolveExternalEntities:NO];
        [nxml parse];
        toc = np.roots;
    }

    if ([toc count] == 0)
    {
        NSString *ncxId = op.spineTocId;
        NSString *ncxPath = nil;
        if (ncxId != nil)
        {
            NSDictionary *d = absManifest[ncxId];
            if (d != nil)
            {
                ncxPath = d[@"abs"];
            }
        }
        if (ncxPath == nil)
        {
            for (NSString *ident in op.manifestOrder)
            {
                NSDictionary *d = absManifest[ident];
                NSString *mt = d[@"media-type"];
                if (mt != nil && [mt isEqualToString:@"application/x-dtbncx+xml"])
                {
                    ncxPath = d[@"abs"];
                    break;
                }
            }
        }
        if (ncxPath != nil)
        {
            _NCXParser *npx = [[_NCXParser alloc] init];
            npx.opfDir = opfDir;
            npx.extractRoot = extractDir;
            NSXMLParser *nxml = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:ncxPath]];
            [nxml setDelegate:npx];
    [nxml setShouldResolveExternalEntities:NO];
            [nxml parse];
            toc = npx.roots;
        }
    }

    /* Build the book (always non-nil unless extraction failed). */
    EPUBBook *book = [[EPUBBook alloc] init];
    NSString *title = op.title;
    if (title == nil || [title length] == 0)
    {
        title = [epubPath lastPathComponent];
    }
    [book setTitle:title];
    [book setAuthor:op.author];
    [book setIdentifier:op.identifier];
    [book setLanguage:op.language];
    [book setPublisher:op.publisher];
    [book setCoverPath:coverPath];
    [book setSpine:spine];
    [book setTableOfContents:toc];
    // EPUB RS 3.3, 5.5: honor an explicit page-progression-direction; when
    // absent the reading system MUST assume "default" (nil here means default).
    [book setPageProgressionDirection:op.pageProgressionDirection];
    [book setValue:extractDir forKey:@"extractedRoot"];
    return book;
}

#pragma mark - spine fallback resolution (EPUB RS 3.3, 5.4)

- (NSString *)spineResourceForId:(NSString *)idref
                       manifest:(NSDictionary<NSString *, NSDictionary *> *)absManifest
{
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *cur = idref;
    while (cur != nil)
    {
        if ([seen containsObject:cur])
        {
            break; // cycle: terminate the fallback chain
        }
        [seen addObject:cur];
        NSDictionary *d = absManifest[cur];
        if (d == nil)
        {
            break;
        }
        NSString *mt = d[@"media-type"];
        if (mt != nil &&
            ([mt isEqualToString:@"application/xhtml+xml"] ||
             [mt isEqualToString:@"text/html"] ||
             [mt rangeOfString:@"html" options:NSCaseInsensitiveSearch].location != NSNotFound))
        {
            return d[@"abs"];
        }
        cur = d[@"fallback"];
    }
    return nil;
}

@end
