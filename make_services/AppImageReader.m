/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Reads the top-level contents of Type-2 AppImage files.  A Type-2 AppImage
 * is an ELF runtime with a SquashFS image appended; the SquashFS payload is
 * located by parsing the ELF section headers (falling back to scanning for
 * the SquashFS magic) and then read with libsquashfs directly from the
 * AppImage file via a pread-based sqfs_file_t.
 */

#import "AppImageReader.h"

#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/types.h>

/* libsquashfs is not packaged on every supported OS (e.g. Arch, OpenBSD);
   the GNUmakefile defines HAVE_LIBSQUASHFS only when it is available, so
   make_services still builds there, just without AppImage registration. */
#ifdef HAVE_LIBSQUASHFS

#import <sqfs/predef.h>
#import <sqfs/error.h>
#import <sqfs/super.h>
#import <sqfs/compressor.h>
#import <sqfs/dir_reader.h>
#import <sqfs/dir.h>
#import <sqfs/inode.h>
#import <sqfs/io.h>
#import <sqfs/data_reader.h>
#import <sqfs/block.h>

#define APPIMAGE_EI_NIDENT 16
#define APPIMAGE_ELFCLASS32 1
#define APPIMAGE_ELFCLASS64 2
#define APPIMAGE_ELFDATA2LSB 1
#define APPIMAGE_ELFDATA2MSB 2
#define APPIMAGE_EI_CLASS 4
#define APPIMAGE_EI_DATA 5

/* A sqfs_file_t reading straight from the AppImage fd at a given offset. */
typedef struct {
  sqfs_file_t base;
  int fd;
  off_t base_offset;
  sqfs_u64 size;
  sqfs_u64 physical_size;
} AppImageSqfsFile;

typedef struct {
  unsigned char e_ident[APPIMAGE_EI_NIDENT];
  uint16_t e_type;
  uint16_t e_machine;
  uint32_t e_version;
  uint32_t e_entry;
  uint32_t e_phoff;
  uint32_t e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize;
  uint16_t e_phentsize;
  uint16_t e_phnum;
  uint16_t e_shentsize;
  uint16_t e_shnum;
  uint16_t e_shstrndx;
} AppImageElf32_Ehdr;

typedef struct {
  unsigned char e_ident[APPIMAGE_EI_NIDENT];
  uint16_t e_type;
  uint16_t e_machine;
  uint32_t e_version;
  uint64_t e_entry;
  uint64_t e_phoff;
  uint64_t e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize;
  uint16_t e_phentsize;
  uint16_t e_phnum;
  uint16_t e_shentsize;
  uint16_t e_shnum;
  uint16_t e_shstrndx;
} AppImageElf64_Ehdr;

typedef struct {
  uint32_t sh_name;
  uint32_t sh_type;
  uint32_t sh_flags;
  uint32_t sh_addr;
  uint32_t sh_offset;
  uint32_t sh_size;
  uint32_t sh_link;
  uint32_t sh_info;
  uint32_t sh_addralign;
  uint32_t sh_entsize;
} AppImageElf32_Shdr;

typedef struct {
  uint32_t sh_name;
  uint32_t sh_type;
  uint64_t sh_flags;
  uint64_t sh_addr;
  uint64_t sh_offset;
  uint64_t sh_size;
  uint32_t sh_link;
  uint32_t sh_info;
  uint64_t sh_addralign;
  uint64_t sh_entsize;
} AppImageElf64_Shdr;

static uint16_t AppImageBswap16(uint16_t value)
{
  return (uint16_t)(((value & 0xff) << 8) | (value >> 8));
}

static uint32_t AppImageBswap32(uint32_t value)
{
  return ((uint32_t)AppImageBswap16((uint16_t)(value & 0xffff)) << 16)
         | (uint32_t)AppImageBswap16((uint16_t)(value >> 16));
}

static uint64_t AppImageBswap64(uint64_t value)
{
  return ((uint64_t)AppImageBswap32((uint32_t)(value & 0xffffffff)) << 32)
         | (uint64_t)AppImageBswap32((uint32_t)(value >> 32));
}

static uint16_t AppImageElf16ToHost(uint16_t val, unsigned char data)
{
  if (data == APPIMAGE_ELFDATA2MSB) {
    return AppImageBswap16(val);
  }
  return val;
}

