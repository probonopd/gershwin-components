#!/bin/sh
# Build all projects and package them into tar.zst archives

# Projects to build
PROJECTS="BootEnvironments Display GlobalShortcuts StartupDisk LoginWindow globalshortcutsd"

# Additional frameworks and tools
FRAMEWORKS="AssistantFramework"
EXAMPLES="ExampleAssistants"

export CC=clang
export OBJC=clang
export OBJCXX=clang++
export CXX=clang++

HERE="$(dirname "$(readlink -f "$0")")"

# Function to create pkg manifest files on the fly
create_pkg_manifest() {
    local project_name="$1"
    local project_dir="$2"
    local stagedir="$3"
    local version="${4:-m}"
    
    # Create manifest file
    cat > "${project_dir}/+MANIFEST" << EOF
name: gershwin-${project_name}
version: ${version}
origin: sysutils/gershwin-${project_name}
comment: ${project_name}
arch: FreeBSD:14:amd64
www: https://github.com/probonopd/gershwin-prefpanes
maintainer: ports@FreeBSD.org
prefix: /usr/local
licenselogic: single
licenses: [BSD2CLAUSE]
categories: [gnustep, sysutils, x11]
desc: |
  ${project_name}
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
    
    # Create the pkg file
    if pkg create --verbose -r "${stagedir}" -m . -o .; then
        echo "Successfully created pkg file for ${project_name}"
        return 0
    else
        echo "Error: Failed to create pkg file for ${project_name}"
        return 1
    fi
}

echo "Building all preference panes and tools..."

# Install build dependencies
echo "Installing build dependencies..."
sudo pkg install -y gnustep-make gnustep-base gnustep-gui gnustep-back gmake systempreferences || {
    echo "Error: Failed to install build dependencies"
    exit 1
}
echo "Build dependencies installed successfully"
echo ""

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