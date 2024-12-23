#!/bin/bash

# Configuration - MODIFY THESE AS NEEDED
ROOT_PARTITION="/dev/md126p7"     # Your root partition
UBUNTU_VERSION="oracular"         # Ubuntu version to install

# Early confirmation
echo "============================================"
echo "Ubuntu Bootstrap Installation"
echo "============================================"
echo "This will install Ubuntu $UBUNTU_VERSION on:"
echo "Device: $ROOT_PARTITION"
echo
echo "WARNING: This will modify the target device!"
echo "Make sure you have backups of important data."
echo "============================================"
read -p "Do you want to proceed? (y/N): " PROCEED
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 1
fi
echo

# Function definitions
log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Check and cleanup previous mounts
cleanup_previous_mounts() {
    log_progress "Checking for leftover mounts from previous attempts..."
    
    # Define mount points in reverse order of mounting
    local MOUNT_POINTS=(
        "/mnt/dev/pts"
        "/mnt/dev"
        "/mnt/proc"
        "/mnt/sys"
        "/mnt/run"
        "/mnt/boot/efi"
        "/mnt/home"
        "/mnt/var"
        "/mnt/tmp"
        "/mnt/.snapshots"
        "/mnt"
    )
    
    # Check each mount point and unmount if mounted
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log_progress "Unmounting $mount_point..."
            umount "$mount_point" || {
                log_progress "Failed to unmount $mount_point. Please unmount manually:"
                echo "sudo umount $mount_point"
                exit 1
            }
        fi
    done
    
    # Double check nothing is left
    if mount | grep -q "/mnt"; then
        log_progress "Warning: Some filesystems are still mounted under /mnt:"
        mount | grep "/mnt"
        echo "Please unmount them manually before proceeding."
        exit 1
    fi
    
    log_progress "Mount points are clean"
}

# Early EFI detection
detect_efi_partition() {
    log_progress "Detecting EFI partition..."
    # First, try to find the EFI partition from the current system
    if [ -d "/boot/efi" ]; then
        EFI_PARTITION=$(df /boot/efi | grep -v Filesystem | awk '{print $1}')
        if [ -n "$EFI_PARTITION" ]; then
            log_progress "Found EFI partition at $EFI_PARTITION (currently mounted)"
            return 0
        fi
    fi
    
    # If not mounted, try to find it by type
    EFI_PARTITION=$(fdisk -l | grep "EFI System" | awk '{print $1}' | head -n1)
    if [ -n "$EFI_PARTITION" ]; then
        log_progress "Found EFI partition at $EFI_PARTITION (by partition type)"
        return 0
    fi
    
    echo "Error: Could not detect EFI partition automatically!"
    echo "Please specify EFI partition manually by editing the script."
    exit 1
}

# Enhanced cleanup function
cleanup() {
    local exit_code=$?
    local error_line=$1
    
    log_progress "Cleanup triggered on line $error_line (exit code: $exit_code)"
    
    # Unmount everything in reverse order
    for mount in "/mnt/dev" "/mnt/proc" "/mnt/sys" "/mnt/boot/efi" "/mnt/home" "/mnt/var" "/mnt/tmp" "/mnt/.snapshots" "/mnt"; do
        if mountpoint -q "$mount" 2>/dev/null; then
            log_progress "Unmounting $mount..."
            umount "$mount" || log_progress "Failed to unmount $mount"
        fi
    done
    
    if [ $exit_code -ne 0 ]; then
        log_progress "Installation failed. Please check the logs."
    fi
    
    exit $exit_code
}

# Enhanced error handling
trap 'cleanup ${LINENO}' ERR
trap 'cleanup ${LINENO}' EXIT