static uint32_t AppImageElf32ToHost(uint32_t val, unsigned char data)
{
  if (data == APPIMAGE_ELFDATA2MSB) {
    return AppImageBswap32(val);
  }
  return val;
}

static uint64_t AppImageElf64ToHost(uint64_t val, unsigned char data)
{
  if (data == APPIMAGE_ELFDATA2MSB) {
    return AppImageBswap64(val);
  }
  return val;
}

static int AppImageSqfsFileReadAt(sqfs_file_t *file,
                                  sqfs_u64 offset,
                                  void *buffer,
                                  size_t size)
{
  AppImageSqfsFile *self = (AppImageSqfsFile *)file;
  sqfs_u64 end = offset + size;

  if (offset >= self->physical_size) {
    return SQFS_ERROR_OUT_OF_BOUNDS;
  }

  size_t readable = size;
  if (end > self->physical_size) {
    readable = (size_t)(self->physical_size - offset);
  }

  if (readable > 0) {
    ssize_t got = pread(self->fd, buffer, readable, self->base_offset + (off_t)offset);
    if (got != (ssize_t)readable) {
      return SQFS_ERROR_IO;
    }
  }

  if (readable < size) {
    memset(((unsigned char *)buffer) + readable, 0, size - readable);
  }

  return 0;
}

static int AppImageSqfsFileWriteAt(sqfs_file_t *file,
                                   sqfs_u64 offset,
                                   const void *buffer,
                                   size_t size)
{
  (void)file;
  (void)offset;
  (void)buffer;
  (void)size;
  return SQFS_ERROR_UNSUPPORTED;
}

static sqfs_u64 AppImageSqfsFileGetSize(const sqfs_file_t *file)
{
  const AppImageSqfsFile *self = (const AppImageSqfsFile *)file;
  return self->size;
}

static int AppImageSqfsFileTruncate(sqfs_file_t *file, sqfs_u64 size)
{
  (void)file;
  (void)size;
  return SQFS_ERROR_UNSUPPORTED;
}

static void AppImageSqfsFileDestroy(sqfs_object_t *obj)
{
  AppImageSqfsFile *self = (AppImageSqfsFile *)obj;
  if (self->fd >= 0) {
    close(self->fd);
    self->fd = -1;
  }
  free(self);
}

static sqfs_object_t *AppImageSqfsFileCopy(const sqfs_object_t *obj)
{
  const AppImageSqfsFile *orig = (const AppImageSqfsFile *)obj;
  int dupfd = dup(orig->fd);
  if (dupfd < 0) {
    return NULL;
  }

  AppImageSqfsFile *copy = calloc(1, sizeof(*copy));
  if (copy == NULL) {
    close(dupfd);
    return NULL;
  }
  copy->fd = dupfd;
  copy->base_offset = orig->base_offset;
  copy->physical_size = orig->physical_size;
  copy->size = orig->size;
  copy->base.read_at = AppImageSqfsFileReadAt;
  copy->base.write_at = AppImageSqfsFileWriteAt;
  copy->base.get_size = AppImageSqfsFileGetSize;
  copy->base.truncate = AppImageSqfsFileTruncate;
  copy->base.base.destroy = AppImageSqfsFileDestroy;
  copy->base.base.copy = AppImageSqfsFileCopy;
  return (sqfs_object_t *)copy;
}

static AppImageSqfsFile *AppImageSqfsFileCreate(int fd,
                                                off_t base_offset,
                                                sqfs_u64 size)
{
  AppImageSqfsFile *file = calloc(1, sizeof(*file));
  if (!file) {
    return NULL;
  }

  file->fd = fd;
  file->base_offset = base_offset;
  file->physical_size = size;
  file->size = size + (sqfs_u64)SQFS_META_BLOCK_SIZE * 1024;
  file->base.read_at = AppImageSqfsFileReadAt;
  file->base.write_at = AppImageSqfsFileWriteAt;
  file->base.get_size = AppImageSqfsFileGetSize;
  file->base.truncate = AppImageSqfsFileTruncate;
  file->base.base.destroy = AppImageSqfsFileDestroy;
  file->base.base.copy = AppImageSqfsFileCopy;

  return file;
}

static BOOL AppImageHasType2Magic(const char *path)
{
  unsigned char ident[16];
  int fd = open(path, O_RDONLY);
  ssize_t rd;

  if (fd < 0) {
    return NO;
  }

  rd = read(fd, ident, sizeof(ident));
  close(fd);

  if (rd < (ssize_t)sizeof(ident)) {
    return NO;
  }

  if (ident[0] != 0x7f || ident[1] != 'E' || ident[2] != 'L' || ident[3] != 'F') {
    return NO;
  }

  if (ident[8] == 'A' && ident[9] == 'I' && ident[10] == 0x02) {
    return YES;
  }

  return NO;
}

