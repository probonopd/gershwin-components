#!/bin/sh

# Copies the running FreeBSD system to a new disk and make it bootable (UEFI or BIOS)
# WARNING: This will ERASE all data on the target disk!
#
# Usage:
#   installer.sh                           Interactive mode
#   installer.sh --list-disks              Output JSON list of available disks
#   installer.sh --noninteractive --disk /dev/da1   Non-interactive install to disk

set -e

# ---- Argument Parsing ----
NONINTERACTIVE=0
ARG_DISK=""
LIST_DISKS=0
ARG_SOURCE=""

CHECK_IMAGE_SOURCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --noninteractive) NONINTERACTIVE=1; shift ;;
        --disk) ARG_DISK="$2"; shift 2 ;;
        --source) ARG_SOURCE="$2"; shift 2 ;;
        --list-disks) LIST_DISKS=1; shift ;;
        --check-image-source) CHECK_IMAGE_SOURCE=1; shift ;;
        --debug) DEBUG=1; shift ;;
        *) ARG_DISK="$1"; shift ;;
    esac
done

# Debug flag defaults to 0
DEBUG=${DEBUG:-0}

report_progress() {
    # Usage: report_progress "Phase" percent "Message"
    echo "PROGRESS:$1:$2:$3"
}

# Checks - detect FreeBSD even under Linux compatibility layer
IS_FREEBSD=0
if [ "$(uname -s)" = "FreeBSD" ]; then
    IS_FREEBSD=1
elif [ -x /bin/freebsd-version ]; then
    IS_FREEBSD=1
elif [ -f /etc/rc.conf ] && sysctl -n kern.ostype 2>/dev/null | grep -q FreeBSD; then
    IS_FREEBSD=1
fi
if [ "$IS_FREEBSD" != "1" ]; then
    echo "ERROR: This script must be run on FreeBSD."
    exit 1
fi

if [ "$LIST_DISKS" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# Automounter control
AUTOMOUNTER_DEVD=""
disable_automounter() {
    if command -v service >/dev/null 2>&1; then
        if service devd onestatus 2>/dev/null; then
            AUTOMOUNTER_DEVD=1
            echo "Stopping devd..."
            service devd stop || true
            sleep 2
        fi
    fi
    # If still alive, escalate
    if pgrep -q devd 2>/dev/null; then
        AUTOMOUNTER_DEVD=1
        echo "devd still running, trying killall..."
        killall devd 2>/dev/null || true
        sleep 2
    fi
    if pgrep -q devd 2>/dev/null; then
        AUTOMOUNTER_DEVD=1
        echo "devd still running, forcing kill..."
        killall -9 devd 2>/dev/null || true
        sleep 1
    fi
    # Refuse to proceed if devd is still alive
    if pgrep -q devd 2>/dev/null; then
        echo "ERROR: Cannot stop devd. It may be automatically respawning."
        echo "Please stop it manually and try again."
        exit 1
    fi
    # Stop automountd too if present
    if command -v service >/dev/null 2>&1; then
        if service automountd onestatus 2>/dev/null; then
            service automountd onestop 2>/dev/null || true
        fi
        if service autounmountd onestatus 2>/dev/null; then
            service autounmountd onestop 2>/dev/null || true
        fi
    fi
}

enable_automounter() {
    if [ -n "$AUTOMOUNTER_DEVD" ] && command -v service >/dev/null 2>&1; then
        echo "Starting devd..."
        service devd onestart 2>/dev/null || true
    fi
}

# ---- Disk enumeration (shared by --list-disks and interactive selection) ----
MIN_SIZE=2147483648  # 2GB in bytes

# Determine disks to exclude: the disk containing the installer script and the disk mounted as /
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in /*) ;; *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;; esac
if command -v realpath >/dev/null 2>&1; then
    SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"
fi
SCRIPT_DEV=$(df -P "$SCRIPT_PATH" 2>/dev/null | awk 'NR==2 {print $1}' || true)
ROOT_DEV=$(mount | awk '$3=="/" {print $1}' || true)
disk_base() { basename "$1" | sed -E 's/p?[0-9]+$//' | sed -E 's/s[0-9]+$//' ; }
SCRIPT_DISK=$(disk_base "$SCRIPT_DEV")
ROOT_DISK=$(disk_base "$ROOT_DEV")

# For ZFS root, determine the physical disk backing the root pool
ZFS_ROOT_DISKS=""
case "$ROOT_DEV" in
    */*)
        # Looks like a ZFS dataset (e.g., zroot/ROOT/default)
        ZFS_POOL=$(echo "$ROOT_DEV" | cut -d/ -f1)
        if command -v zpool >/dev/null 2>&1 && [ -n "$ZFS_POOL" ]; then
            ZFS_ROOT_DISKS=$(zpool status "$ZFS_POOL" 2>/dev/null | awk '/ONLINE/ && /ada|da|nvd|nda/ {print $1}' | sed -E 's/p?[0-9]+$//' | sort -u)
        fi
        ;;