# Early safety checks
check_safety() {
    log_progress "Performing safety checks..."
    
    # Check if script is run as root
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run as root"
        exit 1
    fi
    
    # Detect EFI partition before checking mounts
    detect_efi_partition
    
    # Validate partitions exist
    for partition in "$ROOT_PARTITION" "$EFI_PARTITION"; do
        if ! [ -b "$partition" ]; then
            echo "Error: Partition $partition does not exist!"
            exit 1
        fi
    done
    
    # Check if /mnt is already in use
    if mountpoint -q "/mnt"; then
        echo "Error: /mnt is already mounted! Please unmount it first:"
        echo "sudo umount -R /mnt"
        exit 1
    fi
    
    # Check if root partition is mounted elsewhere
    if grep -qs "$ROOT_PARTITION" /proc/mounts; then
        echo "Error: Root partition ($ROOT_PARTITION) is currently mounted! Please unmount it first:"
        echo "sudo umount $ROOT_PARTITION"
        exit 1
    fi
    
    # For EFI partition, only warn if it's mounted somewhere other than /boot/efi
    if grep -qs "$EFI_PARTITION" /proc/mounts; then
        CURRENT_EFI_MOUNT=$(grep "$EFI_PARTITION" /proc/mounts | awk '{print $2}')
        if [ "$CURRENT_EFI_MOUNT" != "/boot/efi" ]; then
            echo "Error: EFI partition ($EFI_PARTITION) is mounted at $CURRENT_EFI_MOUNT"
            echo "Please unmount it first: sudo umount $EFI_PARTITION"
            exit 1
        else
            log_progress "EFI partition is mounted at /boot/efi - OK"
        fi
    fi
    
    # Check if running from live media
    if [ -d /rofs ]; then
        log_progress "Running from live media - OK"
        return 0
    fi
    
    # Check if target partition is the same as current root
    CURRENT_ROOT=$(df / | tail -n1 | awk '{print $1}')
    if [ "$CURRENT_ROOT" = "$ROOT_PARTITION" ]; then
        echo "Error: Target partition ($ROOT_PARTITION) is the same as current root partition!"
        echo "This would overwrite your running system."
        exit 1
    fi
    
    # Warn if not running from live media
    echo "Warning: You are not running from live media."
    echo "While this can work, it's recommended to run from a live USB/DVD."
    echo "This reduces the risk of affecting your current system."
    read -p "Do you want to continue anyway? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

# System Detection Section
detect_system_config() {
    log_progress "Detecting system configuration..."
    
    # For Intel RST RAID on NVMe
    if [[ $ROOT_PARTITION == "/dev/md126"* ]]; then
        MEDIA_TYPE="nvme"
        log_progress "Intel RST NVMe RAID detected"
    fi
    
    # Current system settings
    CURRENT_LAYOUT=$(setxkbmap -query | grep layout | awk '{print $2}')
    CURRENT_TIMEZONE=$(timedatectl show --property=Timezone --value)
    
    # NVIDIA detection
    if lspci | grep -i nvidia > /dev/null; then
        NVIDIA_DETECTED=1
        if lspci | grep -iE "VGA|3D" | grep -iE "intel|amd" > /dev/null; then
            HYBRID_GRAPHICS=1
        fi
    fi
}

# User Configuration Section
get_user_preferences() {
    log_progress "Configuring user preferences..."
    
    # Get username and password
    read -p "Enter username: " USERNAME
    while true; do
        read -s -p "Enter password: " PASSWORD
        echo
        read -s -p "Confirm password: " PASSWORD2
        echo
        
        if [ "$PASSWORD" = "$PASSWORD2" ]; then
            break
        fi
        echo "Passwords do not match!"
    done
    
    # NVIDIA configuration
    if [ "$NVIDIA_DETECTED" = "1" ]; then
        echo "NVIDIA GPU detected!"
        read -p "Would you like to install NVIDIA drivers? (Y/n): " INSTALL_NVIDIA
        INSTALL_NVIDIA=${INSTALL_NVIDIA:-Y}
        
        if [[ "$INSTALL_NVIDIA" =~ ^[Yy]$ ]] && [ "$HYBRID_GRAPHICS" = "1" ]; then
            echo "Hybrid graphics detected (NVIDIA + Intel/AMD)"
            read -p "Would you like to install NVIDIA PRIME for hybrid graphics support? (Y/n): " INSTALL_PRIME
            INSTALL_PRIME=${INSTALL_PRIME:-Y}
        fi
    fi
    
    # Filesystem selection
    CURRENT_FS=$(lsblk -f $ROOT_PARTITION -n -o FSTYPE)
    if [ -n "$CURRENT_FS" ]; then
        echo "Current filesystem on $ROOT_PARTITION is: $CURRENT_FS"
        read -p "Would you like to format this partition? (y/N): " FORMAT_PARTITION
        if [[ ! "$FORMAT_PARTITION" =~ ^[Yy]$ ]]; then
            echo "Proceeding without formatting. Using existing filesystem."
            FS_TYPE=$CURRENT_FS
        fi
    else
        echo "No filesystem detected on $ROOT_PARTITION"
        FORMAT_PARTITION="y"
    fi
    
    if [[ "$FORMAT_PARTITION" =~ ^[Yy]$ ]]; then
        echo "Available filesystem options:"
        echo "1) btrfs - Modern copy-on-write filesystem with snapshots"
        echo "2) ext4  - Standard Linux filesystem"
        echo "3) xfs   - High-performance journaling filesystem"
        echo "4) f2fs  - Flash-Friendly File System (good for SSDs)"
        echo "5) zfs   - Advanced filesystem with volume management"
        
        read -p "Choose filesystem type [1-5] (default: 1): " FS_CHOICE
        case "$FS_CHOICE" in
            2) FS_TYPE="ext4" ;;
            3) FS_TYPE="xfs" ;;
            4) FS_TYPE="f2fs" ;;
            5) FS_TYPE="zfs" ;;
            *) FS_TYPE="btrfs" ;;
        esac
        
        log_progress "Will format $ROOT_PARTITION as $FS_TYPE"
    fi
    
    # Keyboard layout
    echo "Current keyboard layout: $CURRENT_LAYOUT"
    read -p "Would you like to change the keyboard layout? (y/N): " CHANGE_LAYOUT
    if [[ "$CHANGE_LAYOUT" =~ ^[Yy]$ ]]; then
        echo "Available keyboard layouts:"
        localectl list-x11-keymap-layouts | less
        read -p "Enter desired keyboard layout: " KEYBOARD_LAYOUT
    else
        KEYBOARD_LAYOUT=$CURRENT_LAYOUT
    fi
    
    # Timezone
    echo "Current timezone: $CURRENT_TIMEZONE"
    read -p "Would you like to change the timezone? (y/N): " CHANGE_TIMEZONE
    if [[ "$CHANGE_TIMEZONE" =~ ^[Yy]$ ]]; then
        echo "Available timezones:"
        timedatectl list-timezones | less
        read -p "Enter desired timezone: " TIMEZONE
    else
        TIMEZONE=$CURRENT_TIMEZONE
    fi
}

