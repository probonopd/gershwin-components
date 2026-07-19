/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SystemInfo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/sysinfo.h>
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
#include <sys/sysctl.h>
#include <sys/time.h>
#endif

@implementation SystemInfo

+ (NSString *)processorName
{
#if defined(__linux__)
	FILE *fp = fopen("/proc/cpuinfo", "r");
	if (!fp) return @"Unknown";

	char line[512];
	NSString *name = nil;
	while (fgets(line, sizeof(line), fp)) {
		size_t len = strlen(line);
		if (len == 0) continue;
		if (strncmp(line, "model name", 10) == 0 || strncmp(line, "Model name", 10) == 0) {
			char *p = strchr(line, ':');
			if (p) {
				p++;
				while (*p == ' ' || *p == '\t') p++;
				char *end = strpbrk(p, "\n\r");
				if (end) *end = '\0';
				name = [NSString stringWithUTF8String:p];
				break;
			}
		}
	}
	fclose(fp);
	return (name && [name length] > 0) ? name : @"Unknown";
#elif defined(__FreeBSD__)
	char buf[256];
	size_t len = sizeof(buf);
	if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) {
		return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#elif defined(__NetBSD__)
	char buf[256];
	size_t len = sizeof(buf);
	if (sysctlbyname("machdep.cpu_brand", buf, &len, NULL, 0) == 0) {
		NSString *s = [NSString stringWithUTF8String:buf];
		if ([s length] > 0) return s;
	}
	len = sizeof(buf);
	if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) {
		return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	char buf[256];
	size_t len = sizeof(buf);
	int mib[2] = {CTL_HW, HW_MODEL};
	if (sysctl(mib, 2, buf, &len, NULL, 0) == 0) {
		return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)processorCount
{
	long n = sysconf(_SC_NPROCESSORS_ONLN);
	if (n <= 0) return @"Unknown";
	NSString *label = (n == 1) ? @"Processor" : @"Processors";
	return [NSString stringWithFormat:@"%ld %@", n, label];
}

+ (NSString *)cpuArchitecture
{
	struct utsname buf;
	if (uname(&buf) == 0)
		return [NSString stringWithUTF8String:buf.machine];
	return @"Unknown";
}

+ (NSString *)totalMemory
{
#if defined(__linux__)
	struct sysinfo info;
	if (sysinfo(&info) == 0) {
		double gb = (double) info.totalram / (1024.0 * 1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.2f GB", gb];
	}
	return @"Unknown";
#elif defined(__FreeBSD__)
	unsigned long long physmem = 0;
	size_t len = sizeof(physmem);
	if (sysctlbyname("hw.physmem", &physmem, &len, NULL, 0) == 0) {
		double gb = (double) physmem / (1024.0 * 1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.2f GB", gb];
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	unsigned long long physmem = 0;
	size_t len = sizeof(physmem);
	int mib[2] = {CTL_HW, HW_PHYSMEM};
	if (sysctl(mib, 2, &physmem, &len, NULL, 0) == 0) {
		double gb = (double) physmem / (1024.0 * 1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.2f GB", gb];
	}
	return @"Unknown";
#elif defined(__NetBSD__)
	uint64_t physmem = 0;
	size_t len = sizeof(physmem);
	if (sysctlbyname("hw.physmem64", &physmem, &len, NULL, 0) == 0) {
		double gb = (double) physmem / (1024.0 * 1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.2f GB", gb];
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)kernelVersion
{
	struct utsname buf;
	if (uname(&buf) == 0)
		return [NSString stringWithUTF8String:buf.release];
	return @"Unknown";
}

+ (NSString *)kernelName
{
	struct utsname buf;
	if (uname(&buf) == 0) {
		NSString *s = [NSString stringWithUTF8String:buf.sysname];
		if ([s length] > 0)
			return [NSString stringWithFormat:@"%@%@",
				[[s substringToIndex:1] uppercaseString],
				([s length] > 1 ? [s substringFromIndex:1] : @"")];
		return s;
	}
	return @"Unknown";
}

+ (NSString *)distributionName
{
#if defined(__linux__)
	FILE *fp = fopen("/etc/os-release", "r");
	if (!fp) fp = fopen("/etc/lsb-release", "r");
	if (!fp) return @"Gershwin";

	char line[256];
	NSString *name = nil;
	while (fgets(line, sizeof(line), fp)) {
		if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
			char *p = line + 12; if (*p == '"') p++;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			name = [NSString stringWithUTF8String:p];
			break;
		} else if (strncmp(line, "DISTRIB_DESCRIPTION=", 20) == 0) {
			char *p = line + 20; if (*p == '"') p++;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			name = [NSString stringWithUTF8String:p];
			break;
		}
	}
	fclose(fp);
	return name ? name : @"Gershwin";
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = fopen("/etc/os-release", "r");
	if (fp) {
		char line[256];
		NSString *name = nil;
		while (fgets(line, sizeof(line), fp)) {
			if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
				char *p = line + 12; if (*p == '"') p++;
				char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
				name = [NSString stringWithUTF8String:p];
				break;
			}
		}
		fclose(fp);
		if (name) return name;
	}
	{
		struct utsname buf;
		if (uname(&buf) == 0) {
			return [NSString stringWithFormat:@"%s %s", buf.sysname, buf.release];
		}
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)systemUptime
{
#if defined(__linux__)
	struct sysinfo info;
	if (sysinfo(&info) == 0) {
		unsigned long d = info.uptime / 86400;
		unsigned long h = (info.uptime / 3600) % 24;
		unsigned long m = (info.uptime / 60) % 60;
		unsigned long s = info.uptime % 60;
		NSMutableString *r = [NSMutableString string];
		if (d > 0) [r appendFormat:@"%lu day%@, ", d, (d == 1) ? @"" : @"s"];
		[r appendFormat:@"%lu:%02lu:%02lu", h, m, s];
		return r;
	}
	return @"Unknown";
#elif defined(__FreeBSD__) || defined(__NetBSD__)
	struct timeval boottime;
	size_t len = sizeof(boottime);
	if (sysctlbyname("kern.boottime", &boottime, &len, NULL, 0) == 0) {
		struct timeval now;
		if (gettimeofday(&now, NULL) == 0) {
			long uptime = now.tv_sec - boottime.tv_sec;
			if (uptime < 0) uptime = 0;
			unsigned long d = uptime / 86400;
			unsigned long h = (uptime / 3600) % 24;
			unsigned long m = (uptime / 60) % 60;
			unsigned long s = uptime % 60;
			NSMutableString *r = [NSMutableString string];
			if (d > 0) [r appendFormat:@"%lu day%@, ", d, (d == 1) ? @"" : @"s"];
			[r appendFormat:@"%lu:%02lu:%02lu", h, m, s];
			return r;
		}
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	struct timeval boottime;
	size_t len = sizeof(boottime);
	int mib[2] = {CTL_KERN, KERN_BOOTTIME};
	if (sysctl(mib, 2, &boottime, &len, NULL, 0) == 0) {
		struct timeval now;
		if (gettimeofday(&now, NULL) == 0) {
			long uptime = now.tv_sec - boottime.tv_sec;
			if (uptime < 0) uptime = 0;
			unsigned long d = uptime / 86400;
			unsigned long h = (uptime / 3600) % 24;
			unsigned long m = (uptime / 60) % 60;
			unsigned long s = uptime % 60;
			NSMutableString *r = [NSMutableString string];
			if (d > 0) [r appendFormat:@"%lu day%@, ", d, (d == 1) ? @"" : @"s"];
			[r appendFormat:@"%lu:%02lu:%02lu", h, m, s];
			return r;
		}
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)hostname
{
	char buf[256];
	if (gethostname(buf, sizeof(buf)) == 0)
		return [NSString stringWithUTF8String:buf];
	return @"Unknown";
}

+ (NSString *)userName
{
	const char *u = getenv("USER");
	return u ? [NSString stringWithUTF8String:u] : @"Unknown";
}

+ (NSString *)osVersion
{
#if defined(__linux__)
	FILE *fp = fopen("/etc/os-release", "r");
	if (!fp) fp = fopen("/etc/lsb-release", "r");
	if (!fp) return @"Unknown";

	char line[256];
	NSString *ver = nil;
	while (fgets(line, sizeof(line), fp)) {
		if (strncmp(line, "VERSION_ID=", 11) == 0) {
			char *p = line + 11; if (*p == '"') p++;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			ver = [NSString stringWithUTF8String:p];
			break;
		} else if (strncmp(line, "DISTRIB_RELEASE=", 16) == 0) {
			char *p = line + 16; if (*p == '"') p++;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			ver = [NSString stringWithUTF8String:p];
			break;
		}
	}
	fclose(fp);
	return ver ? ver : @"Unknown";
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	struct utsname buf;
	if (uname(&buf) == 0) {
		return [NSString stringWithUTF8String:buf.release];
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)swapInfo
{
#if defined(__linux__)
	struct sysinfo info;
	if (sysinfo(&info) == 0) {
		if (info.totalswap == 0) return @"None";
		double mb = (double) info.totalswap / (1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.0f MB", mb];
	}
	return @"Unknown";
#elif defined(__FreeBSD__)
	unsigned long long swaptotal = 0;
	size_t len = sizeof(swaptotal);
	if (sysctlbyname("vm.swap_total", &swaptotal, &len, NULL, 0) == 0) {
		if (swaptotal == 0) return @"None";
		double mb = (double) swaptotal / (1024.0 * 1024.0);
		return [NSString stringWithFormat:@"%.0f MB", mb];
	}
	return @"Unknown";
#elif defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = popen("swapctl -l 2>/dev/null", "r");
	if (!fp) return @"Unknown";

	char line[512];
	unsigned long long total = 0;
	while (fgets(line, sizeof(line), fp)) {
		if (strlen(line) == 0) continue;
		unsigned long long blocks = 0;
		int n = sscanf(line, "%*s %*s %llu", &blocks);
		if (n == 1) total += blocks;
	}
	pclose(fp);
	if (total == 0) return @"None";
	/* Convert 512-byte blocks to MB */
	double mb = (double) total * 512.0 / (1024.0 * 1024.0);
	return [NSString stringWithFormat:@"%.0f MB", mb];
#else
	return @"Unknown";
#endif
}

+ (NSArray *)pciDevices
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("lspci -mm 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/lspci -mm 2>/dev/null", "r");
#elif defined(__FreeBSD__)
	FILE *fp = popen("pciconf -l 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/pciconf -l 2>/dev/null", "r");
#elif defined(__NetBSD__)
	FILE *fp = popen("pcictl pci0 list 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/pcictl pci0 list 2>/dev/null", "r");
#elif defined(__OpenBSD__)
	FILE *fp = popen("pcidump -v 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/pcidump -v 2>/dev/null", "r");
#else
	FILE *fp = NULL;
#endif
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0) {
			[a addObject:[NSString stringWithUTF8String:line]];
		}
	}
	pclose(fp);
	return a;
}

+ (NSArray *)usbDevices
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("lsusb 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/lsusb 2>/dev/null", "r");
#elif defined(__FreeBSD__) || defined(__NetBSD__)
	FILE *fp = popen("usbdevs -v 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/sbin/usbdevs -v 2>/dev/null", "r");
#elif defined(__OpenBSD__)
	FILE *fp = popen("usbdevs 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/usbdevs 2>/dev/null", "r");
#else
	FILE *fp = NULL;
#endif
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0) {
			[a addObject:[NSString stringWithUTF8String:line]];
		}
	}
	pclose(fp);
	return a;
}

+ (NSArray *)storageDevices
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -n 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -n 2>/dev/null", "r");
#elif defined(__FreeBSD__)
	FILE *fp = popen("geom disk list 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/geom disk list 2>/dev/null", "r");
#elif defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = popen("sysctl hw.disknames 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/sysctl hw.disknames 2>/dev/null", "r");
#else
	FILE *fp = NULL;
#endif
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0) {
			[a addObject:[NSString stringWithUTF8String:line]];
		}
	}
	pclose(fp);
	return a;
}

+ (NSArray *)mountedFilesystems
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("LC_ALL=C df -h -T 2>/dev/null", "r");
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = popen("LC_ALL=C df -h 2>/dev/null", "r");
#else
	FILE *fp = NULL;
#endif
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		NSString *s = [NSString stringWithUTF8String:line];
		if ([s length] > 0 && ![s hasPrefix:@"Filesystem"]) {
			[a addObject:s];
		}
	}
	pclose(fp);
	return a;
}

