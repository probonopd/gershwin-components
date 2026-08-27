/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBBook.h"
#import "EPUBParser.h"
#import "LCP/LCPManager.h"
#import "LCP/LCPLicense.h"
#import "LCP/LCPOpenSSLBackend.h"
#import "LCP/LCPError.h"
#import <zlib.h>

@interface EPUBBook ()
@property (nonatomic, copy, readwrite) NSString *extractedRoot;
@end

/* SAX collector for META-INF/encryption.xml. Gathers every
 * enc:CipherReference/@URI (the encrypted resource paths) and, per resource,
 * the Compression property (DEFLATE Method=8 + OriginalLength) used by LCP to
 * pre-compress a resource before encrypting it. */
@interface _EncryptedRefCollector : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableSet<NSString *> *refs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *compression;
@end

@implementation _EncryptedRefCollector
{
    NSString *_currentURI;
}
- (instancetype)init
{
    self = [super init];
    if (self) { _refs = [NSMutableSet set]; _compression = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
     attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
    NSString *local = elementName;
    NSRange r = [local rangeOfString:@":"];
    if (r.location != NSNotFound) local = [local substringFromIndex:r.location + 1];
    if ([local isEqualToString:@"EncryptedData"])
    {
        _currentURI = nil;
    }
    else if ([local isEqualToString:@"CipherReference"])
    {
        NSString *uri = attributes[@"URI"];
        if ([uri length] > 0)
        {
            _currentURI = [uri stringByStandardizingPath];
            [_refs addObject: _currentURI];
        }
    }
    else if ([local isEqualToString:@"Compression"])
    {
        if (_currentURI != nil)
        {
            [_compression setObject: @{
                @"method": @([attributes[@"Method"] integerValue]),
                @"originalLength": @([attributes[@"OriginalLength"] integerValue])
            } forKey: _currentURI];
        }
    }
}
@end

@implementation EPUBBook
{
    BOOL _lcpProtected;
    LCPManager *_lcpManager;
    NSSet<NSString *> *_lcpEncryptedPaths;
    NSDictionary<NSString *, NSDictionary *> *_lcpCompression;
    NSString *_lcpHint;
    NSString *_epubPath;
}

- (instancetype)initWithEPUBAtPath:(NSString *)epubPath error:(NSError **)error
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }
    _epubPath = [epubPath copy];
    EPUBParser *parser = [[EPUBParser alloc] init];
    EPUBBook *result = [parser parseEPUBAtPath:epubPath error:error];
    if (result == nil)
    {
        return nil;
    }
    _title = [result.title copy];
    _author = [result.author copy];
    _identifier = [result.identifier copy];
    _language = [result.language copy];
    _publisher = [result.publisher copy];
    _coverPath = [result.coverPath copy];
    _spine = [result.spine copy];
    _tableOfContents = [result.tableOfContents copy];
    _extractedRoot = [result.extractedRoot copy];

    [self _detectLCP];
    return self;
}

/* WHY: LCP detection lives in the resource layer, not the renderer. A book is
 * protected when META-INF/encryption.xml lists encrypted resources. The
 * license may live inside the container (META-INF/license.lcpl) or be
 * delivered separately as a sibling <name>.lcpl next to the EPUB, the common
 * LCPL distribution model. We import whichever we find, then collect the
 * encrypted resource paths (and their compression) from encryption.xml. */
- (void)_detectLCP
{
    if (self.extractedRoot == nil)
        return;
    NSString *encPath = [self.extractedRoot stringByAppendingPathComponent:
        @"META-INF/encryption.xml"];
    if (![[NSFileManager defaultManager] fileExistsAtPath: encPath])
        return;

    NSString *licPath = [self.extractedRoot stringByAppendingPathComponent:
        @"META-INF/license.lcpl"];
    if (![[NSFileManager defaultManager] fileExistsAtPath: licPath] && _epubPath != nil)
    {
        NSString *sibling = [[_epubPath stringByDeletingPathExtension]
            stringByAppendingPathExtension: @"lcpl"];
        if ([[NSFileManager defaultManager] fileExistsAtPath: sibling])
            licPath = sibling;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath: licPath])
        return;

    _lcpProtected = YES;
    NSData *licJSON = [NSData dataWithContentsOfFile: licPath];
    _lcpManager = [[LCPManager alloc] initWithBackend: [LCPOpenSSLBackend new]];
    NSError *le = nil;
    LCPLicense *lic = [_lcpManager importLicense: licJSON error: &le];
    if (lic == nil)
        return; /* invalid license: treat as not protected */
    _lcpHint = lic.userKeyTextHint;
    [self _loadEncryption];
}

/* Parse META-INF/encryption.xml: the encrypted resource set (also the keys of
 * the compression map) and the per-resource compression info. */
- (void)_loadEncryption
{
    NSString *encPath = [self.extractedRoot stringByAppendingPathComponent:
        @"META-INF/encryption.xml"];
    NSData *data = [NSData dataWithContentsOfFile: encPath];
    if (data == nil)
    {
        _lcpEncryptedPaths = [NSSet set];
        _lcpCompression = @{};
        return;
    }
    _EncryptedRefCollector *c = [[_EncryptedRefCollector alloc] init];
    NSXMLParser *p = [[NSXMLParser alloc] initWithData: data];
    [p setShouldResolveExternalEntities: NO];
    [p setDelegate: c];
    [p parse];
    _lcpEncryptedPaths = c.refs;
    _lcpCompression = c.compression;
}

