#!/usr/bin/env bash
# easy-arch-install.sh
# Interactive Arch Linux installer (ext4 or LUKS+btrfs)
# Run as root from Arch install ISO.
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# Cosmetic helpers
# -----------------------
BOLD='\e[1m'; BRED='\e[91m'; BBLUE='\e[34m'; BGREEN='\e[92m'; BYELLOW='\e[93m'; RESET='\e[0m'
info(){ echo -e "${BOLD}${BGREEN}[ ${BYELLOW}•${BGREEN} ]${RESET} $*"; }
warn(){ echo -e "${BOLD}${BYELLOW}[ ${BBLUE}!${BYELLOW} ]${RESET} $*"; }
err(){ echo -e "$ {BOLD}${BRED}[ ${BBLUE}X${BRED} ]${RESET} $*"; }
prompt(){ local _msg="$1"; local _def="${2:-}"; if [[ -n "$_def" ]]; then read -rp "$_msg [$_def]: " _ans; echo "${_ans:-$_def}"; else read -rp "$_msg: " _ans; echo "$_ans"; fi }
confirm(){ local _msg="${1:-Continue?}"; local _def="${2:-y}"; while true; do read -rp "$_msg (${_def^^}/n): " resp; resp="${resp:-$ _def}"; case "${resp,,}" in y|yes) return 0 ;; n|no) return 1 ;; *) echo "Please answer yes or no." ;; esac; done }

# -----------------------
# Preconditions
# -----------------------
if [[ $(id -u) -ne 0 ]]; then err "Run this script as root (from Arch ISO)"; exit 1; fi
info "Quick network check..."
if ! ping -c1 archlinux.org >/dev/null 2>&1; then warn "Network unreachable — continue if you already have network (use 'nmtui' or 'iwctl')"; fi

# -----------------------
# Select target device
# -----------------------
info "Available block devices:"
lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /'
DEVICE=$(prompt "Enter target device (e.g. /dev/sda or /dev/nvme0n1)" "/dev/sda")
if [[ ! -b "$DEVICE" ]]; then err "Device $DEVICE not found"; exit 1; fi
info "Selected device: $DEVICE"

# partition suffix helper (nvme -> p)
psfx() { [[ "$DEVICE" =~ nvme ]] && echo "p" || echo ""; }
PSFX="$(psfx)"

# -----------------------
# UEFI check
# -----------------------
UEFI=false
if [[ -d /sys/firmware/efi/efivars ]]; then UEFI=true; fi
if ! $UEFI; then warn "UEFI not detected in live environment. This script expects UEFI for systemd-boot/grub-efi."; if ! confirm "Continue anyway (you'll need to adjust bootloader manually)?" "n"; then exit 1; fi; fi

# -----------------------
# Kernel selection
# -----------------------
info "Kernel options: 1) linux 2) linux-lts 3) linux-hardened 4) linux-zen"
KERSEL=$(prompt "Kernel choice (1-4)" "1")
case "$KERSEL" in
  1) KERNEL="linux";;
  2) KERNEL="linux-lts";;
  3) KERNEL="linux-hardened";;
  4) KERNEL="linux-zen";;
  *) KERNEL="linux";;
esac
info "Kernel: $KERNEL"

# -----------------------
# Network selection
# -----------------------
info "Network: 1) NetworkManager 2) IWD 3) dhcpcd 4) wpa_supplicant+dhcpcd"
NETCH=$(prompt "Choose network manager (1-4)" "1")
case "$NETCH" in
  1) NETPKG="networkmanager"; NETEN=yes;;
  2) NETPKG="iwd"; NETEN=yes;;
  3) NETPKG="dhcpcd"; NETEN=yes;;
  4) NETPKG="wpa_supplicant dhcpcd"; NETEN=yes;;
  *) NETPKG="networkmanager"; NETEN=yes;;
esac
info "Network pkg: $NETPKG"

# -----------------------
# Layout choice: ext4 or luks+btrfs
# -----------------------
info "Layout options:"
echo "  1) ext4 layout (separate /home, /boot, swap partition, root) — simple"
echo "  2) LUKS2 (encrypted) + btrfs subvolumes (ESP + CRYPTROOT) — encrypted, snapshot-ready"
LAYOUT=$(prompt "Choose layout (1 or 2)" "1")
if [[ "$LAYOUT" != "1" && "$LAYOUT" != "2" ]]; then err "Invalid layout"; exit 1; fi