esac

enumerate_disks() {
    # Returns lines of: device_name size_bytes description
    for d in $(sysctl -n kern.disks 2>/dev/null); do
        # Skip the installer or root disk
        if [ -n "$SCRIPT_DISK" ] && [ "$d" = "$SCRIPT_DISK" ]; then continue; fi
        if [ -n "$ROOT_DISK" ] && [ "$d" = "$ROOT_DISK" ]; then continue; fi
        # Skip disks backing the ZFS root pool
        skip_zfs=0
        for zd in $ZFS_ROOT_DISKS; do
            if [ "$d" = "$zd" ]; then skip_zfs=1; break; fi
        done
        if [ "$skip_zfs" = "1" ]; then
            if [ "$DEBUG" = "1" ]; then echo "DIAG: skipping $d (ZFS root pool disk)" >&2; fi
            continue
        fi

        size=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        # Fallback: try geom disk list for Mediasize if diskinfo fails
        if [ -z "$size" ] || [ "$size" = "0" ]; then
            size=$(geom disk list "$d" 2>/dev/null | awk '/Mediasize:/ {print $2; exit}')
        fi
        [ -z "$size" ] && size=0
        if [ -n "$size" ] && awk -v s="$size" -v m="$MIN_SIZE" 'BEGIN { exit !(s >= m) }' 2>/dev/null; then
            desc=$(geom disk list "$d" 2>/dev/null | grep "descr:" | head -n1 | cut -d: -f2 | sed 's/^[[:space:]]*//')
            [ -z "$desc" ] && desc="Unknown Disk"
            if [ "$DEBUG" = "1" ]; then
                echo "DIAG: disk=$d size=$size desc=$desc" >&2
            fi
            echo "$d $size $desc"
        else
            if [ "$DEBUG" = "1" ]; then
                echo "DIAG: skipping $d size=$size" >&2
            fi
        fi
    done
}

# ---- --list-disks mode: output JSON and exit ----
if [ "$LIST_DISKS" = "1" ]; then
    printf '['
    first=1
    enumerate_disks | while IFS= read -r line; do
        dname=$(echo "$line" | awk '{print $1}')
        dsize=$(echo "$line" | awk '{print $2}')
        ddesc=$(echo "$line" | awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print}')
        if [ "$first" = "1" ]; then first=0; else printf ','; fi
        # Human-readable size
        if command -v numfmt >/dev/null 2>&1; then
            size_hr=$(numfmt --to=iec --suffix=B "$dsize")
        else
            size_hr=$(awk -v b="$dsize" 'BEGIN { if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.1f MB", b/1048576; else printf "%d B", b }')
        fi
        printf '{"devicePath":"/dev/%s","name":"%s","description":"%s","sizeBytes":%s,"formattedSize":"%s"}' \
            "$dname" "$dname" "$ddesc" "$dsize" "$size_hr"
    done
    printf ']\n'
    exit 0
fi