+ (NSArray *)networkInterfaces
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("ip -br addr show 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/ip -br addr show 2>/dev/null", "r");
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = popen("ifconfig -a 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/ifconfig -a 2>/dev/null", "r");
#else
	FILE *fp = NULL;
#endif
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0) {
			[a addObject:[NSString stringWithUTF8String:line]];
		}
	}
	pclose(fp);
	return a;
}

+ (NSArray *)inputDevices
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = fopen("/proc/bus/input/devices", "r");
	if (!fp) return a;

	char line[4096];
	NSString *name = nil;
	while (fgets(line, sizeof(line), fp)) {
		if (strncmp(line, "N: Name=", 8) == 0) {
			char *p = line + 9;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			name = [NSString stringWithUTF8String:p];
		} else if (strncmp(line, "H: Handlers=", 12) == 0 && name) {
			char *p = line + 12;
			char *end = strpbrk(p, "\n\r"); if (end) *end = '\0';
			[a addObject:[NSString stringWithFormat:@"%@ (%@)",
				name, [NSString stringWithUTF8String:p]]];
			name = nil;
		}
	}
	if (name) {
		[a addObject:name];
	}
	fclose(fp);
#elif defined(__FreeBSD__)
	FILE *fp = fopen("/dev/input", "r");
	if (fp) {
		[a addObject:@"(evdev devices present)"];
		fclose(fp);
	}
#else
	/* No standard input device enumeration on NetBSD/OpenBSD */
#endif
	return a;
}

+ (NSArray *)inputDevicePairs
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = fopen("/proc/bus/input/devices", "r");
	if (!fp) return pairs;

	char line[4096];
	NSMutableString *name = nil;
	NSString *phys = nil;
	NSMutableString *handlers = nil;
	while (fgets(line, sizeof(line), fp)) {
		if (line[0] == '\n' || line[0] == '\0') {
			if (name) {
				[pairs addObject:@[@"Device:", name]];
				if (phys)
					[pairs addObject:@[@"Phys:", phys]];
				if (handlers)
					[pairs addObject:@[@"Handlers:", handlers]];
				[pairs addObject:@[@"", @""]];
			}
			name = nil; phys = nil; handlers = nil;
		} else if (strncmp(line, "N: Name=", 8) == 0) {
			char *p = line + 9;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			name = [NSMutableString stringWithUTF8String:p];
		} else if (strncmp(line, "P: Phys=", 8) == 0) {
			char *p = line + 8;
			char *end = strpbrk(p, "\"\n\r"); if (end) *end = '\0';
			phys = [NSString stringWithUTF8String:p];
		} else if (strncmp(line, "H: Handlers=", 12) == 0) {
			char *p = line + 12;
			char *end = strpbrk(p, "\n\r"); if (end) *end = '\0';
			handlers = [NSMutableString stringWithUTF8String:p];
		}
	}
	if (name) {
		[pairs addObject:@[@"Device:", name]];
		if (phys) [pairs addObject:@[@"Phys:", phys]];
		if (handlers) {
			[pairs addObject:@[@"Handlers:", handlers]];
		}
	}
	fclose(fp);
