#!/bin/sh

# Test script to simulate running on a non-FreeBSD system
# This temporarily renames the uname binary to test the error handling

echo "Testing BhyveAssistant system requirements check..."

# Backup the real uname
if [ -f /usr/bin/uname ]; then
    sudo mv /usr/bin/uname /usr/bin/uname.bak
fi

# Create a fake uname that returns "Linux"
sudo tee /usr/bin/uname > /dev/null << 'EOF'
#!/bin/sh
echo "Linux"
EOF

sudo chmod +x /usr/bin/uname

echo "Running BhyveAssistant with fake OS..."
cd /home/User/gershwin-components/Assistants/BhyveAssistant
./BhyveAssistant.app/BhyveAssistant &

# Wait a bit for the assistant to start and show error
sleep 5

# Restore the real uname
sudo rm -f /usr/bin/uname
if [ -f /usr/bin/uname.bak ]; then
    sudo mv /usr/bin/uname.bak /usr/bin/uname
fi

echo "Test complete. The assistant should have shown a system requirements error."