# ---- --check-image-source mode: detect and report image source, then exit ----
if [ "$CHECK_IMAGE_SOURCE" = "1" ]; then
    MP=$(mount | while read -r line; do
        case "$line" in
            /dev/da0*)
                echo "$line" | sed 's/^[^ ]* on \(.*\) (.*/\1/'
                exit 0
                ;;
        esac
    done)
    if [ -n "$MP" ]; then
        echo "IMAGE_SOURCE:$MP"
    else
        echo "IMAGE_SOURCE:"
    fi
    exit 0
fi

# Determine if /dev/da0 is mounted and offer image-based installation only if it is
IMAGE_MODE=0
if [ -n "$ARG_SOURCE" ]; then
    SRC="$ARG_SOURCE"
else
    MP=$(mount | while read -r line; do
        case "$line" in
            /dev/da0*)
                echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/'
                exit 0
                ;;
        esac
    done)
    if [ -n "$MP" ]; then
        if [ "$NONINTERACTIVE" = "1" ]; then
            echo "Image-based install: copying from $MP"
            SRC="$MP"
        else
            printf "Perform image-based installation (like Live system)? [y/N]: "
            read -r image_ans
            case "$image_ans" in
                [Yy]*)
                    echo "Image-based install: copying from $MP"
                    SRC="$MP"
                    IMAGE_MODE=1
                    ;;
                *) SRC="/" ;;
            esac
        fi
    else
        SRC="/"
    fi
fi

MNT="/mnt"
EFI_SIZE="512M"

kill_fuse_by_dev() {
  d=$1; [ -z "$d" ] && return 1
  pids=
  if command -v ps >/dev/null 2>&1; then
    pids=$(ps -axww -o pid= -o command= 2>/dev/null |
      awk -v d="$d" '{
        s=$0; l=tolower(s);
        if (l ~ /(fuse|lklfuse)/ && index(s,d)) print $1
      }')
  fi
  [ -z "$pids" ] && return 0
  echo "$pids" | while IFS= read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 2
  echo "$pids" | while IFS= read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
}

# Function: unmount everything under $MNT
umount_recursive() {
    mount | while read -r line; do
        mp=$(echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/')
        case "$mp" in
            "$MNT"*) echo "$mp" ;;
        esac
    done | sort -r | while read -r mp; do
        umount "$mp" 2>/dev/null || true
    done
}

# Function: unmount all partitions of a disk
umount_disk_partitions() {
    disk_to_unmount="$1"
    [ -z "$disk_to_unmount" ] && return
    
    mount | while read -r line; do
        dev=$(echo "$line" | cut -d' ' -f1)
        case "$dev" in
            "$disk_to_unmount" | "${disk_to_unmount}p"* | "${disk_to_unmount}s"*)
                mp=$(echo "$line" | sed 's/^[^ ]* on \(.*\) (.*)/\1/')
                if [ -n "$mp" ] && [ "$mp" != "/" ]; then
                    echo "Unmounting $mp ($dev)..."
                    umount -f "$mp" 2>/dev/null || true
                fi
                ;;
        esac
    done
}