#elif defined(__FreeBSD__)
	FILE *fp = fopen("/dev/input", "r");
	if (fp) {
		[pairs addObject:@[@"Status:", @"evdev subsystem present"]];
		fclose(fp);
	}
#else
	/* No standard input device enumeration on NetBSD/OpenBSD */
#endif
	return pairs;
}

+ (NSString *)displayInfo
{
	FILE *fp = popen("xrandr --query 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/xrandr --query 2>/dev/null", "r");
	if (!fp) return @"Unknown";

	NSMutableString *s = [NSMutableString string];
	char line[256];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[s appendFormat:@"%s\n", line];
	}
	pclose(fp);
	return [s length] > 0 ? s : @"Unknown";
}

+ (NSArray *)displayPairs
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *drmPath = @"/sys/class/drm";
	NSArray *drmEnts = [fm contentsOfDirectoryAtPath:drmPath error:NULL];

	/* Collect GPU card names (card0, card1, etc.) */
	NSMutableArray *cards = [NSMutableArray array];
	for (NSString *ent in drmEnts) {
		if ([ent hasPrefix:@"card"] && [ent rangeOfString:@"-"].location == NSNotFound)
			[cards addObject:ent];
	}
	[cards sortUsingSelector:@selector(compare:)];

	/* Build a pci address -> GPU name map from lspci */
	NSMutableDictionary *gpuNames = [NSMutableDictionary dictionary];
	NSMutableDictionary *gpuDrivers = [NSMutableDictionary dictionary];
	FILE *fp = popen("LC_ALL=C lspci -k 2>/dev/null", "r");
	if (fp) {
		char line[512];
		NSString *currentAddr = nil;
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			NSString *sl = [NSString stringWithUTF8String:line];
			if ([sl length] == 0) continue;
			/* Lines starting with whitespace are continuation */
			if ([sl characterAtIndex:0] == '\t' || [sl characterAtIndex:0] == ' ') {
				if ([sl rangeOfString:@"Kernel driver in use:"].location != NSNotFound) {
					NSRange r = [sl rangeOfString:@": "];
					if (r.location != NSNotFound && currentAddr) {
						NSString *drv = [[sl substringFromIndex:r.location + 2]
							stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
						gpuDrivers[currentAddr] = drv;
					}
				}
			} else {
				/* Non-continuation line: "XXXX:XX:XX.X Class: Device Name" */
				NSScanner *sc = [NSScanner scannerWithString:sl];
				NSString *addr;
				if ([sc scanUpToString:@" " intoString:&addr] && addr) {
					NSString *rest = [[sl substringFromIndex:[sc scanLocation]]
						stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
					if ([rest hasPrefix:@"VGA compatible controller"] ||
					    [rest hasPrefix:@"3D controller"] ||
					    [rest hasPrefix:@"Display controller"]) {
						currentAddr = addr;
						/* Extract device name after the colon if present */
						NSRange colonR = [rest rangeOfString:@": "];
						if (colonR.location != NSNotFound) {
							gpuNames[addr] = [[rest substringFromIndex:colonR.location + 2]
								stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
						} else {
							gpuNames[addr] = rest;
						}
					} else {
						currentAddr = nil;
					}
				}
			}
		}
		pclose(fp);
	}

	for (NSString *card in cards) {
		NSString *cardPath = [drmPath stringByAppendingPathComponent:card];
		NSString *devicePath = [cardPath stringByAppendingPathComponent:@"device"];

		/* Read PCI address from device symlink */
		NSString *gpuName = nil;
		NSString *driverName = nil;
		char linkBuf[256];
		ssize_t linkLen = readlink([devicePath UTF8String], linkBuf, sizeof(linkBuf) - 1);
		if (linkLen > 0) {
			linkBuf[linkLen] = '\0';
			char *pciAddr = strstr(linkBuf, "pci0000:");
			if (pciAddr) {
				pciAddr = strchr(pciAddr, '/');
				if (pciAddr) {
					pciAddr++;
					char *slash = strchr(pciAddr, '/');
					if (slash) *slash = '\0';
					NSString *addr = [NSString stringWithUTF8String:pciAddr];
					gpuName = gpuNames[addr];
					driverName = gpuDrivers[addr];
				}
			}
		}
		/* Fallback driver from sysfs driver symlink */
		if (!driverName) {
			NSString *driverLink = [devicePath stringByAppendingPathComponent:@"driver"];
			char drvBuf[256];
			ssize_t drvLen = readlink([driverLink UTF8String], drvBuf, sizeof(drvBuf) - 1);
			if (drvLen > 0) {
				drvBuf[drvLen] = '\0';
				char *slash = strrchr(drvBuf, '/');
				driverName = [NSString stringWithUTF8String:slash ? slash + 1 : drvBuf];
			}
		}

		[pairs addObject:@[@"GPU:", gpuName ? gpuName : card]];
		if (driverName)
			[pairs addObject:@[@"Driver:", driverName]];

		/* Find connected connectors for this card */
		BOOL addedConnector = NO;
		for (NSString *ent in drmEnts) {
			NSString *prefix = [card stringByAppendingString:@"-"];
			if (![ent hasPrefix:prefix]) continue;

			NSString *connPath = [drmPath stringByAppendingPathComponent:ent];
			NSString *statusPath = [connPath stringByAppendingPathComponent:@"status"];
			NSString *status = [NSString stringWithContentsOfFile:statusPath
			                                             encoding:NSUTF8StringEncoding error:NULL];
			status = [status stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (![status isEqualToString:@"connected"]) continue;

			NSString *edidPath = [connPath stringByAppendingPathComponent:@"edid"];
			NSData *edid = [NSData dataWithContentsOfFile:edidPath];
			if (!edid || [edid length] < 128) continue;

			const unsigned char *b = [edid bytes];

			unsigned short mfw = (b[8] << 8) | b[9];
			char m1 = ((mfw >> 10) & 0x1F) + 'A' - 1;
			char m2 = ((mfw >> 5) & 0x1F) + 'A' - 1;
			char m3 = (mfw & 0x1F) + 'A' - 1;
			NSString *mfg = [NSString stringWithFormat:@"%c%c%c", m1, m2, m3];

			unsigned short pc = b[10] | (b[11] << 8);
			NSString *prod = [NSString stringWithFormat:@"%04X", pc];

			NSString *name = nil;
			char nbuf[14];
			for (int i = 0; i < 4; i++) {
				const unsigned char *blk = b + 54 + i * 18;
				if (blk[0] == 0 && blk[1] == 0 && blk[2] == 0 && blk[3] == 0xFC) {
					memcpy(nbuf, blk + 5, 13);
					nbuf[13] = '\0';
					name = [NSString stringWithUTF8String:nbuf];
					name = [name stringByTrimmingCharactersInSet:
						[NSCharacterSet whitespaceAndNewlineCharacterSet]];
					break;
				}
			}

			NSString *sz = [NSString stringWithFormat:@"%d x %d cm", b[21], b[22]];
			NSString *connLabel = [ent substringFromIndex:[prefix length]];

			[pairs addObject:@[@"", @""]];
			[pairs addObject:@[[NSString stringWithFormat:@"Port %@:", connLabel], @""]];
			if (name) [pairs addObject:@[@"  Monitor:", name]];
			[pairs addObject:@[@"  Manufacturer:", mfg]];
			[pairs addObject:@[@"  Product:", prod]];
			[pairs addObject:@[@"  Size:", sz]];
			addedConnector = YES;
		}
		if (!addedConnector) {
			[pairs addObject:@[@"", @"(no connected displays)"]];
		}
		[pairs addObject:@[@"", @""]];
	}

	if ([pairs count] == 0) {
		NSString *raw = [self displayInfo];
		if ([raw length] > 0 && ![raw isEqualToString:@"Unknown"]) {
			NSArray *lines = [raw componentsSeparatedByString:@"\n"];
			for (NSString *line in lines) {
				if ([line length] > 0)
					[pairs addObject:@[@"", line]];
			}
		}
	}

	/* Append OpenGL / acceleration info from glxinfo */
	FILE *glfp = popen("LC_ALL=C glxinfo -B 2>/dev/null", "r");
	if (!glfp) glfp = popen("LC_ALL=C DISPLAY=:0 glxinfo -B 2>/dev/null", "r");
	if (glfp) {
		[pairs addObject:@[@"", @""]];
		[pairs addObject:@[@"OpenGL:", @""]];
		char line[256];
		while (fgets(line, sizeof(line), glfp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) == 0) continue;
			NSString *cl = [NSString stringWithUTF8String:line];
			NSRange r = [cl rangeOfString:@": "];
			if (r.location == NSNotFound) continue;
			NSString *val = [[cl substringFromIndex:r.location + 2]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([cl hasPrefix:@"direct rendering:"])
				[pairs addObject:@[@"  Direct Rendering:", val]];
			else if ([cl hasPrefix:@"OpenGL vendor string:"])
				[pairs addObject:@[@"  Vendor:", val]];
			else if ([cl hasPrefix:@"OpenGL renderer string:"])
				[pairs addObject:@[@"  Renderer:", val]];
			else if ([cl hasPrefix:@"OpenGL version string:"])
				[pairs addObject:@[@"  Version:", val]];
			else if ([cl hasPrefix:@"OpenGL shading language version string:"])
				[pairs addObject:@[@"  GLSL Version:", val]];
		}
		pclose(glfp);
	}
#else
	NSString *raw = [self displayInfo];
	if ([raw length] > 0 && ![raw isEqualToString:@"Unknown"]) {
		NSArray *lines = [raw componentsSeparatedByString:@"\n"];
		for (NSString *line in lines) {
			if ([line length] > 0)
				[pairs addObject:@[@"", line]];
		}
	}
	FILE *glfp = popen("glxinfo -B 2>/dev/null", "r");
	if (glfp) {
		[pairs addObject:@[@"", @""]];
		[pairs addObject:@[@"OpenGL:", @""]];
		char line[256];
		while (fgets(line, sizeof(line), glfp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) == 0) continue;
			NSString *cl = [NSString stringWithUTF8String:line];
			NSRange r = [cl rangeOfString:@": "];
			if (r.location == NSNotFound) continue;
			NSString *val = [[cl substringFromIndex:r.location + 2]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([cl hasPrefix:@"direct rendering:"])
				[pairs addObject:@[@"  Direct Rendering:", val]];
			else if ([cl hasPrefix:@"OpenGL vendor string:"])
				[pairs addObject:@[@"  Vendor:", val]];
			else if ([cl hasPrefix:@"OpenGL renderer string:"])
				[pairs addObject:@[@"  Renderer:", val]];
			else if ([cl hasPrefix:@"OpenGL version string:"])
				[pairs addObject:@[@"  Version:", val]];
		}
		pclose(glfp);
	}
#endif
	return pairs;
}

+ (NSArray *)gpuInfo
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *drmPath = @"/sys/class/drm";
	NSArray *drmEnts = [fm contentsOfDirectoryAtPath:drmPath error:NULL];
	NSString *gpuName = nil;
	NSString *driverName = nil;
	if (drmEnts) {
		for (NSString *ent in drmEnts) {
			/* Skip sub-connectors like card0-eDP-1 */
			if ([ent hasPrefix:@"card"] && [ent rangeOfString:@"-"].location == NSNotFound) {
				NSString *devicePath = [[drmPath stringByAppendingPathComponent:ent]
					stringByAppendingPathComponent:@"device"];

				/* Kernel driver from symlink target */
				NSString *driverLink = [devicePath stringByAppendingPathComponent:@"driver"];
				char linkBuf[256];
				ssize_t linkLen = readlink([driverLink UTF8String], linkBuf, sizeof(linkBuf) - 1);
				if (linkLen > 0) {
					linkBuf[linkLen] = '\0';
					char *slash = strrchr(linkBuf, '/');
					driverName = [NSString stringWithUTF8String:slash ? slash + 1 : linkBuf];
				}

				break;
			}
		}
	}
	/* GPU name and fallback driver from lspci */
	FILE *fp = popen("lspci -k 2>/dev/null | grep -A3 -i 'vga\\|3d\\|display' | head -8", "r");
	if (fp) {
		char line[256];
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) == 0) continue;
			if (!gpuName && (strstr(line, "VGA") || strstr(line, "3D") || strstr(line, "Display"))) {
				const char *colon = strstr(line, ": ");
				gpuName = [NSString stringWithUTF8String:colon ? colon + 2 : line];
				gpuName = [gpuName stringByTrimmingCharactersInSet:
					[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			} else if (strstr(line, "Kernel driver in use:")) {
				const char *drv = strstr(line, ": ");
				if (drv) {
					driverName = [NSString stringWithUTF8String:drv + 2];
					driverName = [driverName stringByTrimmingCharactersInSet:
						[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				}
			}
		}
		pclose(fp);
	}
	if (gpuName)
		[pairs addObject:@[@"GPU:", gpuName]];
	if (driverName)
		[pairs addObject:@[@"Kernel Driver:", driverName]];

	/* OpenGL / acceleration info from glxinfo */
	fp = popen("glxinfo -B 2>/dev/null", "r");
	if (!fp) fp = popen("DISPLAY=:0 glxinfo -B 2>/dev/null", "r");
	if (fp) {
		char line[256];
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) == 0) continue;
			NSString *cl = [NSString stringWithUTF8String:line];
			NSRange r = [cl rangeOfString:@": "];
			if (r.location == NSNotFound) continue;
			NSString *val = [[cl substringFromIndex:r.location + 2]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([cl hasPrefix:@"direct rendering:"])
				[pairs addObject:@[@"Direct Rendering:", val]];
			else if ([cl hasPrefix:@"OpenGL vendor string:"])
				[pairs addObject:@[@"GL Vendor:", val]];
			else if ([cl hasPrefix:@"OpenGL renderer string:"])
				[pairs addObject:@[@"GL Renderer:", val]];
			else if ([cl hasPrefix:@"OpenGL version string:"])
				[pairs addObject:@[@"GL Version:", val]];
			else if ([cl hasPrefix:@"OpenGL shading language version string:"])
				[pairs addObject:@[@"GLSL Version:", val]];
		}
		pclose(fp);
	}
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	FILE *fp = popen("glxinfo -B 2>/dev/null", "r");
	if (fp) {
		char line[256];
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) == 0) continue;
			NSString *cl = [NSString stringWithUTF8String:line];
			NSRange r = [cl rangeOfString:@": "];
			if (r.location == NSNotFound) continue;
			NSString *val = [[cl substringFromIndex:r.location + 2]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([cl hasPrefix:@"direct rendering:"])
				[pairs addObject:@[@"Direct Rendering:", val]];
			else if ([cl hasPrefix:@"OpenGL vendor string:"])
				[pairs addObject:@[@"GL Vendor:", val]];
			else if ([cl hasPrefix:@"OpenGL renderer string:"])
				[pairs addObject:@[@"GL Renderer:", val]];
			else if ([cl hasPrefix:@"OpenGL version string:"])
				[pairs addObject:@[@"GL Version:", val]];
		}
		pclose(fp);
	}
