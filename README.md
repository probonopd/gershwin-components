# FreeBSD Boot Environments Manager

This is a GNUstep application for managing FreeBSD boot environments. The application provides a graphical interface to:

## Features

- **Show boot environments**: Display all available boot environments in a table view
- **Create New Configurations**: Add new boot environments with custom kernel, root filesystem, and boot options
- **Edit Configurations**: Modify existing boot environments
- **Switch Active Configuration**: Set which configuration should be used as the default boot option
- **Delete Configurations**: Remove unwanted boot environments
- **Real-time Logging**: View operation logs in a dedicated log panel

## Building

To build the application, you need to first set up the GNUstep environment and then use the GNU make system:

```bash
bash -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && cd src && gmake"
```

## Running

### As Regular User (Read-Only Mode)
To run the application as a regular user (view-only mode):

```bash
bash -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && cd src && openapp ./BootEnvironments.app"
```

**Note:** Running as a regular user will only allow viewing existing boot environments. Creating, deleting, or modifying boot environments requires root privileges.

### As Root (Full Functionality)
To run the application with full functionality (create/delete boot environments):

```bash
sudo bash -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && cd src && openapp ./BootEnvironments.app"
```

Or use the provided script:

```bash
cd src && ../run_as_root.sh
```

**Important:** Creating and deleting ZFS boot environments requires root privileges because it uses the `bectl` command which needs administrative access to modify the ZFS filesystem.

### Build Requirements

- GNUstep development environment installed
- GNU make (gmake)
- GCC or Clang compiler with Objective-C support

The GNUstep environment setup script (`GNUstep.sh`) configures the necessary environment variables including:
- `GNUSTEP_MAKEFILES`: Path to GNUstep makefiles
- `GNUSTEP_SYSTEM_ROOT`: GNUstep system root directory
- Library and include paths for compilation

## Usage

1. **Viewing Configurations**: The main table shows all available boot environments
2. **Creating a Boot Environment**: 
   - Click "Create New" to open the creation dialog
   - Fill in the Name field (required) - this will be the ZFS boot environment name
   - Optionally modify kernel path and other options
   - Click "OK" to create the boot environment using `bectl create`
   - **Note:** Requires root privileges to actually create the ZFS boot environment
3. **Editing a Configuration**: 
   - Select a configuration from the table
   - Click "Edit" to modify the configuration
   - Make changes and click "OK" to save
4. **Setting Active Configuration**: 
   - Select a configuration from the table
   - Click "Set Active" to make it the default boot option
5. **Deleting a Configuration**: 
   - Select a configuration from the table
   - Click "Delete" and confirm the action
6. **Refreshing the List**: 
   - Click "Refresh" to reload boot environments from the system
   - This will show any changes made outside the application

## Important Notes

- **Root Privileges**: The application will warn you if not running as root. While you can view boot environments as a regular user, creating, deleting, or modifying them requires root privileges.
- **ZFS Boot Environment Integration**: The application uses `bectl list` to detect existing ZFS boot environments and `bectl create` to create new ones.
- **Verbose Logging**: All operations are logged to the console with detailed information about what commands are being executed.
- **Error Handling**: Failed operations will show error dialogs with details about what went wrong.

## Testing the Application

### Testing Boot Environment Creation

1. **Run as Regular User** (to see the warning):
   ```bash
   bash -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && openapp ./BootEnvironments.app"
   ```
   - You should see a warning in the console about not running as root
   - You can view existing boot environments, but creating new ones will fail

2. **Run as Root** (for full functionality):
   ```bash
   sudo bash -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && openapp ./BootEnvironments.app"
   ```
   - No warning about root privileges
   - You can create, delete, and modify boot environments

3. **Test Creation**:
   - Click "Create New" 
   - Enter a test name like "test-be-001"
   - Click "OK"
   - Check the console output for detailed `bectl create` logging
   - Click "Refresh" to verify the boot environment was actually created

4. **Verify with Command Line**:
   ```bash
   bectl list
   ```
   - The new boot environment should appear in the list