static BOOL AppImageValidateSquashfsOffset(int fd, off_t offset, off_t fileSize);

static off_t AppImageElfFileSize(const char *path)
{
  FILE *fd = fopen(path, "rb");
  unsigned char ident[APPIMAGE_EI_NIDENT];
  size_t rd;

  if (fd == NULL) {
    return -1;
  }

  rd = fread(ident, 1, sizeof(ident), fd);
  if (rd != sizeof(ident)) {
    fclose(fd);
    return -1;
  }

  if (ident[0] != 0x7f || ident[1] != 'E' || ident[2] != 'L' || ident[3] != 'F') {
    fclose(fd);
    return -1;
  }

  unsigned char elfClass = ident[APPIMAGE_EI_CLASS];
  unsigned char elfData = ident[APPIMAGE_EI_DATA];

  if (elfClass == APPIMAGE_ELFCLASS32) {
    AppImageElf32_Ehdr ehdr32;
    AppImageElf32_Shdr shdr32;
    off_t sht_end;
    off_t last_section_end;

    fseeko(fd, 0, SEEK_SET);
    rd = fread(&ehdr32, 1, sizeof(ehdr32), fd);
    if (rd != sizeof(ehdr32)) {
      fclose(fd);
      return -1;
    }

    uint32_t e_shoff = AppImageElf32ToHost(ehdr32.e_shoff, elfData);
    uint16_t e_shentsize = AppImageElf16ToHost(ehdr32.e_shentsize, elfData);
    uint16_t e_shnum = AppImageElf16ToHost(ehdr32.e_shnum, elfData);

    if (e_shoff == 0 || e_shentsize == 0 || e_shnum == 0) {
      fclose(fd);
      return -1;
    }

    sht_end = (off_t)e_shoff + ((off_t)e_shentsize * (off_t)e_shnum);

    if (fseeko(fd, e_shoff, SEEK_SET) != 0) {
      fclose(fd);
      return -1;
    }

    last_section_end = 0;
    for (uint16_t i = 0; i < e_shnum; i++) {
      rd = fread(&shdr32, 1, sizeof(shdr32), fd);
      if (rd != sizeof(shdr32)) {
        fclose(fd);
        return -1;
      }

      last_section_end = (off_t)AppImageElf32ToHost(shdr32.sh_offset, elfData)
                         + (off_t)AppImageElf32ToHost(shdr32.sh_size, elfData);
    }

    fclose(fd);
    return (last_section_end > sht_end) ? last_section_end : sht_end;
  }

  if (elfClass == APPIMAGE_ELFCLASS64) {
    AppImageElf64_Ehdr ehdr64;
    AppImageElf64_Shdr shdr64;
    off_t sht_end;
    off_t last_section_end;

    fseeko(fd, 0, SEEK_SET);
    rd = fread(&ehdr64, 1, sizeof(ehdr64), fd);
    if (rd != sizeof(ehdr64)) {
      fclose(fd);
      return -1;
    }

    uint64_t e_shoff = AppImageElf64ToHost(ehdr64.e_shoff, elfData);
    uint16_t e_shentsize = AppImageElf16ToHost(ehdr64.e_shentsize, elfData);
    uint16_t e_shnum = AppImageElf16ToHost(ehdr64.e_shnum, elfData);

    if (e_shoff == 0 || e_shentsize == 0 || e_shnum == 0) {
      fclose(fd);
      return -1;
    }

    sht_end = (off_t)e_shoff + ((off_t)e_shentsize * (off_t)e_shnum);

    if (fseeko(fd, (off_t)e_shoff, SEEK_SET) != 0) {
      fclose(fd);
      return -1;
    }

    last_section_end = 0;
    for (uint16_t i = 0; i < e_shnum; i++) {
      rd = fread(&shdr64, 1, sizeof(shdr64), fd);
      if (rd != sizeof(shdr64)) {
        fclose(fd);
        return -1;
      }

      last_section_end = (off_t)AppImageElf64ToHost(shdr64.sh_offset, elfData)
                         + (off_t)AppImageElf64ToHost(shdr64.sh_size, elfData);
    }

    fclose(fd);
    return (last_section_end > sht_end) ? last_section_end : sht_end;
  }

  fclose(fd);
  return -1;
}