#endif
	return pairs;
}

+ (NSString *)hardwareUUID
{
#if defined(__linux__)
	FILE *fp = fopen("/sys/devices/virtual/dmi/id/product_uuid", "r");
	if (!fp) return @"Unknown";

	char buf[64];
	NSString *uuid = nil;
	if (fgets(buf, sizeof(buf), fp)) {
		char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
		if (strlen(buf) > 0)
			uuid = [NSString stringWithUTF8String:buf];
	}
	fclose(fp);
	return uuid ? uuid : @"Unknown";
#elif defined(__FreeBSD__)
	char buf[64];
	size_t len = sizeof(buf);
	if (sysctlbyname("kern.hostuuid", buf, &len, NULL, 0) == 0) {
		return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#elif defined(__NetBSD__)
	char buf[64];
	size_t len = sizeof(buf);
	if (sysctlbyname("machdep.dmi.system-uuid", buf, &len, NULL, 0) == 0) {
		if (strlen(buf) > 0) return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	char buf[64];
	size_t len = sizeof(buf);
	int mib[2] = {CTL_HW, HW_UUID};
	if (sysctl(mib, 2, buf, &len, NULL, 0) == 0) {
		if (strlen(buf) > 0) return [NSString stringWithUTF8String:buf];
	}
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)bootMode
{
#if defined(__linux__)
	FILE *fp = fopen("/sys/firmware/efi", "r");
	if (fp) {
		fclose(fp);
		return @"UEFI";
	}
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/sys/firmware/devicetree/base"]) {
		NSString *model = [self systemModel];
		if ([model hasPrefix:@"Raspberry Pi"])
			return @"Raspberry Pi";
		return @"Device Tree";
	}
	return @"BIOS";
#elif defined(__FreeBSD__)
	{
		char buf[32];
		size_t len = sizeof(buf);
		if (sysctlbyname("machdep.bootmethod", buf, &len, NULL, 0) == 0) {
			NSString *s = [NSString stringWithUTF8String:buf];
			if ([s length] > 0) return s;
		}
	}
	FILE *fp = popen("mount -p 2>/dev/null | grep -q /boot/efi && echo UEFI || echo BIOS", "r");
	if (fp) {
		char buf[16];
		if (fgets(buf, sizeof(buf), fp)) {
			char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
			if (strlen(buf) > 0) {
				pclose(fp);
				return [NSString stringWithUTF8String:buf];
			}
		}
		pclose(fp);
	}
	return @"BIOS";
#elif defined(__NetBSD__)
	{
		FILE *fp = popen("mount -p 2>/dev/null | grep -q /boot/efi && echo UEFI || echo BIOS", "r");
		if (fp) {
			char buf[16];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				if (strlen(buf) > 0) {
					pclose(fp);
					return [NSString stringWithUTF8String:buf];
				}
			}
			pclose(fp);
		}
	}
	return @"BIOS";
#elif defined(__OpenBSD__)
	{
		FILE *fp = popen("mount -p 2>/dev/null | grep -q /boot/efi && echo UEFI || echo BIOS", "r");
		if (fp) {
			char buf[16];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				if (strlen(buf) > 0) {
					pclose(fp);
					return [NSString stringWithUTF8String:buf];
				}
			}
			pclose(fp);
		}
	}
	return @"BIOS";
