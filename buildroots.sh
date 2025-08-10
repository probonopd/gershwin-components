#!/bin/sh
# Build all projects and package them into tar.zst archives

# Projects to build
PROJECTS="BootEnvironments Display GlobalShortcuts StartupDisk LoginWindow globalshortcutsd SudoAskPass initgfx"

# Additional frameworks and tools
FRAMEWORKS="" # "Assistants/Framework"
EXAMPLES="" # "Assistants/DebianRuntimeInstaller"

export CC=clang
export OBJC=clang
export OBJCXX=clang++
export CXX=clang++

HERE="$(dirname "$(readlink -f "$0")")"

# Function to print build steps consistently
print_step() {
    echo "[buildroots.sh] $1"
}

# Function to create pkg manifest files on the fly
create_pkg_manifest() {
    local project_name="$1"
    local project_dir="$2"
    local stagedir="$3"
    local version="${4:-g$(date +%Y%m%d)}"
    
    # Create manifest file
    cat > "${project_dir}/+MANIFEST" << EOF
name: gershwin-${project_name}
version: ${version}
origin: sysutils/gershwin-${project_name}
comment: ${project_name}
arch: FreeBSD:14:amd64
www: https://github.com/probonopd/gershwin-components
maintainer: ports@FreeBSD.org
prefix: /usr/local
licenselogic: single
licenses: [BSD2CLAUSE]
categories: [gnustep, sysutils, x11]
desc: ${project_name}
EOF

    # Create compact desc file
    cat > "${project_dir}/+COMPACT_MANIFEST" << EOF
name: gershwin-${project_name}
version: ${version}
origin: sysutils/gershwin-${project_name}
comment: ${project_name}
arch: FreeBSD:14:amd64
prefix: /usr/local
EOF

    echo "Created pkg manifest files for ${project_name}"
}

# Function to create pkg file
create_pkg_file() {
    local project_name="$1"
    local project_dir="$2"
    local stagedir="$3"
    
    echo "Creating pkg file for ${project_name}..."
    
    # Ensure we have the manifest files
    if [ ! -f "${project_dir}/+MANIFEST" ]; then
        echo "Error: Missing +MANIFEST file for ${project_name}"
        return 1
    fi
    
    cd "${project_dir}"
    
    # Generate plist file from staging directory
    if [ -d "${stagedir}" ]; then
        echo "Generating plist file for ${project_name}..."
        # Include regular files
        find "${stagedir}" -type f -exec echo "{}" \; | sed "s|^${stagedir}||" > pkg-plist
        
        # Include symlinks (needed for projects like SudoAskPass that create command-line tools)
        find "${stagedir}" -type l -exec echo "{}" \; | sed "s|^${stagedir}||" >> pkg-plist
        
        # Include directories
        find "${stagedir}" -type d -exec echo "@dir {}" \; | sed "s|^@dir ${stagedir}|@dir |" | grep -v "^@dir $" >> pkg-plist
        
        echo "Generated plist with $(wc -l < pkg-plist) entries"
    else
        echo "Error: Staging directory ${stagedir} does not exist"
        return 1
    fi
    
    # Create the pkg file with plist
    if pkg create --verbose -r "${stagedir}" -m . -p pkg-plist -o .; then
        echo "Successfully created pkg file for ${project_name}"
        return 0
    else
        echo "Error: Failed to create pkg file for ${project_name}"
        return 1
    fi
}

print_step "Building all preference panes and tools..."

# Install build dependencies
# echo "Installing build dependencies..."
# sudo pkg install -y gnustep-make gnustep-base gnustep-gui gnustep-back gmake systempreferences || {
#     echo "Error: Failed to install build dependencies"
#     exit 1
# }
# echo "Build dependencies installed successfully"
# echo ""

# If GNUSTEP_MAKEFILES is not set, source GNUstep.sh to set it up
if [ -z "$GNUSTEP_MAKEFILES" ]; then
    . /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
fi

# Debug: Show GNUstep environment
echo "GNUstep environment:"
echo "  GNUSTEP_MAKEFILES=$GNUSTEP_MAKEFILES"
echo "  GNUSTEP_SYSTEM_HEADERS=$GNUSTEP_SYSTEM_HEADERS"
echo "  GNUSTEP_SYSTEM_LIBRARIES=$GNUSTEP_SYSTEM_LIBRARIES"
echo ""

