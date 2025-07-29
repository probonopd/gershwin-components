#!/bin/bash

# Dual D-Bus Daemon Comparison Tool
# Runs both MiniBus and real dbus-daemon, captures all traffic, and compares byte-for-byte

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SOCKET="/tmp/dbus-real.socket"
MINIBUS_SOCKET="/tmp/minibus-socket"
PROXY_REAL="/tmp/dbus-real-proxy.socket"
PROXY_MINIBUS="/tmp/dbus-minibus-proxy.socket"
CAPTURE_DIR="$SCRIPT_DIR/captures"
TEST_NAME="${1:-default}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

cleanup() {
    log "Cleaning up processes..."
    pkill -f "dbus-daemon.*$REAL_SOCKET" 2>/dev/null || true
    pkill -f "minibus" 2>/dev/null || true
    pkill -f "socat.*$PROXY_REAL" 2>/dev/null || true
    pkill -f "socat.*$PROXY_MINIBUS" 2>/dev/null || true
    rm -f "$REAL_SOCKET" "$MINIBUS_SOCKET" "$PROXY_REAL" "$PROXY_MINIBUS"
    sleep 1
}

analyze_capture() {
    local daemon_type="$1"
    local capture_file="$2"
    
    log "Analyzing $daemon_type capture..."
    
    # Extract raw bytes (socat -x format)
    python3 -c "
import re, sys

def extract_socat_bytes(filename):
    with open(filename, 'r') as f:
        content = f.read()
    
    # Find hex dump lines (format: > 2021/01/01 12:00:00.000000  length=16 from=0 to=15)
    # followed by hex bytes
    lines = content.split('\n')
    bytes_data = []
    
    for i, line in enumerate(lines):
        if 'length=' in line and ('from=' in line or 'to=' in line):
            # Next line should contain hex bytes
            if i + 1 < len(lines):
                hex_line = lines[i + 1].strip()
                # Extract hex bytes (format: 6c 02 01 01 ...)
                hex_matches = re.findall(r'[0-9a-fA-F]{2}', hex_line)
                if hex_matches:
                    bytes_data.extend([int(b, 16) for b in hex_matches])
    
    return bytes_data

bytes_list = extract_socat_bytes('$capture_file')
if bytes_list:
    print(f'Extracted {len(bytes_list)} bytes from $daemon_type')
    # Print as hex dump
    for i in range(0, len(bytes_list), 16):
        chunk = bytes_list[i:i+16]
        hex_str = ' '.join(f'{b:02x}' for b in chunk)
        print(f'{i:04x}: {hex_str}')
else:
    print(f'No bytes found in $daemon_type capture')
" > "$CAPTURE_DIR/${daemon_type}-bytes.txt"
}

compare_messages() {
    log "Comparing message formats..."
    
    if [[ -f "$CAPTURE_DIR/real-bytes.txt" && -f "$CAPTURE_DIR/minibus-bytes.txt" ]]; then
        python3 -c "
import sys

def read_bytes_file(filename):
    bytes_data = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
            for line in lines:
                if ':' in line and any(c in '0123456789abcdef' for c in line.lower()):
                    # Extract hex bytes from hex dump line
                    hex_part = line.split(':', 1)[1].strip()
                    hex_bytes = hex_part.split()
                    for hex_byte in hex_bytes:
                        if len(hex_byte) == 2 and all(c in '0123456789abcdef' for c in hex_byte.lower()):
                            bytes_data.append(int(hex_byte, 16))
    except Exception as e:
        print(f'Error reading {filename}: {e}')
    return bytes_data

real_bytes = read_bytes_file('$CAPTURE_DIR/real-bytes.txt')
minibus_bytes = read_bytes_file('$CAPTURE_DIR/minibus-bytes.txt')

print(f'Real daemon: {len(real_bytes)} bytes')
print(f'MiniBus: {len(minibus_bytes)} bytes')
print(f'Difference: {abs(len(real_bytes) - len(minibus_bytes))} bytes')

if real_bytes and minibus_bytes:
    print()
    print('Byte-by-byte comparison:')
    max_len = max(len(real_bytes), len(minibus_bytes))
    diff_count = 0
    
    for i in range(max_len):
        real_byte = real_bytes[i] if i < len(real_bytes) else None
        mini_byte = minibus_bytes[i] if i < len(minibus_bytes) else None
        
        if real_byte != mini_byte:
            diff_count += 1
            real_str = f'{real_byte:02x}' if real_byte is not None else '--'
            mini_str = f'{mini_byte:02x}' if mini_byte is not None else '--'
            print(f'  {i:4d}: Real={real_str} MiniBus={mini_str} DIFF')
        elif i < 32:  # Show first 32 matching bytes for context
            print(f'  {i:4d}: Real={real_byte:02x} MiniBus={mini_byte:02x} MATCH')
    
    if diff_count == 0:
        print('✓ Messages are byte-for-byte identical!')
    else:
        print(f'✗ Found {diff_count} byte differences')
"
    else
        error "Missing capture files for comparison"
    fi
}

