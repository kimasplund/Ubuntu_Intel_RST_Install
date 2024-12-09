# Ubuntu 24.04, 24.10, 25.04 Installation with Intel RST RAID

For some strange reason, the standard Ubuntu installer doesn't work with Intel RST RAID even though it's supported and you can see the disk in GParted etc.

The Canonical solution to this (https://help.ubuntu.com/rst/) seems like an awful solution and is prone to break your Windows installation.

This guide will install Ubuntu to the RAID array and then install the bootloader to the Windows disk.

## System Configuration Example
Lenovo ThinkPad P16 Gen2
- Intel RST RAID 0 array with 2x Samsung 990 PRO 2TB NVMe
- Windows installed on RAID array
- Partition layout on `/dev/md126`:
  - EFI: `md126p1` (260M)
  - MSR: `md126p2` (16M)
  - Windows: `md126p3` (1.7T)
  - Recovery: `md126p4` (2G) *(can be moved to the beginning of free space, but not needed)*
  - Linux: `md126p5` (488.3G)

## Installation Steps

1. **Prepare Windows Partition**
   - Resize the Windows partition in Windows Disk Management to create space for Ubuntu
   - Note: Lenovo recovery image uses all diskspace by default

2. **Boot Ubuntu Live USB**
   - Select "Try Ubuntu" option

3. **Create Partitions**
   - Use GParted to create new partition(s) on the RAID array with your prefered filesystem.
   - Create separate partitions for `/boot`, `/home`, `/var` etc. if desired

4. **Mount Partitions**   ```bash
   sudo mount /dev/md126p5 /mnt
   sudo mkdir -p /mnt/boot/efi
   sudo mount /dev/md126p1 /mnt/boot/efi   ```

5. **Install Base System**   ```bash
   sudo debootstrap --arch amd64 plucky /mnt http://archive.ubuntu.com/ubuntu/   ```
   Available versions:
   - 25.04: plucky
   - 24.10: oracular
   - 24.04: noble
   - 22.04: jammy
   - 20.04: focal
   - 18.04: bionic

6. **Mount Essential Filesystems**   ```bash
   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys /mnt/sys   ```

7. **Enter chroot**   ```bash
   cd /mnt
   sudo chroot /mnt /bin/bash   ```

8. **Configure Package Sources**   ```bash
   cat > /etc/apt/sources.list << EOF
   deb http://archive.ubuntu.com/ubuntu/ plucky main restricted universe multiverse
   deb http://archive.ubuntu.com/ubuntu/ plucky-updates main restricted universe multiverse
   deb http://security.ubuntu.com/ubuntu/ plucky-security main restricted universe multiverse
   EOF   ```

9. **Install Essential Packages**   ```bash
   apt update
   apt install linux-image-generic mdadm grub-efi-amd64 ubuntu-desktop network-manager   ```

10. **Configure System**    ```bash
    # Set hostname
    echo "your-hostname" > /etc/hostname

    # Set up fstab
    echo "UUID=$(blkid -s UUID -o value /dev/md126p5) /               ext4    errors=remount-ro 0       1" >> /etc/fstab
    echo "UUID=$(blkid -s UUID -o value /dev/md126p1) /boot/efi       vfat    umask=0077      0       1" >> /etc/fstab    ```

11. **Configure GRUB**    ```bash
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
    echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
    update-grub    ```

12. **Finalize Installation**    ```bash
    # Update initramfs
    update-initramfs -u -k all

    # Enable NetworkManager
    systemctl enable NetworkManager

    # Exit chroot
    exit    ```

13. **Cleanup and Reboot**    ```bash
    sudo umount /mnt/dev
    sudo umount /mnt/proc
    sudo umount /mnt/sys
    sudo umount /mnt/boot/efi
    sudo umount /mnt
    sudo reboot    ```

You will need to do some manual configurations in Ubuntu after like keyboard layout, timezone, etc.
You should now have a working Ubuntu installation on your RAID array.

## Notes
If grub dont show you boot options, you can always just press Enter and select F12 when booting your system to get available EFI boot options and select Windows etc there.

Or install The rEFInd Boot Manager to get a nice GUI for selecting your boot options.

https://www.rodsbooks.com/refind/getting-started.html

## Author
Kim Asplund  
https://asplund.kim

open a issue if you want to add/change something to this guide.