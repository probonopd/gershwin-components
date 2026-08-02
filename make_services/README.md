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

libsquashfs (squashfs-tools-ng) is detected at build time and is optional: on
systems without it (e.g. Arch, OpenBSD) `make_services` still builds, but
AppImage functionality is disabled and a warning is printed both at build time
and at run time, so no AppImage applications are registered there.

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

### Document icons for AppImage file types

Like `appwrap` does for wrapped applications, `make_services` generates a
document icon for each file type an AppImage registers.  Since an AppImage is
a single executable file and not a bundle, there is no `Resources` directory
to hold the icons, so they are written as PNG files to
`~/Library/Services/DocumentIcons/` (next to the `.GNUstepAppList` cache that
references them).

The application icon used for the composite is taken from the top level of the
AppImage itself (the `.desktop` `Icon=` name, the application name, `.DirIcon`,
or any top-level image), falling back to a host icon-theme search.

The extension entry stored in the app list points at each generated icon by
*absolute path*:

```
NSIcon = "/Local/Users/admin/Library/Services/DocumentIcons/OrcaSlicer-doc-stl.png";
```

`NSWorkspace` loads absolute icon paths directly, so files of these types show
the AppImage's document icon without an `.app` bundle.  Icons are only
regenerated when missing or older than the AppImage, and when `make_services`
runs headless (no display server) the file types are still registered, just
without icons.

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
* `[NSWorkspace findApplications]` keeps the running Workspace in sync with
  newly installed applications and AppImages - see "findApplications in the
  Workspace" below.
* File icons come from `NSWorkspace`'s existing extension-icon lookup: for an
  extension handled by an AppImage, the absolute-path `NSIcon` entry in the
  extension map is loaded directly, so files of that type show the generated
  document icon.  (The Workspace's own `AppImageIconProvider` swizzle only
  intercepts AppImage files themselves and does not interfere with document
  files.)
* The Workspace's `launchApplication:arguments:` launches AppImages as plain
  executables: when the resolved application is a regular executable file (no
  `.app` bundle), it is started with the opened file path as a plain argument
  instead of the GNUstep `-GSFilePath` option.

### `findApplications` in the Workspace

`[NSWorkspace findApplications]` refreshes the caches while the Workspace is
running.  It is called in two places:

* by `[NSWorkspace sharedWorkspace]` at startup, if the application list has
  not been read yet;
* by the Workspace's `launchApplication:arguments:` whenever an application
  name cannot be resolved to a path - it then re-runs the resolution after
  the refresh, so a newly installed application (or a freshly downloaded
  AppImage) is found without logging out and back in.

Calling it does the following:

1. locates `make_services` with `[NSTask launchPathForTool:]` and runs it,
   waiting for it to finish - this rebuilds `.GNUstepAppList` and
   `.GNUstepServices` from the current application directories (see
   "What it scans");
2. posts the `GSWorkspacePreferencesChanged` notification, which makes
   `NSWorkspace` re-read `.GNUstepAppList`, `.GNUstepExtPrefs` and
   `.GNUstepURLPrefs` from disk and drop its per-extension icon cache, so
   updated extension associations, default applications and document icons
   are picked up immediately.

## Inspecting the caches (pldes)

All caches are binary property lists.  They can be dumped in a readable form
with the GNUstep `pldes` tool:

```
pldes ~/Library/Services/.GNUstepAppList
pldes ~/Library/Services/.GNUstepExtPrefs
pldes ~/Library/Services/.GNUstepServices
pldes ~/Library/Services/.GNUstepURLPrefs
```

(`pldes` is installed in the GNUstep tools directory, e.g.
`/System/Library/Tools/pldes`.)

### `.GNUstepAppList`

Written by `make_services`.  The top level maps application names to paths and
contains the two extension/scheme maps used by `NSWorkspace`:

```
"TextEdit.app" = "/Local/Applications/TextEdit.app";
"OrcaSlicer.app" = "/Local/Users/admin/Downloads/OrcaSlicer_Linux_AppImage_Ubuntu2404_V2.4.2.AppImage";
GSExtensionsMap = {
    stl = {
        OrcaSlicer = {
            NSIcon = "/Local/Users/admin/Library/Services/DocumentIcons/OrcaSlicer-doc-stl.png";
            NSUnixExtensions = stl;
        };
    };
};
GSSchemesMap = {
    "jitsi-meet" = {
        "Jitsi Meet" = { NSURLScheme = "jitsi-meet"; };
    };
};
```

* the `<Name>.app` entries resolve an application name to its absolute path
  (`fullPathForApplication:`), which is how the Workspace finds AppImages even
  though they are plain executables;
* `GSExtensionsMap` maps each file extension (lowercase, plus the `*` wildcard)
  to the applications that open it and their type information
  (`NSHumanReadableName`, `NSMIMETypes`, `NSRole`, `NSIcon`, ...) - the source
  for `[NSWorkspace infoForExtension:]`, the "Open With" menu and file-type
  descriptions;
* `GSSchemesMap` maps each URL scheme to the applications that register it.

### `.GNUstepServices`

Written by `make_services` from the `NSServices` declarations in application
Info.plists.  It backs the OpenStep services facility and contains the
`ByPath`, `ByService`, `ByFilter`, `ByPrint` and `BySpell` lookup tables used
by `NSApplication`/`NSWorkspace` to populate the Services menu.

### `.GNUstepExtPrefs`

Written by `NSWorkspace` when a default application is chosen for a file type
(e.g. via `setEditor:forFileType:`).  It records the user's preferred
application per extension:

```
{
    mp3 = { Editor = "Player.app"; };
}
```

### `.GNUstepURLPrefs`

Written by `NSWorkspace` when a default application is chosen for a URL scheme.
Same shape as `.GNUstepExtPrefs`, keyed by scheme instead of extension:

```
{
    http = { Editor = "WebBrowser.app"; };
    https = { Editor = "WebBrowser.app"; };
}
```

### How it all fits together

`make_services` rebuilds `.GNUstepAppList` and `.GNUstepServices` from the
installed applications (see "What it scans").  `NSWorkspace` reads them at
startup and re-reads them after `findApplications` reruns `make_services`;
user choices for default applications go into the two `.GNUstep*Prefs` files,
which take precedence over what the app list would otherwise pick.  The
`--extensions` and `--schemes` options of `make_services` print the same
information as `pldes` for the extension and scheme maps in a compact table.

## Building

Links GNUstep's AppKit (`libs-gui`) for the document-icon rendering.
`libsquashfs` (squashfs-tools-ng) is optional - it is auto-detected, and
AppImage support is only built when it is present.  Built and installed
together with `gershwin-components`:

```
sudo gmake install        # from the gershwin-components top level
```

or on its own:

```
gmake all
sudo gmake install
```