- (NSString *)lcpPassphraseHint
{
    return _lcpHint;
}

- (BOOL)lcpUnlockWithPassphrase:(NSString *)passphrase error:(NSError **)error
{
    if (!_lcpProtected || _lcpManager == nil)
        return NO;
    return [_lcpManager unlockWithPassphrase: passphrase error: error];
}

- (NSString *)materializedPathForPath:(NSString *)anyPath error:(NSError **)error
{
    if (!_lcpProtected || _lcpManager == nil)
        return anyPath;

    NSString *rel = [self _relativePathWithinExtractRoot: anyPath];
    if (rel == nil)
        return anyPath;
    if (![_lcpEncryptedPaths containsObject: rel])
        return [self.extractedRoot stringByAppendingPathComponent: rel];

    if ([_lcpManager isLocked])
        {
            if (error)
                *error = [NSError errorWithDomain: LCPErrorDomain
                                             code: LCPErrorInvalidLicense
                                         userInfo: @{ NSLocalizedDescriptionKey:
                                           @"publication is locked" }];
            return nil;
        }

    NSString *ctPath = [self.extractedRoot stringByAppendingPathComponent: rel];
    NSData *ct = [NSData dataWithContentsOfFile: ctPath];
    if (ct == nil)
        {
            if (error)
                *error = [NSError errorWithDomain: LCPErrorDomain
                                             code: LCPErrorPublicationUnavailable
                                         userInfo: @{ NSLocalizedDescriptionKey:
                                           @"cannot read encrypted resource" }];
            return nil;
        }
    NSData *pt = [_lcpManager decryptResource: ct error: error];
    if (pt == nil)
        return nil;

    /* LCP optionally DEFLATEs a resource before encrypting it (per-resource
     * Compression property in encryption.xml). Inflate it back to the
     * original length after decryption. */
    NSDictionary *cm = _lcpCompression[rel];
    if (cm != nil && [cm[@"method"] integerValue] == 8)
    {
        pt = [self _inflate: pt
              originalLength: [cm[@"originalLength"] unsignedIntegerValue]
                        error: error];
        if (pt == nil)
            return nil;
    }

    /* Cache the decrypted bytes inside the temp extract dir (never the
     * user's original EPUB). */
    NSString *outPath = [[self.extractedRoot
        stringByAppendingPathComponent: @".lcpdec"]
        stringByAppendingPathComponent: rel];
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [outPath stringByDeletingLastPathComponent]
                               withIntermediateDirectories: YES
                                                attributes: nil error: NULL];
    [pt writeToFile: outPath atomically: NO];
    return outPath;
}

/* Inflate zlib-compressed data (Compression Method=8) to its known original
 * length. Returns nil on failure. */
- (NSData *)_inflate:(NSData *)input
      originalLength:(NSUInteger)originalLength
               error:(NSError **)error
{
    if (originalLength == 0)
        return input;
    NSMutableData *out = [[NSMutableData alloc] initWithLength: originalLength];
    z_stream strm;
    strm.next_in = (Bytef *)[input bytes];
    strm.avail_in = (uInt)[input length];
    strm.next_out = [out mutableBytes];
    strm.avail_out = (uInt)originalLength;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    if (inflateInit(&strm) != Z_OK)
    {
        if (error)
            *error = [NSError errorWithDomain: LCPErrorDomain
                                         code: LCPErrorDecryptionFailed
                                     userInfo: @{ NSLocalizedDescriptionKey:
                                       @"cannot initialise inflation" }];
        return nil;
    }
    int rc = inflate(&strm, Z_FINISH);
    if (rc != Z_STREAM_END)
    {
        inflateEnd(&strm);
        if (error)
            *error = [NSError errorWithDomain: LCPErrorDomain
                                         code: LCPErrorDecryptionFailed
                                     userInfo: @{ NSLocalizedDescriptionKey:
                                       @"resource inflation failed" }];
        return nil;
    }
    [out setLength: strm.total_out];
    inflateEnd(&strm);
    return out;
}

/* Map any relative (to extract root) or absolute path back to its path
 * relative to the extract root, or nil if it is outside the container. */
- (NSString *)_relativePathWithinExtractRoot:(NSString *)anyPath
{
    NSString *root = [self.extractedRoot stringByStandardizingPath];
    NSString *std = [anyPath stringByStandardizingPath];
    if ([std isEqualToString: root])
        return @"";
    if ([std hasPrefix: [root stringByAppendingString: @"/"]])
    {
        NSString *rel = [std substringFromIndex: [root length] + 1];
        /* Paths under the decryption cache (.lcpdec/) map back to the
         * canonical container-relative resource path. */
        if ([rel hasPrefix: @".lcpdec/"])
            rel = [rel substringFromIndex: [@".lcpdec/" length]];
        return rel;
    }
    /* Try interpreting as already-relative. */
    NSString *candidate = [self.extractedRoot stringByAppendingPathComponent: anyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath: candidate])
        return [anyPath stringByStandardizingPath];
    return nil;
}

- (NSString *)absolutePathForContent:(NSString *)relativePath
{
    if (relativePath == nil)
    {
        return nil;
    }
    if ([relativePath isAbsolutePath])
    {
        return relativePath;
    }
    return [self.extractedRoot stringByAppendingPathComponent:relativePath];
}

- (void)cleanupExtraction
{
    if (self.extractedRoot == nil)
    {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:self.extractedRoot error:NULL];
}

@end