#else
	return @"Unknown";
#endif
}

+ (NSString *)initSystem
{
#if defined(__linux__)
	{
		FILE *fp = fopen("/proc/1/comm", "r");
		if (fp) {
			char buf[64];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				fclose(fp);
				return [NSString stringWithUTF8String:buf];
			}
			fclose(fp);
		}
	}
	/* Fallback: check common init markers */
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/run/systemd/system"])
		return @"systemd";
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/etc/init.d/functions.sh"])
		return @"OpenRC";
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/sbin/runit"])
		return @"runit";
	return @"Unknown";
#elif defined(__FreeBSD__)
	return @"init";
#elif defined(__NetBSD__)
	return @"init";
#elif defined(__OpenBSD__)
	return @"init";
#else
	return @"Unknown";
#endif
}

+ (NSString *)systemModel
{
#if defined(__linux__)
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/sys/firmware/devicetree/base"]) {
		NSData *d = [NSData dataWithContentsOfFile:@"/sys/firmware/devicetree/base/model"];
		if (d) {
			NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
			if (s) {
				s = [s stringByReplacingOccurrencesOfString:@"\0" withString:@""];
				s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if ([s length] > 0) return s;
			}
		}
	}
	{
		NSString *p = [NSString stringWithContentsOfFile:@"/sys/class/dmi/id/product_name"
		                                        encoding:NSUTF8StringEncoding error:NULL];
		if (p) {
			p = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([p length] > 0) return p;
		}
	}
	return @"Unknown";
#elif defined(__FreeBSD__) || defined(__NetBSD__)
	{
		FILE *fp = popen("kenv -q smbios.system.product 2>/dev/null", "r");
		if (fp) {
			char buf[256];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				if (strlen(buf) > 0) {
					pclose(fp);
					return [NSString stringWithUTF8String:buf];
				}
			}
			pclose(fp);
		}
	}
	{
		char buf[256];
		size_t len = sizeof(buf);
		if (sysctlbyname("hw.smbios.product", buf, &len, NULL, 0) == 0) {
			if (strlen(buf) > 0) return [NSString stringWithUTF8String:buf];
		}
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)systemManufacturer
{
	NSString *model = [self systemModel];
	if (model && [model hasPrefix:@"Raspberry Pi"]) {
		return @"Raspberry Pi Ltd";
	}
#if defined(__linux__)
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/sys/firmware/devicetree/base"]) {
		return [model hasPrefix:@"Raspberry Pi"] ? @"Raspberry Pi Ltd" : @"Unknown";
	}
	{
		NSString *v = [NSString stringWithContentsOfFile:@"/sys/class/dmi/id/sys_vendor"
		                                        encoding:NSUTF8StringEncoding error:NULL];
		if (v) {
			v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([v length] > 0) return v;
		}
	}
	return @"Unknown";
#elif defined(__FreeBSD__) || defined(__NetBSD__)
	{
		FILE *fp = popen("kenv -q smbios.system.maker 2>/dev/null", "r");
		if (fp) {
			char buf[256];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				if (strlen(buf) > 0) {
					pclose(fp);
					return [NSString stringWithUTF8String:buf];
				}
			}
			pclose(fp);
		}
	}
	{
		char buf[256];
		size_t len = sizeof(buf);
		if (sysctlbyname("hw.smbios.maker", buf, &len, NULL, 0) == 0) {
			if (strlen(buf) > 0) return [NSString stringWithUTF8String:buf];
		}
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)systemSerial
{
#if defined(__linux__)
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/sys/firmware/devicetree/base"]) {
		NSData *d = [NSData dataWithContentsOfFile:@"/proc/device-tree/serial-number"];
		if (d) {
			NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
			if (s) {
				s = [s stringByReplacingOccurrencesOfString:@"\0" withString:@""];
				s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if ([s length] > 0) return s;
			}
		}
		return [self cpuInfoValueForKey:@"Serial"];
	}
	{
		NSString *s = [NSString stringWithContentsOfFile:@"/sys/class/dmi/id/product_serial"
		                                        encoding:NSUTF8StringEncoding error:NULL];
		if (s) {
			s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([s length] > 0) return s;
		}
	}
	return @"Unknown";
