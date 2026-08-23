# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = DiskUtility
VERSION = 1.0

# Flat #import across the tree: every source dir is on the include path
ADDITIONAL_INCLUDE_DIRS = \
	-ISources \
	-ISources/Application \
	-ISources/Controllers \
	-ISources/Views \
	-ISources/Models \
	-ISources/Services \
	-ISources/Operations \
	-ISources/Backend \
	-ISources/Backend/Parsers \
	-ISources/Backend/Linux \
	-ISources/Backend/FreeBSD \
	-ISources/Backend/OpenBSD \
	-ISources/Backend/NetBSD \
	-ISources/Utilities \
	-I.

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc -fobjc-arc-exceptions -Wno-unused-parameter

DiskUtility_OBJC_FILES = \
	Sources/main.m \
	Sources/Application/DUApplicationDelegate.m \
	Sources/Application/DUPreferencesController.m \
	Sources/Controllers/DUMainWindowController.m \
	Sources/Controllers/DUDeviceBrowserController.m \
	Sources/Controllers/DUOperationController.m \
	Sources/Controllers/DUInformationController.m \
	Sources/Controllers/DUFirstAidViewController.m \
	Sources/Controllers/DUEraseViewController.m \
	Sources/Controllers/DUNewImageController.m \
	Sources/Controllers/DUPartitionViewController.m \
		Sources/Controllers/DURestoreViewController.m \
	Sources/Views/DUDeviceOutlineView.m \
	Sources/Views/DUDiskMapView.m \
	Sources/Views/DUOperationLogView.m \
	Sources/Views/DUIcons.m \
	Sources/Models/DUStorageObject.m \
	Sources/Models/DUStorageDevice.m \
	Sources/Models/DUPartition.m \
	Sources/Models/DUStorageVolume.m \
	Sources/Models/DUOpticalMedia.m \
	Sources/Models/DUDiskImage.m \
	Sources/Models/DURAIDSet.m \
	Sources/Models/DUStorageCapabilities.m \
	Sources/Models/DUPartitionLayout.m \
	Sources/Models/DUPartitionPlan.m \
	Sources/Services/DUStorageManager.m \
	Sources/Services/DUOperationManager.m \
	Sources/Services/DUDeviceMonitor.m \
	Sources/Services/DUAuthorizationManager.m \
	Sources/Services/DUImageService.m \
	Sources/Services/DUNotifications.m \
	Sources/Operations/DUOperation.m \
	Sources/Operations/DUVerifyOperation.m \
	Sources/Operations/DURepairOperation.m \
	Sources/Operations/DUEraseOperation.m \
	Sources/Operations/DUPartitionOperation.m \
	Sources/Operations/DURestoreOperation.m \
	Sources/Operations/DURAIDOperation.m \
	Sources/Operations/DUCreateImageOperation.m \
	Sources/Operations/DUImageOperation.m \
	Sources/Utilities/DUErrors.m \
	Sources/Utilities/DUProcessRunner.m \
	Sources/Utilities/DUParsing.m \
	Sources/Backend/DUStorageBackend.m \
	Sources/Backend/DUMockStorageBackend.m \
	Sources/Backend/DUBackendFactory.m \
	Sources/Backend/Parsers/DULsblkParser.m \
	Sources/Backend/Parsers/DUBlkidParser.m \
	Sources/Backend/Parsers/DUFreeBSDGEOMParser.m \
	Sources/Backend/Parsers/DUOpenBSDDisklabelParser.m \
	Sources/Backend/Parsers/DUNetBKSDisklabelParser.m \
	Sources/Backend/Parsers/DUPartitionTableParser.m \
	Sources/Backend/Linux/DULinuxStorageBackend.m \
	Sources/Backend/Linux/DULinuxDeviceDiscovery.m \
	Sources/Backend/Linux/DULinuxPartitionTool.m \
	Sources/Backend/Linux/DULinuxFilesystemTool.m \
	Sources/Backend/Linux/DULinuxImageTool.m \
	Sources/Backend/FreeBSD/DUFreeBSDStorageBackend.m \
	Sources/Backend/FreeBSD/DUFreeBSDDeviceDiscovery.m \
	Sources/Backend/OpenBSD/DUOpenBSDStorageBackend.m \
	Sources/Backend/OpenBSD/DUOpenBSDDeviceDiscovery.m \
	Sources/Backend/NetBSD/DUNetBSDStorageBackend.m \
	Sources/Backend/NetBSD/DUNetBSDDeviceDiscovery.m

DiskUtility_RESOURCE_FILES = \
	Resources/DiskUtility.png \
	Resources/Icons/verify.png \
	Resources/Icons/info.png \
	Resources/Icons/burn.png \
	Resources/Icons/mount.png \
	Resources/Icons/eject.png \
	Resources/Icons/journal.png \
	Resources/Icons/newimage.png \
	Resources/Icons/convert.png \
	Resources/Icons/resize.png \
	Resources/Icons/disk.png \
	Resources/Icons/volume.png \
	Resources/Icons/optical.png \
	Resources/Icons/media.png \
	Resources/Icons/image.png \
	Resources/Icons/raid.png

DiskUtility_MAIN_MODEL_FILE =

DiskUtility_INFO_PLIST = Resources/DiskUtilityInfo.plist

DiskUtility_APPLICATION_ICON = DiskUtility.png

DiskUtility_LDFLAGS = -lgnustep-base -lgnustep-gui -Wl,-rpath,/System/Library/Libraries

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)
