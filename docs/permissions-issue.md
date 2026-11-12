# Serial Port Permissions Issue

When working with serial ports on Linux systems, you might encounter permission issues like:

```
FATAL: cannot open /dev/ttyUSB0: Permission denied
```

## Solution

To resolve this issue, you need to add your user to the `dialout` group:

1. **Add user to dialout group**:
   ```bash
   sudo usermod -a -G dialout $USER
   ```

2. **Log out and log back in** (or reboot) for the group membership to take effect.

3. **Alternative: Grant direct permissions** (if you can't modify groups):
   ```bash
   sudo chmod 666 /dev/ttyUSB0
   ```

## Verify Group Membership

After logging back in, verify your group membership:
```bash
groups
```

You should see `dialout` included in the list.

## Why This Happens

Linux systems restrict access to serial ports for security reasons. The `/dev/ttyUSB*` and `/dev/ttyACM*` devices are typically owned by the `dialout` group, which your user account needs to be a member of in order to access them.