run_test() {
    local test_command="$1"
    local test_name="$2"
    
    log "Running test: $test_name"
    
    # Clear old captures
    rm -f "$CAPTURE_DIR"/*-capture.log
    
    # Start traffic capture for both daemons
    timeout 30 socat -x -v unix-listen:"$PROXY_REAL",reuseaddr unix-connect:"$REAL_SOCKET" > "$CAPTURE_DIR/real-capture.log" 2>&1 &
    REAL_PROXY_PID=$!
    
    timeout 30 socat -x -v unix-listen:"$PROXY_MINIBUS",reuseaddr unix-connect:"$MINIBUS_SOCKET" > "$CAPTURE_DIR/minibus-capture.log" 2>&1 &
    MINIBUS_PROXY_PID=$!
    
    sleep 0.5
    
    # Test against real daemon
    log "Testing real dbus-daemon..."
    DBUS_SESSION_BUS_ADDRESS="unix:path=$PROXY_REAL" timeout 10 $test_command > "$CAPTURE_DIR/real-output.log" 2>&1 || true
    
    # Test against MiniBus
    log "Testing MiniBus..."
    DBUS_SESSION_BUS_ADDRESS="unix:path=$PROXY_MINIBUS" timeout 10 $test_command > "$CAPTURE_DIR/minibus-output.log" 2>&1 || true
    
    # Stop proxies
    kill $REAL_PROXY_PID $MINIBUS_PROXY_PID 2>/dev/null || true
    wait $REAL_PROXY_PID $MINIBUS_PROXY_PID 2>/dev/null || true
    
    # Analyze captures
    analyze_capture "real" "$CAPTURE_DIR/real-capture.log"
    analyze_capture "minibus" "$CAPTURE_DIR/minibus-capture.log"
    
    # Compare
    compare_messages
    
    # Show test outputs
    echo
    log "Real daemon output:"
    cat "$CAPTURE_DIR/real-output.log" || echo "(no output)"
    echo
    log "MiniBus output:"
    cat "$CAPTURE_DIR/minibus-output.log" || echo "(no output)"
}

# Main execution
log "Starting Dual D-Bus Daemon Comparison Tool"

# Create capture directory
mkdir -p "$CAPTURE_DIR"

# Initial cleanup
cleanup
trap cleanup EXIT

# Build MiniBus
log "Building MiniBus..."
cd "$SCRIPT_DIR"
if ! gmake minibus >/dev/null 2>&1; then
    error "Failed to build MiniBus"
    exit 1
fi
success "MiniBus built successfully"

# Start real dbus-daemon
log "Starting real dbus-daemon..."
dbus-daemon --session --address="unix:path=$REAL_SOCKET" --print-address --nofork > "$CAPTURE_DIR/real-daemon.log" 2>&1 &
REAL_DAEMON_PID=$!
sleep 1

if [[ ! -S "$REAL_SOCKET" ]]; then
    error "Real dbus-daemon failed to start"
    exit 1
fi
success "Real dbus-daemon started (PID: $REAL_DAEMON_PID)"

# Start MiniBus daemon
log "Starting MiniBus daemon..."
"$SCRIPT_DIR/obj/minibus" > "$CAPTURE_DIR/minibus-daemon.log" 2>&1 &
MINIBUS_DAEMON_PID=$!
sleep 1

if [[ ! -S "$MINIBUS_SOCKET" ]]; then
    error "MiniBus daemon failed to start"
    exit 1
fi
success "MiniBus daemon started (PID: $MINIBUS_DAEMON_PID)"

# Run tests based on arguments
if [[ $# -eq 0 ]]; then
    # Default test suite
    log "Running default test suite..."
    
    # Test Hello exchange only
    run_test "dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello" "Hello"
    
    echo
    warning "=== HELLO TEST COMPLETE ==="
    echo
    
    # Test ListNames
    run_test "dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames" "ListNames"
    
    echo
    warning "=== LISTNAMES TEST COMPLETE ==="
    echo
    
else
    # Custom test
    run_test "$*" "Custom"
fi

log "Comparison complete. Captures saved in $CAPTURE_DIR/"