#elif defined(__FreeBSD__) || defined(__NetBSD__)
	{
		FILE *fp = popen("kenv -q smbios.system.serial 2>/dev/null", "r");
		if (fp) {
			char buf[256];
			if (fgets(buf, sizeof(buf), fp)) {
				char *end = strpbrk(buf, "\n\r"); if (end) *end = '\0';
				if (strlen(buf) > 0) {
					pclose(fp);
					return [NSString stringWithUTF8String:buf];
				}
			}
			pclose(fp);
		}
	}
	{
		char buf[256];
		size_t len = sizeof(buf);
		if (sysctlbyname("hw.smbios.serial", buf, &len, NULL, 0) == 0) {
			if (strlen(buf) > 0) return [NSString stringWithUTF8String:buf];
		}
	}
	return @"Unknown";
#elif defined(__OpenBSD__)
	return @"Unknown";
#else
	return @"Unknown";
#endif
}

+ (NSString *)cpuInfoValueForKey:(NSString *)key
{
	FILE *fp = fopen("/proc/cpuinfo", "r");
	if (!fp) return nil;

	char line[256];
	NSString *prefix = [key stringByAppendingString:@":"];
	while (fgets(line, sizeof(line), fp)) {
		NSString *ls = [NSString stringWithUTF8String:line];
		if ([ls hasPrefix:prefix]) {
			NSArray *parts = [ls componentsSeparatedByString:@":"];
			if ([parts count] > 1) {
				NSString *val = [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:
					[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				fclose(fp);
				return [val length] > 0 ? val : nil;
			}
		}
	}
	fclose(fp);
	return nil;
}

+ (NSArray *)audioDevices
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("aplay -l 2>/dev/null", "r");
	if (!fp) fp = popen("/usr/bin/aplay -l 2>/dev/null", "r");
	if (fp) {
		char line[4096];
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) > 0)
				[a addObject:[NSString stringWithUTF8String:line]];
		}
		pclose(fp);
	} else {
		FILE *f = fopen("/proc/asound/cards", "r");
		if (f) {
			char line[4096];
			while (fgets(line, sizeof(line), f)) {
				char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
				if (strlen(line) > 0)
					[a addObject:[NSString stringWithUTF8String:line]];
			}
			fclose(f);
		}
	}
#elif defined(__FreeBSD__)
	FILE *fp = popen("cat /dev/sndstat 2>/dev/null", "r");
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[a addObject:[NSString stringWithUTF8String:line]];
	}
	pclose(fp);
#elif defined(__NetBSD__)
	FILE *fp = popen("audiocfg list 2>/dev/null", "r");
	if (fp) {
		char line[4096];
		while (fgets(line, sizeof(line), fp)) {
			char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
			if (strlen(line) > 0)
				[a addObject:[NSString stringWithUTF8String:line]];
		}
		pclose(fp);
	}
	if ([a count] == 0) {
		fp = popen("cat /dev/sound 2>/dev/null", "r");
		if (fp) {
			char line[4096];
			while (fgets(line, sizeof(line), fp)) {
				char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
				if (strlen(line) > 0)
					[a addObject:[NSString stringWithUTF8String:line]];
			}
			pclose(fp);
		}
	}
#elif defined(__OpenBSD__)
	FILE *fp = popen("audioctl -a 2>/dev/null | head -20", "r");
	if (!fp) fp = popen("/sbin/audioctl -a 2>/dev/null | head -20", "r");
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[a addObject:[NSString stringWithUTF8String:line]];
	}
	pclose(fp);
#endif
	return a;
}

+ (NSArray *)kernelExtensions
{
	NSMutableArray *a = [NSMutableArray array];
#if defined(__linux__)
	FILE *fp = popen("lsmod 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/lsmod 2>/dev/null", "r");
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[a addObject:[NSString stringWithUTF8String:line]];
	}
	pclose(fp);
#elif defined(__FreeBSD__)
	FILE *fp = popen("kldstat 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/kldstat 2>/dev/null", "r");
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[a addObject:[NSString stringWithUTF8String:line]];
	}
	pclose(fp);
#elif defined(__NetBSD__)
	FILE *fp = popen("modstat 2>/dev/null", "r");
	if (!fp) fp = popen("/sbin/modstat 2>/dev/null", "r");
	if (!fp) return a;

	char line[4096];
	while (fgets(line, sizeof(line), fp)) {
		char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
		if (strlen(line) > 0)
			[a addObject:[NSString stringWithUTF8String:line]];
	}
	pclose(fp);
#elif defined(__OpenBSD__)
	/* OpenBSD has no standard module listing tool */
#endif
	return a;
}