static sqfs_u16 AppImageReadLE16(const unsigned char *ptr)
{
  return (sqfs_u16)(ptr[0] | (ptr[1] << 8));
}

static sqfs_u32 AppImageReadLE32(const unsigned char *ptr)
{
  return (sqfs_u32)(ptr[0] | (ptr[1] << 8) | (ptr[2] << 16) | (ptr[3] << 24));
}

static sqfs_u64 AppImageReadLE64(const unsigned char *ptr)
{
  sqfs_u64 lo = AppImageReadLE32(ptr);
  sqfs_u64 hi = AppImageReadLE32(ptr + 4);
  return lo | (hi << 32);
}

static BOOL AppImageSuperblockLooksValid(const unsigned char *buf,
                                         size_t len,
                                         off_t fileSize,
                                         off_t offset)
{
  if (len < sizeof(sqfs_super_t)) {
    return NO;
  }

  sqfs_u32 magic = AppImageReadLE32(buf + 0);
  if (magic != SQFS_MAGIC) {
    return NO;
  }

  sqfs_u16 version_major = AppImageReadLE16(buf + 28);
  sqfs_u16 version_minor = AppImageReadLE16(buf + 30);
  sqfs_u32 block_size = AppImageReadLE32(buf + 12);
  sqfs_u16 compression_id = AppImageReadLE16(buf + 20);
  sqfs_u16 block_log = AppImageReadLE16(buf + 22);
  sqfs_u32 inode_count = AppImageReadLE32(buf + 4);
  sqfs_u64 bytes_used = AppImageReadLE64(buf + 40);

  if (version_major != SQFS_VERSION_MAJOR || version_minor != SQFS_VERSION_MINOR) {
    return NO;
  }

  if (block_size < SQFS_MIN_BLOCK_SIZE || block_size > SQFS_MAX_BLOCK_SIZE) {
    return NO;
  }

  if ((block_size & (block_size - 1)) != 0) {
    return NO;
  }

  if (block_log < 12 || block_log > 20) {
    return NO;
  }

  if (compression_id < SQFS_COMP_MIN || compression_id > SQFS_COMP_MAX) {
    return NO;
  }

  if (inode_count == 0) {
    return NO;
  }

  if (bytes_used == 0) {
    return NO;
  }

  if (offset + (off_t)bytes_used > fileSize) {
    return NO;
  }

  return YES;
}

static BOOL AppImageValidateSquashfsOffset(int fd, off_t offset, off_t fileSize)
{
  unsigned char buffer[sizeof(sqfs_super_t)];

  if (offset < 0 || offset + (off_t)sizeof(buffer) > fileSize) {
    return NO;
  }

  if (lseek(fd, offset, SEEK_SET) < 0) {
    return NO;
  }

  ssize_t rd = read(fd, buffer, sizeof(buffer));
  if (rd != (ssize_t)sizeof(buffer)) {
    return NO;
  }

  return AppImageSuperblockLooksValid(buffer, sizeof(buffer), fileSize, offset);
}

static off_t AppImageFindSquashfsOffsetViaElfSize(NSString *path)
{
  struct stat st;
  int fd;
  off_t elfSize = AppImageElfFileSize([path fileSystemRepresentation]);

  if (elfSize <= 0) {
    return 0;
  }

  fd = open([path fileSystemRepresentation], O_RDONLY);
  if (fd < 0) {
    return 0;
  }

  if (fstat(fd, &st) != 0) {
    close(fd);
    return 0;
  }

  if (AppImageValidateSquashfsOffset(fd, elfSize, (off_t)st.st_size)) {
    close(fd);
    return elfSize;
  }

  close(fd);
  return 0;
}

static off_t AppImageFindSquashfsOffsetByScan(NSString *path)
{
  struct stat st;
  int fd = open([path fileSystemRepresentation], O_RDONLY);
  if (fd < 0) {
    return 0;
  }

  if (fstat(fd, &st) != 0) {
    close(fd);
    return 0;
  }

  off_t fileSize = (off_t)st.st_size;
  const off_t step = 4096;
  unsigned char buffer[sizeof(sqfs_super_t)];
  off_t offset = 0;

  for (off_t candidate = 0; candidate + (off_t)sizeof(buffer) <= fileSize; candidate += step) {
    if (lseek(fd, candidate, SEEK_SET) < 0) {
      break;
    }
    ssize_t rd = read(fd, buffer, sizeof(buffer));
    if (rd != (ssize_t)sizeof(buffer)) {
      break;
    }
    if (AppImageSuperblockLooksValid(buffer, sizeof(buffer), fileSize, candidate)) {
      offset = candidate;
      break;
    }
  }

  close(fd);
  return offset;
}