# Check for PreferencePanes framework
if [ -d "/System/Library/Frameworks/PreferencePanes.framework" ]; then
    echo "Found PreferencePanes framework in /System/Library/Frameworks/"
elif [ -d "$GNUSTEP_SYSTEM_HEADERS/PreferencePanes" ]; then
    echo "Found PreferencePanes headers in $GNUSTEP_SYSTEM_HEADERS/PreferencePanes"
else
    echo "Warning: PreferencePanes framework not found, checking available frameworks..."
    echo "Available frameworks in /System/Library/Frameworks/:"
    ls -la /System/Library/Frameworks/ 2>/dev/null || echo "  Directory not found"
    echo "Available headers in $GNUSTEP_SYSTEM_HEADERS/:"
    ls -la "$GNUSTEP_SYSTEM_HEADERS/" 2>/dev/null || echo "  Directory not found"
fi
echo ""

# Ensure we're in the base directory
cd "$HERE"

SUCCESS_COUNT=0
FAIL_COUNT=0

# Build frameworks first (they may be dependencies for other projects)
echo "=== Building Frameworks ==="
for FRAMEWORK in $FRAMEWORKS; do
    echo "Building framework: $FRAMEWORK"
    
    cd "$HERE/$FRAMEWORK"
    
    # Clean previous build
    gmake clean > /dev/null 2>&1
    
    # Build framework
    if gmake; then
        echo "Framework $FRAMEWORK built successfully"
        
        # Install framework to system location (required for dependent projects)
        if sudo gmake install; then
            echo "Framework $FRAMEWORK installed successfully"
        else
            echo "Warning: Failed to install framework $FRAMEWORK"
        fi
        
        # Create root directory for packaging
        if [ -d root ]; then
            rm -rf root
        fi
        
        # Build and install with DESTDIR for packaging
        if gmake install DESTDIR=root; then
            if [ -d root ]; then
                echo "Creating ${FRAMEWORK}.tar.zst..."
                (cd root && tar --zstd -cf "../${FRAMEWORK}.tar.zst" .)
                echo "Created ${FRAMEWORK}.tar.zst"
                
                # Create pkg manifest and pkg file
                framework_lower=$(echo "$FRAMEWORK" | tr '[:upper:]' '[:lower:]')
                create_pkg_manifest "$framework_lower" "$HERE/$FRAMEWORK" "$HERE/$FRAMEWORK/root"
                create_pkg_file "$framework_lower" "$HERE/$FRAMEWORK" "$HERE/$FRAMEWORK/root"
                
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "Warning: No root directory created for $FRAMEWORK"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            echo "Error: Failed to package $FRAMEWORK"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "Error: Failed to build framework $FRAMEWORK"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    echo "Finished framework $FRAMEWORK"
    echo ""
done

# Build main projects
echo "=== Building Main Projects ==="

for PROJECT in $PROJECTS; do
    echo "Building $PROJECT..."
    
    # Check if project directory exists
    if [ ! -d "$HERE/$PROJECT" ]; then
        echo "Warning: Directory $PROJECT does not exist in $HERE, skipping..."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    cd "$HERE/$PROJECT"
    
    # Clean any existing root directory
    if [ -d root ]; then
        rm -rf root
    fi
    
    # Build and install with DESTDIR (continue on error)
    if gmake install DESTDIR=root; then
        # Create tar.zst archive if root directory exists
        if [ -d root ]; then
            echo "Creating ${PROJECT}.tar.zst..."
            (cd root && tar --zstd -cf "../${PROJECT}.tar.zst" .)
            echo "Created ${PROJECT}.tar.zst"
            
            # Create pkg manifest and pkg file
            project_lower=$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]')
            create_pkg_manifest "$project_lower" "$HERE/$PROJECT" "$HERE/$PROJECT/root"
            create_pkg_file "$project_lower" "$HERE/$PROJECT" "$HERE/$PROJECT/root"
            
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "Warning: No root directory created for $PROJECT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "Error: Failed to build $PROJECT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    echo "Finished $PROJECT"
    echo ""
done

echo "Build summary:"
echo "  Successful: $SUCCESS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo ""

