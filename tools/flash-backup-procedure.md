# SPI Flash Backup Procedure - RH-PD10

## Overview
This document details the procedure for creating a verified backup of the original SPI flash memory from the RH-PD10 device.

## Safety Requirements
Before proceeding with any flash operations, ensure:
1. **Battery Disconnected**: Remove the device battery completely
2. **USB Power Off**: Disconnect all USB power sources
3. **Voltage Verification**: Confirm 1.8V signal levels on all pins  
4. **Adapter Compatibility**: Verify CH341A adapter supports 1.8V signaling
5. **Proper Orientation**: Confirm SOIC-8 clip orientation matches chip packaging

## Hardware Preparation
1. Power off the device completely
2. Remove the battery 
3. Disconnect any USB power cables
4. Identify the Winbond W25Q64JWSSIQ SPI flash chip on the PCB
5. Verify chip orientation with the SOP-8 package (208 mil spacing)

## Flashrom Configuration
The CH341A adapter needs to be properly configured for 1.8V operation:
```bash
# Check if CH341A is detected by flashrom
flashrom -p ch341a_spi --listchips

# Verify voltage settings for proper 1.8V signal levels
flashrom -p ch341a_spi -V
```

## Backup Procedure
1. **Initial Flash Detection**:
   ```bash
   flashrom -p ch341a_spi -r backup_initial.bin
   ```

2. **Second Backup for Verification**:
   ```bash
   flashrom -p ch341a_spi -r backup_verification.bin
   ```

3. **Hash Verification**:
   ```bash
   shasum -a 256 backup_initial.bin backup_verification.bin
   ```

## Expected Results
- Two identical backup files created
- Consistent SHA-256 hashes for both backups
- 8MiB (64Mbit) flash memory content
- No error messages during backup process

## Recovery Considerations
- **Never overwrite original** without complete verification backup
- Store backups securely away from repository - they may contain device secrets
- Keep backups in encrypted storage if required by security policies
- Document any differences between the two backup attempts

## Potential Issues
1. **Communication Errors**: Check CH341A adapter voltage settings
2. **Inconsistent Backups**: May indicate faulty connection or chip degradation
3. **No Device Response**: Confirm correct chip identification and adapter compatibility