static NSString *AppImageSanitizeInnerPath(NSString *path)
{
  if (path == nil) {
    return nil;
  }

  if ([path hasPrefix:@"/"]) {
    return [path substringFromIndex:1];
  }

  return path;
}

static NSData *AppImageReadFileDataFromInode(sqfs_data_reader_t *data_reader,
                                             sqfs_dir_reader_t *dir_reader,
                                             const sqfs_inode_generic_t *inode,
                                             BOOL fragmentTableReady)
{
  sqfs_u64 size = 0;

  if (inode == NULL) {
    return nil;
  }

  if (inode->base.type == SQFS_INODE_FILE) {
    if (inode->data.file.fragment_index != 0xffffffff && !fragmentTableReady) {
      return nil;
    }
    size = inode->data.file.file_size;
  } else if (inode->base.type == SQFS_INODE_EXT_FILE) {
    if (inode->data.file_ext.fragment_idx != 0xffffffff && !fragmentTableReady) {
      return nil;
    }
    size = inode->data.file_ext.file_size;
  } else if (inode->base.type == SQFS_INODE_SLINK ||
             inode->base.type == SQFS_INODE_EXT_SLINK) {
    sqfs_u32 target_size = (inode->base.type == SQFS_INODE_SLINK)
                           ? inode->data.slink.target_size
                           : inode->data.slink_ext.target_size;
    if (target_size > 0) {
      char *target = calloc(1, target_size + 1);
      if (target != NULL) {
        memcpy(target, inode->extra, target_size);
        target[target_size] = '\0';
        NSString *targetPath = AppImageSanitizeInnerPath([NSString stringWithUTF8String: target]);
        sqfs_inode_generic_t *resolved = NULL;
        if (targetPath && sqfs_dir_reader_find_by_path(dir_reader,
                                                       NULL,
                                                       [targetPath UTF8String],
                                                       &resolved) == 0) {
          NSData *resolvedData = AppImageReadFileDataFromInode(data_reader,
                                                               dir_reader,
                                                               resolved,
                                                               fragmentTableReady);
          sqfs_free(resolved);
          free(target);
          return resolvedData;
        }
        free(target);
      }
    }
    return nil;
  } else {
    return nil;
  }

  if (size == 0 || size > UINT32_MAX) {
    return nil;
  }

  void *buffer = malloc((size_t)size);
  if (buffer == NULL) {
    return nil;
  }

  sqfs_s32 rd = sqfs_data_reader_read(data_reader,
                                      inode,
                                      0,
                                      buffer,
                                      (sqfs_u32)size);
  if (rd < 0 || (sqfs_u64)rd != size) {
    free(buffer);
    return nil;
  }

  return [NSData dataWithBytesNoCopy: buffer length: (NSUInteger)size freeWhenDone: YES];
}

static BOOL AppImageInodeNeedsFragmentTable(const sqfs_inode_generic_t *inode)
{
  if (inode == NULL) {
    return NO;
  }

  if (inode->base.type == SQFS_INODE_FILE) {
    return inode->data.file.fragment_index != 0xffffffff;
  }
  if (inode->base.type == SQFS_INODE_EXT_FILE) {
    return inode->data.file_ext.fragment_idx != 0xffffffff;
  }
  return NO;
}

/* Extracts the top-level regular files of the SquashFS payload of an AppImage.
 * The sqfs_file_t is kept alive for the whole read and everything is released
 * before returning. */