# -----------------------
# Locale, kbd, hostname, users, passwords
# -----------------------
LOCALE=$(prompt "Locale (eg en_US.UTF-8)" "en_US.UTF-8")
KMAP=$(prompt "Console keymap (eg us)" "us")
HOSTNAME=$(prompt "Hostname" "aoba-arch")
USERNAME=$(prompt "Create user (username; leave empty to skip creating user)" "aoba")
# passwords (hidden prompts)
read -rsp "Root password (typing hidden): " ROOTPASS; echo
if [[ -n "$USERNAME" ]]; then read -rsp "Password for $USERNAME: " USERPASS; echo; fi

# Microcode detection
CPUVENDOR=$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d ' \t')
if [[ "$CPUVENDOR" == *AuthenticAMD* ]]; then MICROCODE="amd-ucode"; else MICROCODE="intel-ucode"; fi
info "Microcode package: $MICROCODE"

# Confirm plan overview
info "Plan summary:"
echo "  Device: $DEVICE"
echo "  Layout: $LAYOUT (1=ext4, 2=luks+btrfs)"
echo "  Kernel: $KERNEL"
echo "  Network: $NETPKG"
echo "  Locale: $LOCALE, Keymap: $KMAP"
echo "  Hostname: $HOSTNAME"
echo "  Create user: ${USERNAME:-<none>}"
if ! confirm "Proceed with partitioning and install? This WILL DESTROY data on $DEVICE" "n"; then info "Aborted."; exit 0; fi

# -----------------------
# Wipe and partition
# -----------------------
info "Wiping partition table on $DEVICE"
wipefs -a "$DEVICE" || true
sgdisk -Zo "$DEVICE" || true

if [[ "$LAYOUT" == "1" ]]; then
  # ext4 scheme: partition order: /home, /boot(ESP), swap, root
  info "Creating partitions (ext4 scheme): /home, /boot(ESP), swap, /"
  parted --script "$DEVICE" mklabel gpt \
    mkpart primary ext4 1MiB 50% \
    mkpart primary fat32 50% 51% \
    set 2 esp on \
    mkpart primary linux-swap 51% 53% \
    mkpart primary ext4 53% 100% || { err "parted failed"; exit 1; }
  sleep 1
  HOME_PART="${DEVICE}${PSFX}1"
  EFI_PART="${DEVICE}${PSFX}2"
  SWAP_PART="${DEVICE}${PSFX}3"
  ROOT_PART="${DEVICE}${PSFX}4"

  info "Formatting partitions..."
  mkfs.ext4 -F "$HOME_PART"
  mkfs.fat -F32 "$EFI_PART"
  mkswap "$SWAP_PART"
  mkfs.ext4 -F "$ROOT_PART"
  swapon "$SWAP_PART"

  info "Mounting partitions..."
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/home /mnt/boot
  mount "$HOME_PART" /mnt/home
  mount "$EFI_PART" /mnt/boot

else
  # LUKS + btrfs: ESP + CRYPTROOT
  info "Creating partitions (LUKS+btrfs): ESP + CRYPTROOT"
  parted --script "$DEVICE" mklabel gpt \
    mkpart primary fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart primary 1025MiB 100% \
    name 2 CRYPTROOT || { err "parted failed"; exit 1; }
  sleep 1
  ESP="${DEVICE}${PSFX}1"
  CRYPTPART="${DEVICE}${PSFX}2"

  info "Formatting ESP..."
  mkfs.fat -F32 "$ESP"

  # LUKS password prompt
  while true; do
    read -rsp "Enter LUKS passphrase (hidden): " LUKSPASS; echo
    read -rsp "Confirm LUKS passphrase: " LUKSPASS2; echo
    [[ "$LUKSPASS" == "$LUKSPASS2" && -n "$LUKSPASS" ]] && break
    err "Passphrases do not match or empty, try again."
  done

  info "Creating LUKS2 container on $CRYPTPART..."
  echo -n "$LUKSPASS" | cryptsetup luksFormat "$CRYPTPART" -d - --type luks2 --iter-time 2000
  echo -n "$LUKSPASS" | cryptsetup open "$CRYPTPART" cryptroot -d -
  MAPPER="/dev/mapper/cryptroot"

  info "Formatting LUKS as btrfs and creating subvolumes..."
  mkfs.btrfs -f "$MAPPER"
  mount "$MAPPER" /mnt
  subvols=(@ @home @snapshots @var_pkgs @var_log)
  for s in "${subvols[@]}"; do btrfs subvolume create /mnt/"$s"; done
  umount /mnt
  mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ "$MAPPER" /mnt
  mkdir -p /mnt/{home,.snapshots,var/cache/pacman/pkg,var/log,boot}
  mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home "$MAPPER" /mnt/home
  mount "$ESP" /mnt/boot