# Disk Selection
if [ -n "$ARG_DISK" ]; then
    DISK="$ARG_DISK"
    # Add /dev/ if missing and it doesn't start with /
    case "$DISK" in
        /*) ;;
        *) DISK="/dev/$DISK" ;;
    esac
    
    if [ ! -c "$DISK" ]; then
        echo "ERROR: $DISK is not a character device"
        exit 1
    fi
else
    if [ "$NONINTERACTIVE" = "1" ]; then
        echo "ERROR: --disk is required in non-interactive mode"
        exit 1
    fi
    echo "Scanning for disks over 2GB..."
    VALID_DISKS=""

    EXCLUDED_MSG=""
    if [ -n "$SCRIPT_DISK" ]; then EXCLUDED_MSG="$EXCLUDED_MSG installer:$SCRIPT_DISK"; fi
    if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" != "$SCRIPT_DISK" ]; then EXCLUDED_MSG="$EXCLUDED_MSG root:$ROOT_DISK"; fi
    if [ -n "$EXCLUDED_MSG" ]; then echo "Excluding disks: $EXCLUDED_MSG"; fi
    
    # shellcheck disable=SC2046
    for d in $(sysctl -n kern.disks 2>/dev/null); do
        # Skip the installer or root disk
        if [ -n "$SCRIPT_DISK" ] && [ "$d" = "$SCRIPT_DISK" ]; then
            continue
        fi
        if [ -n "$ROOT_DISK" ] && [ "$d" = "$ROOT_DISK" ]; then
            continue
        fi

        # diskinfo without flags returns: device sectorsize size_bytes size_sectors ...
        size=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        [ -z "$size" ] && size=0
        # Use awk for comparison to handle large integers (> 32-bit)
        if [ -n "$size" ] && awk -v s="$size" -v m="$MIN_SIZE" 'BEGIN { exit !(s >= m) }' 2>/dev/null; then
            VALID_DISKS="$VALID_DISKS $d"
        fi
    done

    if [ -z "$VALID_DISKS" ]; then
        echo "ERROR: No disks larger than 2GB found (after excluding installer/root disks)."
        echo "Ensure you are running on FreeBSD and have permissions to access disks."
        exit 1
    fi

    echo "Available disks (>2GB):"
    count=0
    for d in $VALID_DISKS; do
        count=$((count + 1))
        size_bytes=$(diskinfo "/dev/$d" 2>/dev/null | awk '{print $3}')
        [ -z "$size_bytes" ] && size_bytes=0
        size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.0f", b / 1073741824 }')
        # Try to get a description from geom
        desc=$(geom disk list "$d" 2>/dev/null | grep "descr:" | head -n1 | cut -d: -f2 | sed 's/^[[:space:]]*//')
        [ -z "$desc" ] && desc="Unknown Disk"
        echo "$count) $d - $desc (${size_gb}GB)"
    done

    printf "Select a disk (1-%d): " "$count"
    read -r choice
    
    # Ensure choice is a valid decimal number
    case "$choice" in
        ''|*[!0-9]*) choice=0 ;;
    esac
    
    item_count=0
    for d in $VALID_DISKS; do
        item_count=$((item_count + 1))
        if [ "$item_count" -eq "$choice" ] 2>/dev/null; then
            DISK="/dev/$d"
            break
        fi
    done

    if [ -z "$DISK" ]; then
        echo "Invalid selection."
        exit 1
    fi
fi

echo "Target disk: $DISK"

# Detect Boot Method
BOOT_METHOD=$(sysctl -n machdep.bootmethod)
echo "Detected boot method: $BOOT_METHOD"

# Confirmation prompt
if [ "$NONINTERACTIVE" = "1" ]; then
    echo "Non-interactive mode: proceeding with installation to $DISK"
else
    echo "WARNING: This will ERASE all data on $DISK!"
    printf "Are you sure you want to continue? [y/N]: "
    read -r ans
    case "$ans" in
        [Yy]*) echo "Proceeding..." ;;
        *) echo "Aborting."; exit 1 ;;
    esac
fi

sleep 1

report_progress "Preparing" 5 "Unmounting existing partitions..."

# Cleanup
kill_fuse_by_dev "$DISK"
umount_disk_partitions "$DISK"
umount_recursive

# Disable automounter to prevent interference
disable_automounter

report_progress "Partitioning" 8 "Destroying old partition table..."
echo "Destroying old partition table..."
gpart destroy -F "$DISK" 2>/dev/null || true

report_progress "Partitioning" 10 "Creating GPT partition table..."
echo "Creating GPT..."
gpart create -s gpt "$DISK"

if [ "$BOOT_METHOD" = "UEFI" ]; then
    # Create EFI partition
    report_progress "Partitioning" 12 "Creating EFI partition..."
    echo "Creating EFI partition..."
    gpart add -t efi -s "$EFI_SIZE" "$DISK"
    EFI_PART="${DISK}p1"
    report_progress "Formatting" 15 "Formatting EFI partition..."
    echo "Formatting EFI..."
    newfs_msdos -F 32 -c 1 "$EFI_PART"
else
    # Create BIOS boot partition
    report_progress "Partitioning" 12 "Creating BIOS boot partition..."
    echo "Creating BIOS boot partition..."
    gpart add -t freebsd-boot -s 512k "$DISK"
    gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "$DISK"
