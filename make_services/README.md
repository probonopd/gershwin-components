# make_services

`make_services` builds the GNUstep caches of service information, file
extensions and URL schemes that applications support.  It is the tool the
Gershwin desktop runs to produce `.GNUstepServices` and `.GNUstepAppList` in
`~/Library/Services`.

This copy is a drop-in replacement for the `make_services` shipped with
`libs-gui`, extended for Gershwin.  When `gershwin-components` is installed,
this version is installed to `/System/Library/Tools/make_services`, overwriting
the `libs-gui` one.

## What it scans

* the standard application directories (`NSAllApplicationsDirectory`) in all
  domains (`~/Applications`, `/Local/Applications`, `/Network/Applications`,
  `/System/Applications`);
* `Library/CoreServices/Applications` in every domain, where system components
  such as the menu bar and the window manager live;
* the user's `~/Downloads` directory, where downloaded AppImage applications
  are commonly kept;
* the standard `Services` directories.

Every found application is logged (`found application ...`), and AppImage
scans log their results, when running with the default verbosity.

## Gershwin additions

### AppImage applications

AppImages (self-extracting ELF + SquashFS executables) are now registered as
applications.  `AppImageReader.m` (linking `libsquashfs`) locates the SquashFS
payload inside a Type-2 AppImage, reads the top-level `*.desktop` file and
exposes the top-level regular files.

For each AppImage the `.desktop` file is parsed and the application is
registered just like an app bundle:

* the application name (the `.desktop` `Name=` field, or the file name) is
  keyed in the application list with a `.app` extension pointing at the
  AppImage executable, mirroring how `TextEdit.app` maps to its absolute path;
* the file types from the `.desktop` `MimeType=` field become GNUstep
  extension associations (the mime type subtype is used as the extension, with
  a table of exceptions such as `model/stl` -> `stl`, `application/vnd.ms-3mfdocument`
  -> `3mf`, `text/plain` -> `txt`);
* `x-scheme-handler/...` mime types become URL scheme associations.

### `--lookup=` command

Shows which applications can open a given filename extension or mime type:

```
$ make_services --lookup=stl
extension .stl can be opened by:
  OrcaSlicer
$ make_services --lookup=model/stl
mime type model/stl (extension stl) can be opened by:
  OrcaSlicer
```

## Interaction with the Workspace

The Gershwin Workspace reads the caches produced here:

* `NSWorkspace` loads `~/Library/Services/.GNUstepAppList` and resolves
  applications by name through `fullPathForApplication:` (which looks the name
  up as `<name>.app`), so AppImages registered under their name plus `.app`
  are found.
* The Workspace "Open With" submenu is populated from the `GSExtensionsMap`
  via `[NSWorkspace infoForExtension:]`.
* `[NSWorkspace findApplications]` (called when an application is not found)
  reruns this `make_services` binary, so regenerating the caches keeps the
  AppImage entries.
* The Workspace's `launchApplication:arguments:` launches AppImages as plain
  executables: when the resolved application is a regular executable file (no
  `.app` bundle), it is started with the opened file path as a plain argument
  instead of the GNUstep `-GSFilePath` option.

## Building

Requires `libsquashfs` (squashfs-tools-ng).  Built and installed together with
`gershwin-components`:

```
sudo gmake install        # from the gershwin-components top level
```

or on its own:

```
gmake all
sudo gmake install
```