static NSDictionary *AppImageExtractTopLevelFiles(NSString *appImagePath,
                                                  off_t offset,
                                                  NSUInteger maxSize)
{
  sqfs_super_t super;
  sqfs_compressor_config_t meta_cfg;
  sqfs_compressor_config_t data_cfg;
  sqfs_compressor_t *meta_compressor = NULL;
  sqfs_compressor_t *data_compressor = NULL;
  sqfs_dir_reader_t *dir_reader = NULL;
  sqfs_data_reader_t *data_reader = NULL;
  sqfs_inode_generic_t *root = NULL;
  sqfs_file_t *file = NULL;
  AppImageSqfsFile *fallbackFile = NULL;
  int fd = -1;
  NSString *tempSqfsPath = nil;
  BOOL fragmentTableReady = NO;
  struct stat st;
  NSMutableDictionary *result = nil;

  fd = open([appImagePath fileSystemRepresentation], O_RDONLY);
  if (fd < 0) {
    return nil;
  }

  if (fstat(fd, &st) != 0) {
    close(fd);
    return nil;
  }

  if ((off_t)st.st_size <= offset) {
    close(fd);
    return nil;
  }

  /* Copy the SquashFS payload to a temp file; fall back to reading straight
     from the AppImage fd when that fails. */
  {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *templatePath = [tempDir stringByAppendingPathComponent: @"appimage-sqfs-XXXXXX"];
    const char *tmpl = [templatePath fileSystemRepresentation];
    char *tmpPath = strdup(tmpl);
    sqfs_u64 remaining = (sqfs_u64)(st.st_size - offset);
    int outfd = -1;

    if (tmpPath != NULL) {
      outfd = mkstemp(tmpPath);
      if (outfd >= 0) {
        BOOL ok = YES;
        if (lseek(fd, offset, SEEK_SET) < 0) {
          ok = NO;
        }
        unsigned char buffer[8192];
        while (ok && remaining > 0) {
          size_t toRead = (remaining > sizeof(buffer)) ? sizeof(buffer) : (size_t)remaining;
          ssize_t rd = read(fd, buffer, toRead);
          if (rd <= 0) {
            ok = NO;
            break;
          }
          ssize_t wr = write(outfd, buffer, (size_t)rd);
          if (wr != rd) {
            ok = NO;
            break;
          }
          remaining -= (sqfs_u64)rd;
        }
        close(outfd);
        if (ok && remaining == 0) {
          tempSqfsPath = [NSString stringWithUTF8String: tmpPath];
        } else {
          unlink(tmpPath);
        }
      }
      free(tmpPath);
    }
  }

  if (tempSqfsPath != nil) {
    file = sqfs_open_file([tempSqfsPath fileSystemRepresentation], SQFS_FILE_OPEN_READ_ONLY);
    if (file == NULL) {
      [[NSFileManager defaultManager] removeFileAtPath: tempSqfsPath handler: nil];
      tempSqfsPath = nil;
    }
  }

  if (file == NULL) {
    fallbackFile = AppImageSqfsFileCreate(fd, offset, (sqfs_u64)(st.st_size - offset));
    if (fallbackFile == NULL) {
      close(fd);
      return nil;
    }
    file = (sqfs_file_t *)fallbackFile;
    fd = -1; /* the fd is now owned by fallbackFile */
  }

  if (sqfs_super_read(&super, file) != 0) {
    goto cleanup;
  }

  memset(&meta_cfg, 0, sizeof(meta_cfg));
  if (sqfs_compressor_config_init(&meta_cfg,
                                  (SQFS_COMPRESSOR)super.compression_id,
                                  SQFS_META_BLOCK_SIZE,
                                  0) != 0) {
    goto cleanup;
  }
  meta_cfg.flags |= SQFS_COMP_FLAG_UNCOMPRESS;
  if (sqfs_compressor_create(&meta_cfg, &meta_compressor) != 0) {
    goto cleanup;
  }

  memset(&data_cfg, 0, sizeof(data_cfg));
  if (sqfs_compressor_config_init(&data_cfg,
                                  (SQFS_COMPRESSOR)super.compression_id,
                                  super.block_size,
                                  0) != 0) {
    goto cleanup;
  }
  data_cfg.flags |= SQFS_COMP_FLAG_UNCOMPRESS;
  if (sqfs_compressor_create(&data_cfg, &data_compressor) != 0) {
    goto cleanup;
  }

  if ((super.flags & SQFS_FLAG_COMPRESSOR_OPTIONS)) {
    if (meta_compressor->read_options != NULL) {
      meta_compressor->read_options(meta_compressor, file);
    }
    if (data_compressor->read_options != NULL) {
      data_compressor->read_options(data_compressor, file);
    }
  }

  dir_reader = sqfs_dir_reader_create(&super, meta_compressor, file, 0);
  if (dir_reader == NULL) {
    goto cleanup;
  }

  data_reader = sqfs_data_reader_create(file, super.block_size, data_compressor, 0);
  if (data_reader == NULL) {
    goto cleanup;
  }

  if (super.fragment_entry_count > 0 && !fragmentTableReady) {
    if (sqfs_data_reader_load_fragment_table(data_reader, &super) == 0) {
      fragmentTableReady = YES;
    }
  }

  if (sqfs_dir_reader_get_root_inode(dir_reader, &root) != 0) {
    root = NULL;
    goto cleanup;
  }

  if (sqfs_dir_reader_open_dir(dir_reader, root, SQFS_DIR_OPEN_NO_DOT_ENTRIES) != 0) {
    goto cleanup;
  }

  result = [NSMutableDictionary dictionary];
  for (;;) {
    sqfs_dir_entry_t *entry = NULL;
    sqfs_inode_generic_t *fileInode = NULL;
    if (sqfs_dir_reader_read(dir_reader, &entry) != 0) {
      break;
    }

    if (entry != NULL) {
      NSUInteger nameLen = (NSUInteger)entry->size + 1;
      NSString *name = [[[NSString alloc] initWithBytes:entry->name
                                                 length:nameLen
                                               encoding:NSUTF8StringEncoding]
                        autorelease];
      if (name != nil && [name hasPrefix:@"."] == NO) {
        if (sqfs_dir_reader_get_inode(dir_reader, &fileInode) == 0) {
          BOOL isFile = (fileInode->base.type == SQFS_INODE_FILE
                         || fileInode->base.type == SQFS_INODE_EXT_FILE
                         || fileInode->base.type == SQFS_INODE_SLINK
                         || fileInode->base.type == SQFS_INODE_EXT_SLINK);
          if (isFile) {
            if (AppImageInodeNeedsFragmentTable(fileInode) && !fragmentTableReady) {
              if (sqfs_data_reader_load_fragment_table(data_reader, &super) == 0) {
                fragmentTableReady = YES;
              }
            }
            sqfs_u64 fileSize = 0;
            if (fileInode->base.type == SQFS_INODE_FILE) {
              fileSize = fileInode->data.file.file_size;
            } else if (fileInode->base.type == SQFS_INODE_EXT_FILE) {
              fileSize = fileInode->data.file_ext.file_size;
            }
            if (maxSize == 0 || fileSize <= maxSize) {
              NSData *data = AppImageReadFileDataFromInode(data_reader, dir_reader,
                                                           fileInode, fragmentTableReady);
              if (data != nil) {
                [result setObject:data forKey:name];
              }
            }
          }
          sqfs_free(fileInode);
        }
      }
      sqfs_free(entry);
    }
  }

cleanup:
  if (root) sqfs_free(root);
  if (data_reader) sqfs_destroy(data_reader);
  if (dir_reader) sqfs_destroy(dir_reader);
  if (data_compressor) sqfs_destroy(data_compressor);
  if (meta_compressor) sqfs_destroy(meta_compressor);
  if (file) sqfs_destroy(file);
  if (fd >= 0) close(fd);
  if (tempSqfsPath != nil) {
    [[NSFileManager defaultManager] removeFileAtPath: tempSqfsPath handler: nil];
  }

  return result;
}

@implementation AppImageReader

+ (BOOL)looksLikeAppImage:(NSString *)path
{
  return AppImageHasType2Magic([path fileSystemRepresentation]);
}

+ (NSDictionary *)topLevelFilesInAppImage:(NSString *)path
                                  maxSize:(NSUInteger)maxSize
{
  off_t offset = 0;

  if (!AppImageHasType2Magic([path fileSystemRepresentation])) {
    return nil;
  }

  offset = AppImageFindSquashfsOffsetViaElfSize(path);
  if (offset == 0) {
    offset = AppImageFindSquashfsOffsetByScan(path);
  }
  if (offset == 0) {
    return nil;
  }

  return AppImageExtractTopLevelFiles(path, offset, maxSize);
}

@end

#else  /* !HAVE_LIBSQUASHFS */

/* libsquashfs is unavailable: AppImage contents cannot be read, so AppImage
   applications are simply not registered on this platform. */
@implementation AppImageReader

+ (BOOL)looksLikeAppImage:(NSString *)path
{
  return NO;
}

+ (NSDictionary *)topLevelFilesInAppImage:(NSString *)path
                                  maxSize:(NSUInteger)maxSize
{
  return nil;
}

@end

#endif  /* HAVE_LIBSQUASHFS */
