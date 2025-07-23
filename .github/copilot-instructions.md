# Instructions

* When we work with GNUstep, use the GNUstep that is on FreeBSD
and is installed in `/System` (do NOT use the one in `/usr/local/GNUstep/`),
and use `gmake` rather than `make`.

* Never use bashisms, always use POSIX sh. (The shell on our system is `csh`.)

* Always try building the application until it works, even if it
requires multiple attempts or changes to the code.

* Always fix all compiler warnings, even if they seem minor.