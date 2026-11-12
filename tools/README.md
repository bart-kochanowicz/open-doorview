# Tools Directory

This directory was previously used for standalone shell scripts, but all functionality is now managed through the Makefile automation system.

All recovery procedures should be executed using the Makefile targets:

```bash
make check-tools     # Verify all required tools are installed
make discover-ports  # Discover available serial ports  
make backup-flash    # Perform SPI flash backup
make analyze-firmware # Analyze firmware image
```

The individual scripts have been deprecated in favor of the centralized Makefile approach which provides better organization and consistency.