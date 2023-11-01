#!/bin/bash
# Script Name: sdcard-to-usb.sh
# Author: Thomas Blarre
# Description: This script has been designed to create a bootable USB key for a Raspberry Pi, with full disk encryption, btrfs for the root file system, organized with two timeshift-compatible subvolumes (@ and @home), from an existing installation of Raspberry Pi OS on a SD card.
# Usage: Change the USB_DEVICE value in the script and then run ./sdcard-to-usb.sh

# To do: umount and close LUKS volumes at the beginning if need be, and ask for the device or pass it as a parameter

echo "Setting up the drive to prepare"
USB_DEVICE="/dev/sda"

echo "Updating the system"
sudo apt-get update && sudo apt-get -y dist-upgrade

echo "Making sure required packages are installed"
sudo apt-get install -y btrfs-progs cryptsetup

echo "Creating boot partition"
sudo parted "$USB_DEVICE" mklabel gpt
sudo parted "$USB_DEVICE" mkpart primary fat32 1MiB 512MiB
sudo parted "$USB_DEVICE" name 1 bootfs
sudo parted "$USB_DEVICE" set 1 boot on

echo "Creating swap partition"
sudo parted "$USB_DEVICE" mkpart primary linux-swap 512MiB 1536MiB 
sudo parted "$USB_DEVICE" name 2 swapfs
sudo parted "$USB_DEVICE" set 2 swap on

echo "Creating root partition"
sudo parted "$USB_DEVICE" mkpart primary ext4 1536MiB 100%
sudo parted "$USB_DEVICE" name 3 rootfs

echo "Creating boot and swap filesystems"
sudo mkfs.vfat /dev/sda1
sudo mkswap /dev/sda2

echo "Mounting the boot filesystem"
sudo mkdir -p /mnt/bootfs
sudo mount /dev/sda1 /mnt/bootfs

echo "Creating LUKS volume"
sudo cryptsetup luksFormat /dev/disk/by-partlabel/rootfs

echo "Opening the LUKS volume"
sudo cryptsetup open /dev/disk/by-partlabel/rootfs decrypted_rootfs

echo "Creating the btrfs filesystem, mounting it and creating the two subvolumes"
sudo mkfs.btrfs /dev/mapper/decrypted_rootfs
sudo mkdir -p /mnt/btrfs
sudo mount /dev/mapper/decrypted_rootfs /mnt/btrfs
sudo btrfs subvolume create /mnt/btrfs/@
sudo btrfs subvolume create /mnt/btrfs/@home


echo "Copying the files from the SD card to the USB key"
sudo rsync -avhP /boot/firmware/ /mnt/bootfs
sudo rsync -avhP /home/ /mnt/btrfs/@home
sudo rsync -avhP --exclude boot/firmware --exclude home --exclude mnt / /mnt/btrfs/@

echo "Making sure everything is written on the disk"
sudo sync && sync

echo "Unmount everything and prepare the mounts for chrooting"
sudo umount /mnt/bootfs
sudo umount /mnt/btrfs
sudo mkdir -p /mnt/chroot
sudo mount -o subvol=@ /dev/mapper/decrypted_rootfs /mnt/chroot
sudo mkdir -p /mnt/chroot/home
sudo mount -o subvol=@home /dev/mapper/decrypted_rootfs /mnt/chroot/home
sudo mkdir -p /mnt/chroot/boot/firmware
sudo mount /dev/sda1 /mnt/chroot/boot/firmware
for i in /dev /dev/pts /proc /sys /run; do sudo mkdir -p /mnt/chroot$i && sudo mount -B $i /mnt/chroot$i; done