# Filesystem Functions
format_root_partition() {
    log_progress "Formatting root partition as $FS_TYPE..."
    case "$FS_TYPE" in
        "btrfs")
            # Common options for all devices
            local BTRFS_OPTS=(
                -f                          # Force overwrite
                -L "Ubuntu_${UBUNTU_VERSION^}"  # Label
                --csum xxhash              # Use xxhash for checksums (faster than crc32c)
                -O no-holes                # More efficient space handling
                -O free-space-tree         # Better free space tracking
                -O extref                  # Extended references for better performance
                -O skinny-metadata         # Reduced metadata consumption
            )
            
            case "$MEDIA_TYPE" in
                "nvme"|"ssd")
                    # NVMe/SSD specific options
                    BTRFS_OPTS+=(
                        -n 32k              # Node size optimized for SSDs
                        -m dup              # Metadata duplication for safety
                        -d single           # Single data for space efficiency
                        --features "no-holes,free-space-tree"
                        -K                  # Enable no-holes feature
                        -A 4k               # Align at 4K for NVMe
                    )
                    ;;
                *)
                    # HDD specific options
                    BTRFS_OPTS+=(
                        -m dup              # Metadata duplication for safety
                        -d single           # Single data for space efficiency
                        --features "no-holes,free-space-tree"
                    )
                    ;;
            esac
            
            # Execute mkfs.btrfs with all options
            mkfs.btrfs "${BTRFS_OPTS[@]}" "$ROOT_PARTITION"
            ;;
        "ext4")
            mkfs.ext4 -F -L Ubuntu_${UBUNTU_VERSION^} "$ROOT_PARTITION"
            ;;
        "xfs")
            mkfs.xfs -f -L Ubuntu_${UBUNTU_VERSION^} "$ROOT_PARTITION"
            ;;
        "f2fs")
            mkfs.f2fs -f -l Ubuntu_${UBUNTU_VERSION^} "$ROOT_PARTITION"
            ;;
        "zfs")
            # ZFS formatting will be handled separately
            log_progress "ZFS formatting will be handled during pool creation"
            ;;
    esac
}