#if defined(__linux__)
static void _walkDTDir(NSString *dirPath, NSString *relPath, NSMutableArray *pairs)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:NULL];
	if (!contents) return;

	for (NSString *name in contents) {
		NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
		BOOL isDir;
		if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;

		if (isDir) {
			if ([name isEqualToString:@"of_node"]) continue;
			NSString *childRel = relPath ? [relPath stringByAppendingPathComponent:name] : name;
			NSString *compatPath = [fullPath stringByAppendingPathComponent:@"compatible"];
			NSData *cData = [NSData dataWithContentsOfFile:compatPath];
			NSString *compat = nil;
			if (cData) {
				compat = [[NSString alloc] initWithData:cData encoding:NSUTF8StringEncoding];
				if (compat) {
					compat = [compat stringByReplacingOccurrencesOfString:@"\0" withString:@", "];
					compat = [compat stringByTrimmingCharactersInSet:
						[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				}
			}
			[pairs addObject:@[[@"/" stringByAppendingString:childRel],
				compat ? compat : @""]];
			_walkDTDir(fullPath, childRel, pairs);
		}
	}
}
#endif

+ (NSArray *)deviceTreeInfo
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	if (![[NSFileManager defaultManager] fileExistsAtPath:@"/sys/firmware/devicetree/base"])
		return pairs;

	/* Root node model */
	NSData *d = [NSData dataWithContentsOfFile:@"/sys/firmware/devicetree/base/model"];
	if (d) {
		NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
		if (s) {
			s = [s stringByReplacingOccurrencesOfString:@"\0" withString:@""];
			s = [s stringByTrimmingCharactersInSet:
				[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([s length] > 0)
				[pairs addObject:@[@"Model:", s]];
		}
	}

	d = [NSData dataWithContentsOfFile:@"/sys/firmware/devicetree/base/compatible"];
	if (d) {
		NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
		if (s) {
			s = [s stringByReplacingOccurrencesOfString:@"\0" withString:@", "];
			s = [s stringByTrimmingCharactersInSet:
				[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([s length] > 0)
				[pairs addObject:@[@"Compatible:", s]];
		}
	}

	/* Walk the full device tree */
	_walkDTDir(@"/sys/firmware/devicetree/base", nil, pairs);
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	/* Device tree may be available via sysctl on some BSDs */
#endif
	return pairs;
}

+ (NSString *)_readFile:(NSString *)path
{
	NSString *s = [NSString stringWithContentsOfFile:path
	                                       encoding:NSUTF8StringEncoding
	                                          error:NULL];
	return [s stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)_runCmd:(NSString *)cmd
{
	FILE *fp = popen([cmd UTF8String], "r");
	if (!fp) return @"";
	char line[512];
	if (!fgets(line, sizeof(line), fp)) { pclose(fp); return @""; }
	char *end = strpbrk(line, "\n\r"); if (end) *end = '\0';
	pclose(fp);
	return [NSString stringWithUTF8String:line];
}

+ (NSArray *)energyInfo
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	NSString *acOnline = [self _readFile:@"/sys/class/power_supply/AC/online"];
	NSString *battCap = [self _readFile:@"/sys/class/power_supply/BAT0/capacity"];
	NSString *battStatus = [self _readFile:@"/sys/class/power_supply/BAT0/status"];
	NSString *manufacturer = [self _readFile:@"/sys/class/power_supply/BAT0/manufacturer"];
	NSString *modelName = [self _readFile:@"/sys/class/power_supply/BAT0/model_name"];
	NSString *technology = [self _readFile:@"/sys/class/power_supply/BAT0/technology"];
	NSString *serialNum = [self _readFile:@"/sys/class/power_supply/BAT0/serial_number"];
	NSString *cycleCount = [self _readFile:@"/sys/class/power_supply/BAT0/cycle_count"];
	NSString *capacityLevel = [self _readFile:@"/sys/class/power_supply/BAT0/capacity_level"];

	NSString *energyFull = [self _readFile:@"/sys/class/power_supply/BAT0/energy_full"];
	NSString *energyFullDesign = [self _readFile:@"/sys/class/power_supply/BAT0/energy_full_design"];
	NSString *energyNow = [self _readFile:@"/sys/class/power_supply/BAT0/energy_now"];

	NSString *source = [acOnline isEqualToString:@"1"] ? @"AC Power" : @"Battery";
	[pairs addObject:@[@"Power Source:", source]];

	if ([battCap length] > 0) {
		[pairs addObject:@[@"Battery Charge:", [NSString stringWithFormat:@"%@%%", battCap]]];
	}
	if ([battStatus length] > 0) {
		[pairs addObject:@[@"Battery Status:", [battStatus capitalizedString]]];
	}
	if ([manufacturer length] > 0) {
		[pairs addObject:@[@"Battery Manufacturer:", manufacturer]];
	}
	if ([modelName length] > 0) {
		[pairs addObject:@[@"Battery Model:", modelName]];
	}
	if ([technology length] > 0) {
		[pairs addObject:@[@"Battery Technology:", technology]];
	}
	if ([serialNum length] > 0) {
		[pairs addObject:@[@"Battery Serial:", serialNum]];
	}
	if ([cycleCount length] > 0) {
		[pairs addObject:@[@"Cycle Count:", cycleCount]];
	}
	if ([capacityLevel length] > 0) {
		[pairs addObject:@[@"Capacity Level:", capacityLevel]];
	}

	/* Health: energy_full / energy_full_design */
	if ([energyFullDesign doubleValue] > 0) {
		double health = ([energyFull doubleValue] / [energyFullDesign doubleValue]) * 100.0;
		[pairs addObject:@[@"Battery Health:",
			[NSString stringWithFormat:@"%.1f%%", health]]];
	}

	/* Charge energy now vs full */
	if ([energyFull doubleValue] > 0 && [energyNow doubleValue] > 0) {
		double remaining = ([energyNow doubleValue] / [energyFull doubleValue]) * 100.0;
		[pairs addObject:@[@"Charge Remaining:",
			[NSString stringWithFormat:@"%.1f%%", remaining]]];
	}

	/* CPU governor */
	NSString *gov = [self _readFile:@"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"];
	if ([gov length] > 0) {
		[pairs addObject:@[@"CPU Governor:", [gov capitalizedString]]];
	}

	/* Backlight level */
	int maxBright = [[self _readFile:@"/sys/class/backlight/intel_backlight/max_brightness"] intValue];
	int curBright = [[self _readFile:@"/sys/class/backlight/intel_backlight/brightness"] intValue];
	if (maxBright > 0) {
		int pct = (curBright * 100) / maxBright;
		[pairs addObject:@[@"Display Brightness:", [NSString stringWithFormat:@"%d%%", pct]]];
	}
#elif defined(__FreeBSD__)
	/* FreeBSD: acpiconf + sysctl */
	{
		NSString *acline = [self _runCmd:@"/sbin/sysctl -n hw.acpi.acline"];
		NSString *life = [self _runCmd:@"/sbin/sysctl -n hw.acpi.battery.life"];
		NSString *state = [self _runCmd:@"/sbin/sysctl -n hw.acpi.battery.state"];
		NSString *time = [self _runCmd:@"/sbin/sysctl -n hw.acpi.battery.time"];

		NSString *source = [acline isEqualToString:@"1"] ? @"AC Power" : @"Battery";
		[pairs addObject:@[@"Power Source:", source]];

		if ([life length] > 0)
			[pairs addObject:@[@"Battery Charge:", [life stringByAppendingString:@"%"]]];
		if ([state length] > 0) {
			int s = [state intValue];
			NSString *status = (s == 1) ? @"Discharging" :
			                  (s == 2) ? @"Charging" :
			                  (s == 7) ? @"Charged" :
			                  (s == 0) ? @"Idle" : state;
			[pairs addObject:@[@"Battery Status:", status]];
		}
		if ([time length] > 0 && [time intValue] > 0)
			[pairs addObject:@[@"Remaining Time:", [time stringByAppendingString:@" min"]]];

		/* Try acpiconf -b 0 for extra details */
		NSString *acpi = [self _runCmd:@"/usr/sbin/acpiconf -b 0"];
		if ([acpi length] > 0) {
			/* Format: "Battery 0: status, %, time" — may include manufacturer */
			[pairs addObject:@[@"ACPI Info:", acpi]];
		}
	}

	/* CPU frequency */
	{
		NSString *freq = [self _runCmd:@"/sbin/sysctl -n dev.cpu.0.freq 2>/dev/null"];
		NSString *freqLevels = [self _runCmd:@"/sbin/sysctl -n dev.cpu.0.freq_levels 2>/dev/null"];
		if ([freq length] > 0)
			[pairs addObject:@[@"CPU Frequency:", [freq stringByAppendingString:@" MHz"]]];
		if ([freqLevels length] > 0)
			[pairs addObject:@[@"CPU Freq Levels:", freqLevels]];
	}

	/* Backlight */
	{
		NSString *b = [self _runCmd:@"/usr/local/bin/xbacklight -get 2>/dev/null"];
		if ([b length] > 0) {
			int pct = (int)([b doubleValue] + 0.5);
			[pairs addObject:@[@"Display Brightness:", [NSString stringWithFormat:@"%d%%", pct]]];
		}
	}
#elif defined(__OpenBSD__)
	/* OpenBSD: apm + sysctl */
	{
		NSString *apmOut = [self _runCmd:@"/usr/sbin/apm"];
		/* apm output: "Battery state: charging, 95% remaining, 1:23" */
		if ([apmOut length] > 0) {
			[pairs addObject:@[@"APM Info:", apmOut]];

			/* Parse AC state */
			NSString *ac = [self _runCmd:@"/usr/sbin/apm -a"];
			[pairs addObject:@[@"Power Source:", [ac isEqualToString:@"1"] ? @"AC Power" : @"Battery"]];

			NSString *pct = [self _runCmd:@"/usr/sbin/apm -l"];
			if ([pct length] > 0)
				[pairs addObject:@[@"Battery Charge:", [pct stringByAppendingString:@"%"]]];

			NSString *status = [self _runCmd:@"/usr/sbin/apm -b"];
			if ([status length] > 0) {
				int s = [status intValue];
				NSString *state = (s == 0) ? @"High" :
				                  (s == 1) ? @"Low" :
				                  (s == 2) ? @"Critical" :
				                  (s == 3) ? @"Charging" : status;
				[pairs addObject:@[@"Battery Status:", state]];
			}
		} else {
			[pairs addObject:@[@"Power Source:", @"Unknown"]];
		}
	}

	/* CPU performance via hw.setperf (0 = min, 100 = max) */
	{
		NSString *perf = [self _runCmd:@"/sbin/sysctl -n hw.setperf 2>/dev/null"];
		if ([perf length] > 0) {
			int p = [perf intValue];
			NSString *label = (p >= 90) ? @"Performance" :
			                  (p <= 10) ? @"Power Save" : @"Auto";
			[pairs addObject:@[@"CPU Performance:", [NSString stringWithFormat:@"%d%% (%@)", p, label]]];
		}
	}

	/* Backlight via wsconsctl or xbacklight */
	{
		NSString *b = [self _runCmd:@"/usr/sbin/wsconsctl brightness 2>/dev/null"];
		if ([b length] == 0)
			b = [self _runCmd:@"/usr/local/bin/xbacklight -get 2>/dev/null"];
		if ([b length] > 0) {
			int pct = (int)([b doubleValue] + 0.5);
			[pairs addObject:@[@"Display Brightness:", [NSString stringWithFormat:@"%d%%", pct]]];
		}
	}
#elif defined(__NetBSD__)
	/* NetBSD: envstat + sysctl */
	{
		NSString *acline = [self _runCmd:@"/sbin/sysctl -n hw.acpi.acline 2>/dev/null"];
		if ([acline length] > 0) {
			[pairs addObject:@[@"Power Source:", [acline isEqualToString:@"1"] ? @"AC Power" : @"Battery"]];
		} else {
			[pairs addObject:@[@"Power Source:", @"Unknown"]];
		}

		NSString *life = [self _runCmd:@"/sbin/sysctl -n hw.acpi.battery.life 2>/dev/null"];
		if ([life length] > 0)
			[pairs addObject:@[@"Battery Charge:", [life stringByAppendingString:@"%"]]];

		NSString *state = [self _runCmd:@"/sbin/sysctl -n hw.acpi.battery.state 2>/dev/null"];
		if ([state length] > 0) {
			int s = [state intValue];
			NSString *status = (s == 1) ? @"Discharging" :
			                  (s == 2) ? @"Charging" :
			                  (s == 7) ? @"Charged" : state;
			[pairs addObject:@[@"Battery Status:", status]];
		}
	}

	/* CPU frequency */
	{
		NSString *freq = [self _runCmd:@"/sbin/sysctl -n machdep.cpu.frequency.current 2>/dev/null"];
		if ([freq length] == 0)
			freq = [self _runCmd:@"/sbin/sysctl -n machdep.dmi.processor-frequency 2>/dev/null"];
		if ([freq length] > 0)
			[pairs addObject:@[@"CPU Frequency:", [freq stringByAppendingString:@" MHz"]]];
	}

	/* Backlight */
	{
		NSString *b = [self _runCmd:@"/usr/local/bin/xbacklight -get 2>/dev/null"];
		if ([b length] > 0) {
			int pct = (int)([b doubleValue] + 0.5);
			[pairs addObject:@[@"Display Brightness:", [NSString stringWithFormat:@"%d%%", pct]]];
		}
	}
#else
	[pairs addObject:@[@"Power Source:", @"Unknown"]];
#endif
	return pairs;
}

+ (NSArray *)bluetoothInfo
{
	NSMutableArray *pairs = [NSMutableArray array];
#if defined(__linux__)
	NSString *show = [self _runCmd:@"/usr/bin/bluetoothctl -- show 2>/dev/null"];
	if ([show length] > 0) {
		NSString *addr = @"";
		NSString *name = @"";
		BOOL powered = NO;
		BOOL discoverable = NO;
		BOOL pairable = NO;
		for (NSString *line in [show componentsSeparatedByString:@"\n"]) {
			NSString *t = [line stringByTrimmingCharactersInSet:
				[NSCharacterSet whitespaceCharacterSet]];
			if ([t hasPrefix:@"Controller "]) {
				addr = [[t componentsSeparatedByString:@" "] objectAtIndex:1];
				[pairs addObject:@[@"Adapter Address:", addr]];
			} else if ([t hasPrefix:@"Name:"]) {
				name = [[t substringFromIndex:5]
					stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				[pairs addObject:@[@"Adapter Name:", name]];
			} else if ([t hasPrefix:@"Alias:"]) {
				NSString *alias = [[t substringFromIndex:6]
					stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				[pairs addObject:@[@"Alias:", alias]];
			} else if ([t isEqualToString:@"Powered: yes"]) {
				powered = YES;
			} else if ([t isEqualToString:@"Discoverable: yes"]) {
				discoverable = YES;
			} else if ([t isEqualToString:@"Pairable: yes"]) {
				pairable = YES;
			}
		}
		[pairs addObject:@[@"Powered:", powered ? @"Yes" : @"No"]];
		[pairs addObject:@[@"Discoverable:", discoverable ? @"Yes" : @"No"]];
		[pairs addObject:@[@"Pairable:", pairable ? @"Yes" : @"No"]];

		NSString *paired = [self _runCmd:@"/usr/bin/bluetoothctl -- devices Paired 2>/dev/null"];
		if ([paired length] > 0) {
			int count = 0;
			for (NSString *line in [paired componentsSeparatedByString:@"\n"]) {
				if ([line hasPrefix:@"Device "]) count++;
			}
			[pairs addObject:@[@"Paired Devices:", [NSString stringWithFormat:@"%d", count]]];
		}

		NSString *connected = [self _runCmd:@"/usr/bin/bluetoothctl -- devices Connected 2>/dev/null"];
		if ([connected length] > 0) {
			int count = 0;
			for (NSString *line in [connected componentsSeparatedByString:@"\n"]) {
				if ([line hasPrefix:@"Device "]) count++;
			}
			[pairs addObject:@[@"Connected Devices:", [NSString stringWithFormat:@"%d", count]]];
		}
	} else {
		[pairs addObject:@[@"Bluetooth:", @"Not available"]];
	}
#elif defined(__FreeBSD__)
	NSString *bdaddr = [self _runCmd:@"/usr/sbin/hccontrol -n ubt0hci read_node_bd_addr 2>/dev/null"];
	if ([bdaddr length] > 0) {
		[pairs addObject:@[@"Adapter:", bdaddr]];
		NSString *ver = [self _runCmd:@"/usr/sbin/hccontrol -n ubt0hci read_local_version_information 2>/dev/null"];
		if ([ver length] > 0)
			[pairs addObject:@[@"Version:", ver]];
		NSString *name = [self _runCmd:@"/usr/sbin/hccontrol -n ubt0hci read_local_name 2>/dev/null"];
		if ([name length] > 0)
			[pairs addObject:@[@"Name:", name]];
		NSString *conns = [self _runCmd:@"/usr/sbin/hccontrol -n ubt0hci read_connection_list 2>/dev/null"];
		if ([conns length] > 0)
			[pairs addObject:@[@"Connections:", conns]];
	} else {
		[pairs addObject:@[@"Bluetooth:", @"Not available"]];
	}
#elif defined(__OpenBSD__) || defined(__NetBSD__)
	[pairs addObject:@[@"Bluetooth:", @"Not available on this platform"]];
#else
	[pairs addObject:@[@"Bluetooth:", @"Not available"]];
#endif
	return pairs;
}

@end