fi

# -----------------------
# Pacstrap
# -----------------------
info "Installing base system (pacstrap). This may take a while..."
PKGS=(base base-devel "$KERNEL" "$MICROCODE" linux-firmware vim sudo bash-completion)
PKGS+=("$NETPKG" efibootmgr dosfstools mtools os-prober)
if [[ "$LAYOUT" == "2" ]]; then PKGS+=(btrfs-progs grub grub-btrfs snapper snap-pac zram-generator rsync); else PKGS+=(os-prober); fi

pacstrap /mnt "${PKGS[@]}"

# -----------------------
# fstab
# -----------------------
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------
# Prepare chroot script
# -----------------------
info "Preparing chroot configuration script..."
cat > /mnt/root/arch_chroot_setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
HOSTNAME="$1"; LOCALE="$2"; KMAP="$3"; USERNAME="$4"; USERPASS="$5"; ROOTPASS="$6"; LAYOUT="$7"; DEVICE_ROOT="$8"
info(){ echo -e "\n[CHROOT] $*"; }
# Timezone
ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc || true
# Locale
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
# vconsole
echo "KEYMAP=$KMAP" > /etc/vconsole.conf
# Hostname and hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF
# Set root password
if [[ -n "$ROOTPASS" ]]; then echo "root:$ROOTPASS" | chpasswd; fi
# Create user
if [[ -n "$USERNAME" ]]; then
  useradd -m -G wheel -s /bin/bash "$USERNAME"
  if [[ -n "$USERPASS" ]]; then echo "$USERNAME:$USERPASS" | chpasswd; fi
  pacman -S --noconfirm sudo
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true
fi
# Enable Network
pacman -S --noconfirm networkmanager || true
systemctl enable NetworkManager
# mkinitcpio adjustments for LUKS
if [[ "$LAYOUT" == "2" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems)/' /etc/mkinitcpio.conf || true
fi
mkinitcpio -P
# Bootloader: for LUKS we use grub-efi; for ext4 use systemd-boot
if [[ "$LAYOUT" == "2" ]]; then
  # install grub-efi
  pacman -S --noconfirm grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  # if encrypted root, ensure GRUB cmdline
  ROOT_UUID=$(blkid -s UUID -o value "$DEVICE_ROOT" || true)
  if [[ -n "$ROOT_UUID" ]]; then
    sed -i "s,^GRUB_CMDLINE_LINUX=\\\"\\\",GRUB_CMDLINE_LINUX=\\\"rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot\\\"," /etc/default/grub || true
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
else
  # systemd-boot
  bootctl install || true
  KIMG=$(ls /boot | grep '^vmlinuz' | head -n1 || echo vmlinuz-linux)
  IIMG=$(ls /boot | grep '^initramfs' | head -n1 || echo initramfs-linux.img)
  ROOT_UUID=$(blkid -s UUID -o value "$DEVICE_ROOT" || true)
  cat > /boot/loader/loader.conf <<EOF
default arch
timeout 3
EOF
  cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /$KIMG
initrd  /$IIMG
options root=UUID=$ROOT_UUID rw
EOF
fi
# Final update
pacman -Syu --noconfirm
echo "CHROOT_DONE"
CHROOT

chmod +x /mnt/root/arch_chroot_setup.sh

# -----------------------
# Run chroot script
# -----------------------
info "Entering chroot and finishing configuration..."
# Pass parameters: HOSTNAME LOCALE KMAP USERNAME USERPASS ROOTPASS LAYOUT ROOT_DEVICE
ROOT_DEVICE_PARAM=""
if [[ "$LAYOUT" == "1" ]]; then ROOT_DEVICE_PARAM="$ROOT_PART"; else ROOT_DEVICE_PARAM="$CRYPTPART"; fi

# copy variables for chroot (safely; passwords may contain special chars)
arch-chroot /mnt /bin/bash -c "/root/arch_chroot_setup.sh '$HOSTNAME' '$LOCALE' '$KMAP' '$USERNAME' '$USERPASS' '$ROOTPASS' '$LAYOUT' '$ROOT_DEVICE_PARAM'"

info "Unmounting and finishing..."
sync
umount -R /mnt || true
swapoff -a || true

info "Installation finished. Reboot when ready. (Remember to remove installation media)"