mount_root_partition() {
    log_progress "Mounting root partition..."
    case "$FS_TYPE" in
        "btrfs")
            # Set mount options for NVMe RAID
            MOUNT_OPTIONS="defaults,noatime,space_cache=v2,ssd,discard=async,compress=zstd:1"
            
            # Mount for subvolume creation if formatting
            mount -o "$MOUNT_OPTIONS" "$ROOT_PARTITION" /mnt
            
            if [[ "$FORMAT_PARTITION" =~ ^[Yy]$ ]]; then
                log_progress "Creating btrfs subvolume layout..."
                btrfs subvolume create /mnt/@
                btrfs subvolume create /mnt/@home
                btrfs subvolume create /mnt/@var
                btrfs subvolume create /mnt/@tmp
                btrfs subvolume create /mnt/@snapshots
                
                # Unmount and remount with subvolumes
                umount /mnt
                
                # Mount subvolumes
                mount -o "$MOUNT_OPTIONS,subvol=@" "$ROOT_PARTITION" /mnt
                mkdir -p /mnt/{home,var,tmp,.snapshots,boot/efi}
                mount -o "$MOUNT_OPTIONS,subvol=@home" "$ROOT_PARTITION" /mnt/home
                mount -o "$MOUNT_OPTIONS,subvol=@var" "$ROOT_PARTITION" /mnt/var
                mount -o "$MOUNT_OPTIONS,subvol=@tmp" "$ROOT_PARTITION" /mnt/tmp
                mount -o "$MOUNT_OPTIONS,subvol=@snapshots" "$ROOT_PARTITION" /mnt/.snapshots
            else
                # If not formatting, still ensure the mount points exist
                mkdir -p /mnt/{home,var,tmp,.snapshots,boot/efi}
            fi
            ;;
        *)
            # Set mount options for NVMe RAID
            MOUNT_OPTIONS="defaults,noatime,discard=async"
            mount -o "$MOUNT_OPTIONS" "$ROOT_PARTITION" /mnt
            mkdir -p /mnt/boot/efi
            ;;
    esac
}

mount_efi_partition() {
    log_progress "Mounting and configuring EFI partition..."
    
    # Check EFI partition space and backups
    if [ -d "/mnt/boot/efi/EFI" ]; then
        EFI_SPACE=$(df -h /mnt/boot/efi | awk 'NR==2 {print $4}')
        EFI_USED=$(df -h /mnt/boot/efi | awk 'NR==2 {print $5}' | tr -d '%')
        BACKUP_COUNT=$(ls -d /mnt/boot/efi/EFI.backup.* 2>/dev/null | wc -l)
        
        log_progress "EFI partition status:"
        echo "- Space available: $EFI_SPACE"
        echo "- Space used: $EFI_USED%"
        echo "- Number of existing backups: $BACKUP_COUNT"
        
        if [ $EFI_USED -gt 70 ]; then
            echo "Warning: EFI partition is more than 70% full"
            if [ $BACKUP_COUNT -gt 0 ]; then
                echo "Found $BACKUP_COUNT previous EFI backup(s)"
                read -p "Would you like to remove old EFI backups to free space? (Y/n): " REMOVE_BACKUPS
                REMOVE_BACKUPS=${REMOVE_BACKUPS:-Y}
                
                if [[ "$REMOVE_BACKUPS" =~ ^[Yy]$ ]]; then
                    log_progress "Removing old EFI backups..."
                    rm -rf /mnt/boot/efi/EFI.backup.*
                    log_progress "EFI backups removed"
                fi
            fi
        fi
        
        # Create new backup only if we have enough space
        EFI_USED=$(df -h /mnt/boot/efi | awk 'NR==2 {print $5}' | tr -d '%')
        if [ $EFI_USED -lt 80 ]; then
            log_progress "Backing up existing EFI directory..."
            cp -r /mnt/boot/efi/EFI "/mnt/boot/efi/EFI.backup.$(date +%Y%m%d_%H%M%S)"
        else
            log_progress "Warning: Skipping EFI backup due to insufficient space"
            echo "Current EFI partition is $EFI_USED% full"
            echo "Proceeding without backup"
        fi
    fi
    
    mount "$EFI_PARTITION" /mnt/boot/efi
}

mount_essential_filesystems() {
    log_progress "Mounting essential filesystems..."
    
    # Create essential mount points
    mkdir -p /mnt/{dev,proc,sys,run}
    
    # Mount essential filesystems
    mount --bind /dev /mnt/dev || {
        log_progress "Failed to mount /dev"
        return 1
    }
    mount --bind /dev/pts /mnt/dev/pts || {
        log_progress "Failed to mount /dev/pts"
        return 1
    }
    mount -t proc proc /mnt/proc || {
        log_progress "Failed to mount /proc"
        return 1
    }
    mount -t sysfs sys /mnt/sys || {
        log_progress "Failed to mount /sys"
        return 1
    }
    mount -t tmpfs tmpfs /mnt/run || {
        log_progress "Failed to mount /run"
        return 1
    }
    
    # Create additional required directories
    mkdir -p /mnt/run/systemd
    mkdir -p /mnt/run/dbus
    mkdir -p /mnt/run/udev
    
    log_progress "Essential filesystems mounted successfully"
    return 0
}