# Create out directory and collect all archives and pkg files
echo "Collecting archives and pkg files into out/ directory..."
mkdir -p "$HERE/out"

COLLECTED_COUNT=0

# Collect framework archives and pkg files
for FRAMEWORK in $FRAMEWORKS; do
    if [ -f "$HERE/$FRAMEWORK/${FRAMEWORK}.tar.zst" ]; then
        echo "  Copying ${FRAMEWORK}.tar.zst to out/"
        cp "$HERE/$FRAMEWORK/${FRAMEWORK}.tar.zst" "$HERE/out/"
        COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
    fi
    
    # Look for pkg files with framework name (case insensitive)
    framework_lower=$(echo "$FRAMEWORK" | tr '[:upper:]' '[:lower:]')
    for pkg_file in "$HERE/$FRAMEWORK"/gershwin-"$framework_lower"-*.pkg; do
        if [ -f "$pkg_file" ]; then
            echo "  Copying $(basename "$pkg_file") to out/"
            cp "$pkg_file" "$HERE/out/"
            COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
        fi
    done
done

# Collect project archives and pkg files
for PROJECT in $PROJECTS; do
    if [ -f "$HERE/$PROJECT/${PROJECT}.tar.zst" ]; then
        echo "  Copying ${PROJECT}.tar.zst to out/"
        cp "$HERE/$PROJECT/${PROJECT}.tar.zst" "$HERE/out/"
        COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
    fi
    
    # Look for pkg files with project name (case insensitive)
    project_lower=$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]')
    for pkg_file in "$HERE/$PROJECT"/gershwin-"$project_lower"-*.pkg; do
        if [ -f "$pkg_file" ]; then
            echo "  Copying $(basename "$pkg_file") to out/"
            cp "$pkg_file" "$HERE/out/"
            COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
        fi
    done
done

echo ""
echo "Archives and pkg files collected in out/ directory: $COLLECTED_COUNT"
if [ "$COLLECTED_COUNT" -gt 0 ]; then
    echo "Contents of out/:"
    ls -la "$HERE/out/"*.tar.zst "$HERE/out/"*.pkg 2>/dev/null | while read -r line; do
        echo "  $line"
    done
fi

echo ""
print_step "=== Creating FreeBSD Package Repository ==="

# Get ABI information for repository structure
ABI=$(pkg config abi 2>/dev/null || echo "FreeBSD:14:amd64")
echo "Using ABI: $ABI"

# Create repository directory
REPO_DIR="$HERE/$ABI"
mkdir -p "$REPO_DIR"

# Count and move all .pkg files to repository directory
PKG_COUNT=0
echo "Moving all .pkg files to repository directory..."
for pkg_file in "$HERE"/*/*.pkg "$HERE/out"/*.pkg; do
    if [ -f "$pkg_file" ]; then
        echo "  Moving $(basename "$pkg_file") to $ABI/"
        mv "$pkg_file" "$REPO_DIR/"
        PKG_COUNT=$((PKG_COUNT + 1))
    fi
done

if [ "$PKG_COUNT" -gt 0 ]; then
    echo "Moved $PKG_COUNT package files to repository"
    
    # Create repository metadata
    echo "Creating repository metadata..."
    if pkg repo "$REPO_DIR/"; then
        echo "Repository metadata created successfully"
    else
        echo "Warning: Failed to create repository metadata"
    fi
    
    # Generate index.html for the repository
    echo "Generating index.html for repository..."
    cd "$REPO_DIR"
    echo "<html><head></head><body>" > index.html
    echo "<ul>" >> index.html
    find . -maxdepth 1 -name "*.pkg" -exec basename {} \; | sort | while read -r file; do
        echo "<li><a href=\"$file\" download>$file</a></li>" >> index.html
    done
    echo "</ul>" >> index.html
    echo "<p>Generated on $(date)</p>" >> index.html
    echo "</body></html>" >> index.html
    cd "$HERE"
    
    echo "Repository created in: $REPO_DIR"
    echo "Repository contents:"
    ls -la "$REPO_DIR"
    readlink -f "$REPO_DIR/index.html" || echo "No index.html generated"
    
else
    echo "No package files found to create repository"
fi

echo ""
echo "Build and packaging completed successfully!"
