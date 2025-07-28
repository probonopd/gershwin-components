# Instructions

* We are on FreeBSD, which means that many commands are in `/usr/local/bin/` rather than `/usr/bin/`.
But in order to increase portability, we should not hardcode paths but rather use `$PATH`.

* GNUstep is installed in `/System` (do NOT use the one in `/usr/local/GNUstep/`).

* Use `gmake` rather than `make`.

* Never use bashisms, always use POSIX sh. (The shell on our system is `csh`.)

* Always try building the application until it works, even if it
requires multiple attempts or changes to the code.

* Always fix all compiler warnings, even if they seem minor.

* If a command must be run with root privileges, use `sudo -A` in the code,
this will lead to the user being asked to enter the password.

* Always use `clang19` for compiling, never use `gcc`.

* Run `/System/Applications/SystemPreferences.app/SystemPreferences` to test the preference pane after building it.
This allows us to see the logging output.

* Check the FreeBSD ports handbook for guidance on how to build ports

* In general, check the FreeBSD documentation on the operating system