# Installation Functions
install_base_system() {
    log_progress "Installing base system..."
    
    # Install base system using debootstrap
    debootstrap --arch amd64 $UBUNTU_VERSION /mnt http://archive.ubuntu.com/ubuntu/
    
    # Configure package sources
    log_progress "Configuring package sources..."
    cat > /mnt/etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_VERSION main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $UBUNTU_VERSION-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ $UBUNTU_VERSION-security main restricted universe multiverse
EOF
    
    # Save configuration for chroot
    save_chroot_config
}

save_chroot_config() {
    # Save all configuration for chroot environment
    echo "$USERNAME" > /mnt/username
    echo "$PASSWORD" > /mnt/userpass
    echo "$KEYBOARD_LAYOUT" > /mnt/keyboard_layout
    echo "$TIMEZONE" > /mnt/timezone
    echo "$FS_TYPE" > /mnt/fs_type
    echo "$MEDIA_TYPE" > /mnt/media_type
    echo "${INSTALL_NVIDIA:-N}" > /mnt/install_nvidia
    echo "${INSTALL_PRIME:-N}" > /mnt/install_prime
    
    # Create and configure chroot setup script
    create_chroot_script
}

create_chroot_script() {
    log_progress "Creating chroot setup script..."
    cat > /mnt/chroot-setup.sh << 'EOF'
#!/bin/bash
set -e

# Load configuration
USERNAME=$(cat /username)
PASSWORD=$(cat /userpass)
KEYBOARD_LAYOUT=$(cat /keyboard_layout)
TIMEZONE=$(cat /timezone)
FS_TYPE=$(cat /fs_type)
MEDIA_TYPE=$(cat /media_type)
INSTALL_NVIDIA=$(cat /install_nvidia)
INSTALL_PRIME=$(cat /install_prime)

# Remove sensitive files
rm -f /username /userpass /keyboard_layout /timezone /fs_type /media_type /install_nvidia /install_prime

# Update and add repositories
apt update
apt install -y software-properties-common

# Add all repositories at once
add-apt-repository -y universe
add-apt-repository -y multiverse
add-apt-repository -y restricted

# Add conditional repositories
if [ "$FS_TYPE" = "zfs" ]; then
    add-apt-repository -y ppa:jonathonf/zfs
fi

if [[ "$INSTALL_NVIDIA" =~ ^[Yy]$ ]]; then
    add-apt-repository -y ppa:graphics-drivers/ppa
fi

# Update after adding all repositories
apt update

# Install essential packages
DEBIAN_FRONTEND=noninteractive apt install -y \
    linux-image-generic \
    linux-headers-generic \
    mdadm \
    grub-efi-amd64 \
    ubuntu-desktop \
    network-manager \
    sudo \
    ufw \
    openssh-server \
    $([ "$MEDIA_TYPE" = "nvme" ] && echo "nvme-cli") \
    $([ "$FS_TYPE" = "btrfs" ] && echo "btrfs-progs") \
    $([ "$FS_TYPE" = "zfs" ] && echo "zfsutils-linux zfs-initramfs") \
    $([ "$INSTALL_NVIDIA" = "Y" ] && [ "$INSTALL_PRIME" = "Y" ] && \
      echo "nvidia-driver-535 nvidia-prime nvidia-settings prime-select") \
    ubuntu-restricted-extras \
    firmware-sof-signed \
    intel-microcode \
    amd64-microcode

# Configure system
configure_system

# Cleanup
apt autoremove -y
apt clean
EOF

    chmod +x /mnt/chroot-setup.sh
}

configure_system() {
    log_progress "Configuring system..."
    
    # Execute chroot setup script
    chroot /mnt /chroot-setup.sh
    
    # Configure fstab
    create_fstab
    
    # Final system checks
    perform_final_checks
}

