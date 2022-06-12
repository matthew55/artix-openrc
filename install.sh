#!/usr/bin/env bash
# Install script for Artix linux with Openrc as an init system.
# Created on June 11, 2022

set -xe

## User Info
get_info() {
    read -r -p "Host name? " HOST_NAME
    read -r -p "User's name? " USER_NAME
    read -r -p "User's password? " USER_PASSWORD
    read -r -p "Root's password? " ROOT_PASSWORD

    lsblk
    read -r -p "Which drive? (i.e. sda): " DRIVE
    read -r -p "Are you sure you want to wipe $DRIVE? This cannot be undone. (y/n): " DRIVE_CONFIRM
    if [[ ! "$DRIVE_CONFIRM" =~ ^(y|Y) ]]; then
        exit 1
    fi 
}

## Partition and Mounting
partition_device() {
    BIOS=/sys/firmware/efi/efivars
    if [ -n $BIOS ]; then
        partition_bios
    else
        partition_efi
    fi
}

partition_bios() {
    echo -n "Partitioning drive..."
    SWAP_PARTITION="n 1 _ +4G"
    ROOT_PARTITION="n 2 _ _"
    
    SWAP_TYPE="t 1 19"
    ROOT_TYPE="t 2 20"

    FDISK_INSTRUCTIONS="
        g
        $SWAP_PARTITION
        $ROOT_PARTITION
        $SWAP_TYPE
        $ROOT_TYPE
        w
    "

    for INSTRUCTION in $FDISK_INSTRUCTIONS; do
        printf "%s\n" "$INSTRUCTION" | grep -q "_" && printf "\n" || printf "%s\n" "$INSTRUCTION"
    done | fdisk "/dev/$DRIVE"
    echo "done"

    echo -n "Configuring partitions..."
    mkswap -L SWAP "/dev/$DRIVE"1
    swapon "/dev/$DRIVE"1
    mkfs.ext4 -L ROOT "/dev/$DRIVE"2
    mount "/dev/$DRIVE"2 /mnt
    echo "done"
}

partition_efi() {
    echo -n "Partitioning drive..."
    BOOT_PARTITION="n 1 _ +550M"
    SWAP_PARTITION="n 2 _ +4G"
    ROOT_PARTITION="n 3 _ _"
    
    BOOT_TYPE="t 1 1"
    SWAP_TYPE="t 2 19"
    ROOT_TYPE="t 3 20"

    FDISK_INSTRUCTIONS="
        g
        $BOOT_PARTITION
        $SWAP_PARTITION
        $ROOT_PARTITION
        $BOOT_TYPE
        $SWAP_TYPE
        $ROOT_TYPE
        w
    "

    for INSTRUCTION in $FDISK_INSTRUCTIONS; do
        printf "%s\n" "$INSTRUCTION" | grep -q "_" && printf "\n" || printf "%s\n" "$INSTRUCTION"
    done | fdisk "/dev/$DRIVE"
    echo "done"

    echo -n "Configuring partitions..."
    mkfs.fat -F 32 "/dev/$DRIVE"1
    fatlabel "/dev/$DRIVE"1 BOOT
    mkswap -L SWAP "/dev/$DRIVE"2
    swapon "/dev/$DRIVE"2
    mkfs.ext4 -L ROOT "/dev/$DRIVE"3
    mount "/dev/$DRIVE"3 /mnt
    mkdir -p /mnt/boot && mount "/dev/$DRIVE"1 /mnt/boot
    echo "done"
}

## Install base system
base_install() {
    echo -n "Installing base system..."
    basestrap /mnt base base-devel openrc elogind-openrc linux linux-firmware vim connman-openrc dhclient networkmanager networkmanager-openrc grub os-prober efibootmgr pacman-contrib
    artix-chroot /mnt rc-update add connmand && artix-chroot /mnt rc-update add NetworkManager
    echo "done"

    echo -n "Generating fstab..."
    fstabgen -U /mnt >> /mnt/etc/fstab
    echo "done"
}


## Configure base system
base_configure() {
    echo -n "Setting time zone..."
    ln -sf /usr/share/zoneinfo/America/Indianapolis /etc/localtime
    hwclock --systohc
    echo "done"

    echo -n "Configuring pacman settings..."
    curl https://archlinux.org/mirrorlist/all/ -o /mnt/etc/pacman.d/mirrorlist-arch
    grep "s/#Color/Color/" /mnt/etc/pacman.conf
    grep "s/#VerbosePkgLists/VerbosePkgLists/" /mnt/etc/pacman.conf
    grep "s/#ParallelDownloads/ParallelDownloads/" /mnt/etc/pacman.conf
    echo "#Arch Linux Mirrors\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n\n[community]Include = /etc/pacman.d/mirrorlist-arch\n\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch"
    echo "#!/bin/bash\nrankmirrors -v -n 5 /etc/pacman.d/mirrorlist.pacnew | tee /etc/pacman.d/mirrorlist && reflector --score 5 --protocol https | tee /etc/pacman.d/mirrorlist-arch && pacman -Sc --noconfirm && pacman -Syyu --noconfirm" < /mnt/usr/bin/update-artix
    pacman-key --init && pacman-key --populate artix
    chmod +x /mnt/usr/bin/update-artix && /mnt/usr/bin/update-artix
    echo "done"

    echo -n "Configure locale..."
    sed "s/^#en_US/en_US/g" /mnt/etc/locale.gen
    locale-gen
    echo 'export LANG="en_US.UTF-8"' > /mnt/etc/locale.conf
    echo 'export LC_COLLATE="C"' >> /mnt/etc/locale.conf
    echo "done"

    echo -n "Creating hostname file..."
    echo "$HOST_NAME" > /mnt/etc/hostname
    echo "127.0.0.1     localhost" > /mnt/etc/hosts
    echo "::1           localhost" >> /mnt/etc/hosts
    echo "127.0.0.1     $HOST_NAME.localdomain $HOST_NAME" >> /mnt/etc/hosts
    echo 'hostname="$HOST_NAME"' >> /mnt/etc/conf.d/hostname
    echo "done"

    echo -n "Creating users "
    artix-chroot /mnt useradd -mG "wheel" "$USER_NAME"
    echo -n "$USER_PASSWORD\n$USER_PASSWORD" | artix-chroot /mnt passwd "$USER_NAME"
    echo -n "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd
    echo "done"
}

## Setup Grub
setup_grub() {
    echo -n "Setting up grub..."
    if [ -n $BIOS ]; then
        grub-install --recheck /dev/$DRIVE
    else 
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
    echo "done"
}

## Finish install
cleanup() {
    read -r -p "Would you like to reboot now? (y/n): " REBOOT_CONFIRM
    if [[ ! "$REBOOT_CONFIRM" =~ ^(y|Y) ]]; then
        umount -R /mnt
        reboot
    fi 
}

main() {
    get_info
    partition_device
    base_install
    setup_grub
    cleanup
}

main
