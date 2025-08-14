/*
 * Compatibility header for ZFS/Solaris types on FreeBSD
 */

#ifndef _ZFS_COMPAT_TYPES_H_
#define _ZFS_COMPAT_TYPES_H_

#include <sys/types.h>
#include <stdint.h>

// Define missing Solaris types
typedef unsigned int    uint_t;
typedef unsigned char   uchar_t;
typedef unsigned int    boolean_t;

// Boolean values
#ifndef B_FALSE
#define B_FALSE 0
#endif
#ifndef B_TRUE  
#define B_TRUE  1
#endif

#endif /* _ZFS_COMPAT_TYPES_H_ */