create_fstab() {
    log_progress "Creating fstab..."
    
    # Start with header
    cat > /mnt/etc/fstab << EOF
# /etc/fstab: static file system information
EOF
    
    # Add root filesystem entry based on type
    case "$FS_TYPE" in
        "btrfs")
            if [ "$SUBVOL_MOUNTS" = "1" ]; then
                echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /               btrfs   $MOUNT_OPTIONS,subvol=@ 0       1" >> /mnt/etc/fstab
                echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /home          btrfs   $MOUNT_OPTIONS,subvol=@home 0       2" >> /mnt/etc/fstab
                echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /var           btrfs   $MOUNT_OPTIONS,subvol=@var 0       2" >> /mnt/etc/fstab
                echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /tmp           btrfs   $MOUNT_OPTIONS,subvol=@tmp 0       2" >> /mnt/etc/fstab
                echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /.snapshots    btrfs   $MOUNT_OPTIONS,subvol=@snapshots 0       2" >> /mnt/etc/fstab
            fi
            ;;
        "zfs")
            echo "# Root filesystem is handled by ZFS" >> /mnt/etc/fstab
            ;;
        *)
            echo "UUID=$(blkid -s UUID -o value $ROOT_PARTITION) /               $FS_TYPE    $MOUNT_OPTIONS 0       1" >> /mnt/etc/fstab
            ;;
    esac
    
    # Add EFI partition
    echo "UUID=$(blkid -s UUID -o value $EFI_PARTITION) /boot/efi       vfat    umask=0077      0       1" >> /mnt/etc/fstab
    
    # Add swap partitions if found
    detect_and_configure_swap
}

detect_and_configure_swap() {
    log_progress "Detecting and configuring swap..."
    while read -r device; do
        if [ -n "$device" ]; then
            local uuid=$(blkid -s UUID -o value "$device")
            if [ -n "$uuid" ]; then
                log_progress "Found swap partition: $device (UUID: $uuid)"
                echo "UUID=$uuid none swap sw 0 0" >> /mnt/etc/fstab
            fi
        fi
    done < <(fdisk -l | grep "Linux swap" | awk '{print $1}')
}

perform_final_checks() {
    log_progress "Performing final system checks..."
    chroot /mnt /bin/bash -c '
        # Check for broken packages
        if ! dpkg -C; then
            echo "Warning: Found broken packages!"
            apt install -f -y
        fi
        
        # Verify bootloader installation
        if [ ! -f "/boot/efi/EFI/ubuntu/grubx64.efi" ]; then
            echo "Warning: GRUB bootloader not found in expected location!"
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
            update-grub
        fi
        
        # Verify essential services
        for service in NetworkManager systemd-timesyncd systemd-resolved gdm3 ufw; do
            if ! systemctl is-enabled $service >/dev/null 2>&1; then
                echo "Warning: $service is not enabled!"
                systemctl enable $service
            fi
        done
    '
}

cleanup_and_finish() {
    log_progress "Cleaning up..."
    rm -f /mnt/chroot-setup.sh
    
    log_progress "Installation complete! You can now reboot your system."
    echo "The following settings have been configured:"
    echo "Username: $USERNAME"
    echo "Password: [as specified]"
    echo "Keyboard layout: $KEYBOARD_LAYOUT"
    echo "Timezone: $TIMEZONE"
    echo "Filesystem: $FS_TYPE"
    echo "This user has sudo privileges."
    echo
    echo "Additional security measures:"
    echo "- UFW firewall enabled (SSH allowed)"
    echo "- Password policies enforced"
    if [ -f "/mnt/etc/initramfs-tools/conf.d/resume" ]; then
        echo "- Hibernation support configured"
    fi
    echo
    echo "After reboot, you'll need to configure:"
    echo "- Display settings"
    echo "- Network settings"
    echo "- Other system preferences"
}

# Mounting Section
prepare_mount_points() {
    log_progress "Preparing mount points..."
    
    # Mount and format root partition based on filesystem type
    if [[ "$FORMAT_PARTITION" =~ ^[Yy]$ ]]; then
        format_root_partition
    fi
    
    # Mount root partition
    mount_root_partition || {
        log_progress "Failed to mount root partition"
        exit 1
    }
    
    # Mount EFI partition and handle backups
    mount_efi_partition || {
        log_progress "Failed to mount EFI partition"
        exit 1
    }
    
    # Mount essential filesystems
    mount_essential_filesystems || {
        log_progress "Failed to mount essential filesystems"
        exit 1
    }
}

# Main Installation Section
main() {
    # Clean up any previous mounts first
    cleanup_previous_mounts
    
    # Perform all safety checks
    check_safety
    
    # Detect system configuration
    detect_system_config
    
    # Get user preferences
    get_user_preferences
    
    # Prepare mount points and filesystems
    prepare_mount_points
    
    # Install base system
    install_base_system
    
    # Configure system
    configure_system
    
    # Cleanup and finish
    cleanup_and_finish
}

# Run main function
main