echo "Modifying the fstab of the USB key"
sudo sed -i '/\/boot\/firmware/d' /mnt/chroot/etc/fstab
sudo sed -i '/\ \/\ /d' /mnt/chroot/etc/fstab
BOOT_UUID=$(sudo blkid -s UUID -o value "$USB_DEVICE"1)
echo "UUID=$BOOT_UUID /boot/firmware vfat defaults 0 1" | sudo tee -a /mnt/chroot/etc/fstab
echo "/dev/mapper/decrypted_rootfs / btrfs defaults,subvol=@ 0 0" | sudo tee -a /mnt/chroot/etc/fstab
echo "/dev/mapper/decrypted_rootfs /home btrfs defaults,subvol=@home 0 0" | sudo tee -a /mnt/chroot/etc/fstab
echo "/dev/mapper/decrypted_swapfs swap swap defaults 0 0" | sudo tee -a /mnt/chroot/etc/fstab

echo "Modifying the crypttab of the USB key"
ROOT_UUID=$(sudo blkid -s UUID -o value "$USB_DEVICE"3)
SWAP_UUID=$(sudo blkid -s UUID -o value "$USB_DEVICE"2)
echo "decrypted_rootfs UUID=$ROOT_UUID none luks,initramfs" | sudo tee -a /mnt/chroot/etc/crypttab
echo "decrypted_swapfs UUID=$SWAP_UUID /dev/urandom swap" | sudo tee -a /mnt/chroot/etc/crypttab

echo "Modifying cmdline.txt"
DECRYPTED_ROOTFS_UUID=$(sudo blkid -s UUID -o value /dev/mapper/decrypted_rootfs)
sudo sed -i -E "s|(root=)[^ ]*|\1UUID=$DECRYPTED_ROOTFS_UUID rootflags=subvol=@|" /mnt/chroot/boot/firmware/cmdline.txt
sudo sed -i -E "s|(rootfstype=)[^ ]*|\1btrfs cryptdevice=UUID=$ROOT_UUID:decrypted_rootfs|" /mnt/chroot/boot/firmware/cmdline.txt
sudo sed -i '/quiet/d' /mnt/chroot/boot/firmware/cmdline.txt
sudo sed -i '/splash/d' /mnt/chroot/boot/firmware/cmdline.txt

"Chroot, install and configure dropbear-initramfs"
sudo chroot /mnt/chroot /bin/bash -x <<'EOF'
apt-get install -y dropbear-initramfs
echo 'no-port-forwarding,no-agent-forwarding,no-x11-forwarding,command="/bin/cryptroot-unlock" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDXAr+I9YH+gFz7v61N1YTLzuRnYaXHT0CzuhiniKmZRDDIIrXuOnYR8UMZclhtEVkvmyM05xfaddFNUGUjsG9jWKQ4t256J0OS5xq3AqZCTu/wA05o88r0zsEGDurfa6UJrNoEOfnXQl9IsOFRumNVFguHoJYWtSGk01qrm1po/ZVUS86A7ZrC77T0QwqeIUwjS3E5RN95nszp81LGh2AJhoHto0OIGTYodqZlR08ZSaEDRAkLpVQeRDI/huhv8vA2XuOtW2VIgvPEg/AvEEOmoR+TUSnbQTTZhG2sjqiUSqk0rGYaoGD+gV0NzS3ZO3uIJBN5eW1rFNYlr2bnHWlW78BKlq+0hwn3241BxTJA0r4jO7hlNd5oAi6zsHZS40dN1jBiU2O0QgBDTSdzECnlo6aYXMd+yTW8pYE9gHh5Qb3LLDVr2Wc8oZomGFzN/lL6YxWoUor0YVnXRcnYDMpYpVcvhKVMtIVodjpVIHZQbqbKtcPhBI8BNUgo5iF3q6M= dropbear' >> /etc/dropbear/initramfs/authorized_keys
sed -i 's|#DROPBEAR_OPTIONS=|DROPBEAR_OPTIONS="-p 4444"|' /etc/dropbear/initramfs/dropbear.conf
echo 'ip=:::::eth0:dhcp' > /etc/initramfs-tools/conf.d/ip
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
update-initramfs -c -k all
EOF

echo "Rebooting now"
sudo reboot