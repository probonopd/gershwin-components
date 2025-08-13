# VNC and X11 Support Improvements

## Enhanced VNC Configuration

The BhyveAssistant now includes improved VNC support with better X11 compatibility:

### Key Improvements

1. **Enhanced Framebuffer Configuration**
   - **Resolution**: Increased from 1024x768 to 1280x1024 for better desktop experience
   - **Wait Mode**: Added `wait` parameter to improve synchronization with X11
   - **Better Mouse Support**: XHCI tablet device for absolute mouse positioning

2. **Multiple VNC Client Support**
   - Supports TigerVNC, TightVNC, and other VNC viewers
   - Tries multiple address formats automatically:
     - `localhost:5900` (full port format)
     - `localhost:0` (display number format)  
     - `:0` (short display format)
     - `localhost::5900` (double colon format)
     - `127.0.0.1:5900` (IP address format)

3. **X11 Compatibility Features**
   - Higher resolution framebuffer (1280x1024)
   - Wait mode for better synchronization
   - Enhanced error reporting and troubleshooting tips

### Troubleshooting X11 Issues

**If you can see the text console but not X11:**

1. **Be Patient**: X11 startup can take 10-30 seconds after text console appears
2. **Refresh VNC Viewer**: Try disconnecting and reconnecting your VNC client
3. **Check Resolution**: Some X11 sessions may need time to detect the framebuffer
4. **Monitor Logs**: Use the "Show Log" button to see X11 startup messages
5. **VM Configuration**: Ensure adequate RAM (2GB+) for X11 desktop environments

### VNC Connection Information

When you click the VNC button, the assistant will show:
- VNC port and display number
- Multiple connection address formats
- Troubleshooting tips specific to X11 issues
- Expected timing for X11 startup

### Technical Details

The bhyve framebuffer device (`fbuf`) is configured with:
```
-s 29:0,fbuf,tcp=0.0.0.0:5900,w=1280,h=1024,wait
-s 30:0,xhci,tablet
```

- **Slot 29**: Framebuffer device with VNC server
- **Slot 30**: USB tablet for better mouse handling
- **Wait Mode**: Synchronizes VM start with VNC client connection
- **Resolution**: 1280x1024 provides good compatibility with most X11 sessions

### Common X11 Desktop Environments

Tested with:
- **GhostBSD**: MATE desktop works well
- **FreeBSD Desktop**: Both KDE and GNOME compatible
- **Linux Live ISOs**: Most modern distributions work
- **Ubuntu/Debian**: Standard GNOME/KDE environments

### Performance Tips

- Allocate at least 2GB RAM for X11 desktops
- Use 2+ CPU cores for better performance
- VNC performance depends on network and VNC client efficiency
- Some desktop effects may be slower over VNC