fi

# Create UFS root
report_progress "Partitioning" 18 "Creating root partition..."
echo "Creating UFS root partition..."
gpart add -t freebsd-ufs "$DISK"
ROOT_PART="${DISK}p2"
report_progress "Formatting" 20 "Formatting root filesystem..."
newfs -U "$ROOT_PART"

# Mount filesystems
report_progress "Mounting" 22 "Mounting target filesystems..."
echo "Mounting target..."
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"

if [ "$BOOT_METHOD" = "UEFI" ]; then
    mkdir -p "$MNT/efi"
    mount -t msdosfs "$EFI_PART" "$MNT/efi"
fi

# Re-enable automounter now that filesystems are mounted
enable_automounter

report_progress "Copying" 25 "Starting system copy from $SRC..."
echo "Copying system from $SRC to $MNT..."

# Exclude runtime dirs
EXCLUDES="dev proc sys tmp mnt media efi private run var/run var/tmp var/cache compat"

# For non-image installations, also exclude /Local (it will be initialized with dscli init
# because DirectoryServices requires specific permissions and ownership that are hard to preserve during copying)
if [ "$IMAGE_MODE" = "0" ]; then
    EXCLUDES="$EXCLUDES Local"
    if [ -n "$MP" ]; then
        EXCLUDES="$EXCLUDES boot"
    fi
fi

EXCLUDE_ARGS=""
for d in $EXCLUDES; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$d"
done

