#!/usr/bin/env bash

# Create a test service directory
mkdir -p ~/.local/share/dbus-1/services

# Create a simple test service
cat > ~/.local/share/dbus-1/services/org.example.TestService.service << EOF
[D-BUS Service]
Name=org.example.TestService
Exec=/home/User/gershwin-prefpanes/minibus/test-service
EOF

echo "Created test service file: ~/.local/share/dbus-1/services/org.example.TestService.service"

# Create a simple test service executable
cat > /home/User/gershwin-prefpanes/minibus/test-service << 'EOF'
#!/usr/bin/env python3

import os
import sys
import time
import socket
import struct

def main():
    print("Test service starting up...")
    
    # Get D-Bus address from environment
    dbus_address = os.environ.get('DBUS_STARTER_ADDRESS')
    if not dbus_address:
        print("Error: DBUS_STARTER_ADDRESS not set")
        sys.exit(1)
    
    print(f"Connecting to D-Bus at: {dbus_address}")
    
    # Parse unix socket address
    if dbus_address.startswith('unix:path='):
        socket_path = dbus_address[10:]  # Remove 'unix:path=' prefix
        
        # Connect to the socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(socket_path)
            print(f"Connected to D-Bus socket: {socket_path}")
            
            # Send authentication (simple NULL auth)
            sock.send(b'\0AUTH\r\n')
            
            # Read response
            response = sock.recv(1024)
            print(f"Auth response: {response}")
            
            # Send BEGIN
            sock.send(b'BEGIN\r\n')
            
            # Simple Hello message (we'll just sleep for now since full D-Bus is complex)
            print("Test service is now 'running' - sleeping for 30 seconds")
            time.sleep(30)
            
        except Exception as e:
            print(f"Error connecting to D-Bus: {e}")
        finally:
            sock.close()
    else:
        print(f"Unsupported D-Bus address format: {dbus_address}")
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF

chmod +x /home/User/gershwin-prefpanes/minibus/test-service

echo "Created test service executable: /home/User/gershwin-prefpanes/minibus/test-service"
echo
echo "To test activation:"
echo "1. Start minibus daemon"
echo "2. Call: gdbus call --session --dest org.example.TestService --object-path /test --method org.example.TestService.Hello"