# POSIX-safe cp -a with excludes using rsync if available, else fallback to find+cp
if command -v rsync >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    rsync_pipe=/tmp/rsync_pipe.$$
    if mkfifo "$rsync_pipe" 2>/dev/null; then
        rsync -aHAX --info=progress2 $EXCLUDE_ARGS "${SRC%/}/" "$MNT" > "$rsync_pipe" 2>&1 &
        rsync_pid=$!
        while IFS= read -r line; do
            echo "$line"
            pct=$(echo "$line" | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p')
            if [ -n "$pct" ]; then
                scaled=$(awk -v p="$pct" 'BEGIN { printf "%d", 25 + (p * 55 / 100) }')
                report_progress "Copying" "$scaled" "Copying files with rsync... ${pct}%"
            fi
        done < "$rsync_pipe"
        wait "$rsync_pid"
        rm -f "$rsync_pipe"
    else
        rsync -aHAX --info=progress2 $EXCLUDE_ARGS "${SRC%/}/" "$MNT"
    fi
else
    # fallback
    report_progress "Copying" 30 "Copying files..."
    cd "$SRC"
    for item in * .*; do
        # Skip '.' and '..'
        if [ "$item" = "." ] || [ "$item" = ".." ]; then continue; fi
        # Skip excluded dirs
        skip=0
        for e in $EXCLUDES; do
            [ "$item" = "$e" ] && skip=1
        done
        [ "$skip" -eq 1 ] && continue
        cp -a "$item" "$MNT/" || true
    done
    report_progress "Copying" 80 "File copy complete."
fi

# Create the directories we skipped during copying.
# Some paths may have parent directories that are symlinks to other
# excluded paths (e.g. /var -> private/var on FreeBSD).  In that case
# mkdir -p would fail because the symlink target is missing, so we
# first walk each path and resolve any dangling symlinks along the way.
for d in $EXCLUDES; do
    if [ ! -d "$MNT/$d" ]; then
        path="$MNT"
        rest="$d"
        while [ -n "$rest" ]; do
            part="${rest%%/*}"
            rest="${rest#*/}"
            path="$path/$part"
            if [ -L "$path" ] && [ ! -d "$path" ]; then
                tgt=$(readlink "$path")
                case "$tgt" in
                    /*) mkdir -p "$MNT$tgt" 2>/dev/null || true ;;
                    *)  mkdir -p "$(dirname "$path")/$tgt" 2>/dev/null || true ;;
                esac
            fi
            [ "$rest" = "$part" ] && rest=""
        done
        mkdir -p "$MNT/$d"
    fi
done
chmod 1777 "$MNT/tmp"

# For non-image installations, copy /boot from the ISO
if [ "$IMAGE_MODE" = "0" ] && [ -n "$MP" ]; then
    if [ -d "$MP/boot" ]; then
        report_progress "Copying" 82 "Copying boot files from ISO..."
        echo "Copying /boot from ISO location $MP..."
        mkdir -p "$MNT/boot"
        cp -a "$MP/boot"/* "$MNT/boot/"
    fi
fi

# For non-image installations, initialize /Local with dscli init in chroot
# This creates the default user "admin" with password "admin" and sets up DirectoryServices properly
if [ "$IMAGE_MODE" = "0" ]; then
    report_progress "Finalizing" 84 "Initializing system with dscli init..."
    if [ -d "$MNT/Local" ]; then
        echo "Wiping existing /Local in chroot before dscli init..."
        rm -rf "$MNT/Local"
    fi
    echo "Running dscli init in chroot..."
    chroot "$MNT" /bin/sh -c '. /System/Library/Makefiles/GNUstep.sh && /System/Library/Tools/dscli init' || true
    echo "Restarting dshelper in chroot..."
    chroot "$MNT" service dshelper restart || true
fi

# Install bootloader
report_progress "Bootloader" 82 "Installing bootloader..."
if [ "$BOOT_METHOD" = "UEFI" ]; then
    echo "Installing UEFI bootloader..."
    mkdir -p "$MNT/efi/EFI/BOOT"
    cp /boot/loader.efi "$MNT/efi/EFI/BOOT/BOOTX64.EFI"
    mkdir -p "$MNT/efi/EFI/freebsd"
    cp /boot/loader.efi "$MNT/efi/EFI/freebsd/loader.efi"

    # Register boot entry
    report_progress "Bootloader" 86 "Registering UEFI boot entry..."
    echo "Registering UEFI boot entry..."
    # Mount EFI partition to /boot/efi temporarily to help efibootmgr translate path
    umount "$MNT/efi"
    mkdir -p /boot/efi
    mount -t msdosfs "$EFI_PART" /boot/efi
    efibootmgr -c -d "$DISK" -p 1 -L "FreeBSD" -l /boot/efi/EFI/freebsd/loader.efi
    # Set as BootNext to ensure it boots from the new disk next time
    NEW_BOOT_ENTRY=$(efibootmgr | grep "FreeBSD" | head -n 1 | sed -E 's/.*Boot([0-9A-Fa-f]{4}).*/\1/')
    if [ -n "$NEW_BOOT_ENTRY" ]; then
        echo "Setting BootNext to $NEW_BOOT_ENTRY"
        efibootmgr -n -b "$NEW_BOOT_ENTRY"
    fi
    umount /boot/efi
else
    echo "BIOS bootloader already installed via gpart bootcode."
fi

# Write fstab
report_progress "Configuration" 90 "Writing filesystem table..."
cat > "$MNT/etc/fstab" <<EOF
$ROOT_PART   /      ufs   rw   1 1
EOF
if [ "$BOOT_METHOD" = "UEFI" ]; then
    cat >> "$MNT/etc/fstab" <<EOF
$EFI_PART    /efi   msdos rw   0 0
EOF
fi
cat >> "$MNT/etc/fstab" <<EOF
proc         /proc  procfs rw  0 0
EOF

# Configure loader
report_progress "Configuration" 93 "Configuring boot loader..."
cat >> "$MNT/boot/loader.conf" <<EOF
nvme_load="YES"
vfs.root.mountfrom="ufs:$ROOT_PART"
EOF

report_progress "Finalizing" 96 "Syncing filesystems..."
sync

report_progress "Finalizing" 98 "Unmounting target..."
# Unmount any bind mounts first
for dir in dev proc; do
    umount -f "$MNT/$dir" 2>/dev/null || true
    mkdir -p "$MNT/$dir"
done
umount_recursive

# Re-enable automounter now that we're done
enable_automounter

report_progress "Complete" 100 "Installation complete."
echo "=== COMPLETE ==="
echo "The system is now installed on $DISK."
echo "You may now restart your computer."
