#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script modifies a base image to act as a recovery installer.
# If no kernel image is supplied, it will build a devkeys signed recovery
# kernel.  Alternatively, a signed recovery kernel can be used to
# create a Chromium OS recovery image.

SCRIPT_ROOT=$(dirname "$0")
. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1


DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built" b
DEFINE_integer statefulfs_sectors 4096 \
  "Number of sectors to use for the stateful filesystem when minimizing"
# Skips the build steps and just does the kernel swap.
DEFINE_string kernel_image "" \
    "Path to a pre-built recovery kernel"
DEFINE_string kernel_outfile "" \
    "Filename and path to emit the kernel outfile to. \
If empty, emits to IMAGE_DIR."
DEFINE_string image "" "Path to the image to use"
DEFINE_string to "" \
    "Path to the image to create. If empty, defaults to \
IMAGE_DIR/recovery_image.bin."
DEFINE_boolean kernel_image_only $FLAGS_FALSE \
    "Emit the recovery kernel image only"
DEFINE_boolean sync_keys $FLAGS_TRUE \
    "Update the kernel to be installed with the vblock from stateful"
DEFINE_boolean minimize_image $FLAGS_TRUE \
    "Decides if the original image is used or a minimal recovery image is \
created."
DEFINE_boolean modify_in_place $FLAGS_FALSE \
    "Modifies the source image in place. This cannot be used with \
--minimize_image."
DEFINE_integer jobs -1 \
    "How many packages to build in parallel at maximum." j
DEFINE_string build_root "/build" \
    "The root location for board sysroots."

DEFINE_string rootfs_hash "/tmp/rootfs.hash" \
  "Path where the rootfs hash should be stored."

DEFINE_boolean verbose $FLAGS_FALSE \
    "Log all commands to stdout." v

# Keep in sync with build_image.
DEFINE_string keys_dir "/usr/share/vboot/devkeys" \
  "Directory containing the signing keys."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
set -e

if [ $FLAGS_verbose -eq $FLAGS_TRUE ]; then
  # Make debugging with -v easy.
  set -x
fi


. "${SCRIPT_ROOT}/build_library/board_options.sh" || exit 1


EMERGE_BOARD_CMD="emerge-$BOARD"

# No image was provided.  Use the standard latest image
if [ -z "$FLAGS_image" ]; then
  IMAGES_DIR="$($SCRIPT_ROOT/get_latest_image.sh --board=$BOARD)"
  FLAGS_image="$IMAGES_DIR/$CHROMEOS_IMAGE_NAME"
fi

# Turn path into an absolute path.
FLAGS_image=$(eval readlink -f "$FLAGS_image")

# Abort early if we can't find the image
if [ ! -f "$FLAGS_image" ]; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

get_install_vblock() {
  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  local stateful_offset=$(partoffset "$FLAGS_image" 1)
  local stateful_mnt=$(mktemp -d)
  local out=$(mktemp)

  set +e
  sudo mount -o ro,loop,offset=$((stateful_offset * 512)) \
             "$FLAGS_image" $stateful_mnt
  sudo cp "$stateful_mnt/vmlinuz_hd.vblock"  "$out"
  sudo chown $USER "$out"

  sudo umount -d "$stateful_mnt"
  rmdir "$stateful_mnt"
  set -e
  echo "$out"
}

failboat() {
# http://www.chris.com/ascii/index.php?art=transportation/nautical
  echo -e "${V_BOLD_RED}"
  cat <<BOAT
             .  o ..
     o . o o.o
          ...oo
            __[]__
         __|_o_o_o\__
         \""""""""""/
          \   FAIL /
     ^^^^^^^^^^^^^^^^^^^^
BOAT
  echo -e "${V_VIDOFF}"
  die "$* failed"
}

create_recovery_kernel_image() {
  local sysroot="$FACTORY_ROOT"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local root_offset=$(partoffset "$FLAGS_image" 3)
  local root_size=$(partsize "$FLAGS_image" 3)

  local root_dev=$(sudo losetup --show -f \
                   -o $((root_offset * 512)) \
                   --sizelimit $((root_size * 512)) \
                   "$FLAGS_image")
  echo "16651 root_dev: $root_dev"
  trap "sudo losetup -d $root_dev" EXIT

  cros_root="PARTUUID=%U/PARTNROFF=1"  # only used for non-verified images
  if grep -q enable_rootfs_verification "${IMAGE_DIR}/boot.desc"; then
    cros_root=/dev/dm-0
  fi
  # TODO(wad) LOAD FROM IMAGE KERNEL AND NOT BOOT.DESC
  local verity_args=$(grep -- '--verity_' "${IMAGE_DIR}/boot.desc")
  # Convert the args to the right names and clean up extra quoting.
  # TODO(wad) just update these everywhere
  verity_args=$(echo $verity_args | sed \
    -e 's/verity_algorithm/verity_hash_alg/g' \
    -e 's/"//g')

  # Tie the installed recovery kernel to the final kernel.  If we don't
  # do this, a normal recovery image could be used to drop an unsigned
  # kernel on without a key-change check.
  # Doing this here means that the kernel and initramfs creation can
  # be done independently from the image to be modified as long as the
  # chromeos-recovery interfaces are the same.  It allows for the signer
  # to just compute the new hash and update the kernel command line during
  # recovery image generation.  (Alternately, it means an image can be created,
  # modified for recovery, then passed to a signer which can then sign both
  # partitions appropriately without needing any external dependencies.)
  local kern_offset=$(partoffset "$FLAGS_image" 2)
  local kern_size=$(partsize "$FLAGS_image" 2)
  local kern_tmp=$(mktemp)
  local kern_hash=

  dd if="$FLAGS_image" bs=512 count=$kern_size \
     skip=$kern_offset of="$kern_tmp" 1>&2
  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$kern_tmp" conv=notrunc 1>&2
  fi
  local kern_hash=$(sha1sum "$kern_tmp" | cut -f1 -d' ')
  rm "$kern_tmp"

  # TODO(wad) add FLAGS_boot_args support too.
  ${SCRIPTS_DIR}/build_kernel_image.sh \
    --arch="${ARCH}" \
    --to="$RECOVERY_KERNEL_IMAGE" \
    --hd_vblock="$RECOVERY_KERNEL_VBLOCK" \
    --vmlinuz="$vmlinuz" \
    --working_dir="${IMAGE_DIR}" \
    --boot_args="noinitrd panic=60 cros_recovery kern_b_hash=$kern_hash" \
    --keep_work \
    --rootfs_image=${root_dev} \
    --rootfs_hash=${FLAGS_rootfs_hash} \
    --root=${cros_root} \
    --keys_dir="${FLAGS_keys_dir}" \
    --nouse_dev_keys \
    ${verity_args} 1>&2 || failboat "build_kernel_image"
  sudo rm "$FLAGS_rootfs_hash"
  sudo mount | sed 's/^/16651 /'
  sudo losetup -a | sed 's/^/16651 /'
  sudo losetup -d "$root_dev"
  trap - RETURN

  # Update the EFI System Partition configuration so that the kern_hash check
  # passes.
  local efi_offset=$(partoffset "$FLAGS_image" 12)
  local efi_size=$(partsize "$FLAGS_image" 12)

  local efi_dev=$(sudo losetup --show -f \
                  -o $((efi_offset * 512)) \
                  --sizelimit $((efi_size * 512)) \
                  "$FLAGS_image")
  local efi_dir=$(mktemp -d)
  trap "sudo losetup -d $efi_dev && rmdir \"$efi_dir\"" EXIT
  echo "16651 mount: $efi_dev -> $efi_dir"
  sudo mount "$efi_dev" "$efi_dir"
  sudo mount | sed 's/^/16651 /'
  sudo sed  -i -e "s/cros_legacy/cros_legacy kern_b_hash=$kern_hash/g" \
    "$efi_dir/syslinux/usb.A.cfg" || true
  # This will leave the hash in the kernel for all boots, but that should be
  # safe.
  sudo sed  -i -e "s/cros_efi/cros_efi kern_b_hash=$kern_hash/g" \
    "$efi_dir/efi/boot/grub.cfg" || true
  sudo umount "$efi_dir"
  sudo losetup -a | sed 's/^/16651 /'
  sudo losetup -d "$efi_dev"
  rmdir "$efi_dir"
  trap - EXIT
}

install_recovery_kernel() {
  local kern_a_offset=$(partoffset "$RECOVERY_IMAGE" 2)
  local kern_a_size=$(partsize "$RECOVERY_IMAGE" 2)
  local kern_b_offset=$(partoffset "$RECOVERY_IMAGE" 4)
  local kern_b_size=$(partsize "$RECOVERY_IMAGE" 4)

  if [ $kern_b_size -eq 1 ]; then
    echo "Image was created with no KERN-B partition reserved!" 1>&2
    echo "Cannot proceed." 1>&2
    return 1
  fi

  # Backup original kernel to KERN-B
  dd if="$RECOVERY_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     count=$kern_a_size \
     skip=$kern_a_offset \
     seek=$kern_b_offset \
     conv=notrunc

  # We're going to use the real signing block.
  if [ $FLAGS_sync_keys -eq $FLAGS_TRUE ]; then
    dd if="$INSTALL_VBLOCK" of="$RECOVERY_IMAGE" bs=512 \
       seek=$kern_b_offset \
       conv=notrunc
  fi

  # Install the recovery kernel as primary.
  dd if="$RECOVERY_KERNEL_IMAGE" of="$RECOVERY_IMAGE" bs=512 \
     seek=$kern_a_offset \
     count=$kern_a_size \
     conv=notrunc

  # Set the 'Success' flag to 1 (to prevent the firmware from updating
  # the 'Tries' flag).
  sudo $GPT add -i 2 -S 1 "$RECOVERY_IMAGE"

  # Repeat for the legacy bioses.
  # Replace vmlinuz.A with the recovery version we built.
  # TODO(wad): Extract the $RECOVERY_KERNEL_IMAGE and grab vmlinuz from there.
  local sysroot="$FACTORY_ROOT"
  local vmlinuz="$sysroot/boot/vmlinuz"
  local failed=0

  if [ "$ARCH" = "x86" ]; then
    # There is no syslinux on ARM, so this copy only makes sense for x86.
    set +e
    local esp_offset=$(partoffset "$RECOVERY_IMAGE" 12)
    local esp_mnt=$(mktemp -d)
    sudo mount -o loop,offset=$((esp_offset * 512)) "$RECOVERY_IMAGE" "$esp_mnt"
    sudo cp "$vmlinuz" "$esp_mnt/syslinux/vmlinuz.A" || failed=1
    sudo umount -d "$esp_mnt"
    rmdir "$esp_mnt"
    set -e
  fi

  if [ $failed -eq 1 ]; then
    echo "Failed to copy recovery kernel to ESP"
    return 1
  fi
  return 0
}

update_partition_table() {
  local src_img=$1          # source image
  local temp_state=$2       # stateful partition image
  local resized_sectors=$3  # number of sectors in resized stateful partition
  local temp_img=$4

  local kern_a_offset=$(partoffset ${src_img} 2)
  local kern_a_count=$(partsize ${src_img} 2)
  local kern_b_offset=$(partoffset ${src_img} 4)
  local kern_b_count=$(partsize ${src_img} 4)
  local rootfs_offset=$(partoffset ${src_img} 3)
  local rootfs_count=$(partsize ${src_img} 3)
  local oem_offset=$(partoffset ${src_img} 8)
  local oem_count=$(partsize ${src_img} 8)
  local esp_offset=$(partoffset ${src_img} 12)
  local esp_count=$(partsize ${src_img} 12)

  local temp_pmbr=$(mktemp "/tmp/pmbr.XXXXXX")
  dd if="${src_img}" of="${temp_pmbr}" bs=512 count=1 &>/dev/null

  trap "rm -rf \"${temp_pmbr}\"" EXIT
  # Set up a new partition table
  install_gpt "${temp_img}" "${rootfs_count}" "${resized_sectors}" \
    "${temp_pmbr}" "${esp_count}" false \
    $(((rootfs_count * 512)/(1024 * 1024)))

  # Copy into the partition parts of the file
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ROOTFS_A}" skip=${rootfs_offset} count=${rootfs_count}
  dd if="${temp_state}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_STATEFUL}"
  # Copy the full kernel (i.e. with vboot sections)
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_KERN_A}" skip=${kern_a_offset} count=${kern_a_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_KERN_B}" skip=${kern_b_offset} count=${kern_b_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_OEM}" skip=${oem_offset} count=${oem_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ESP}" skip=${esp_offset} count=${esp_count}
}

maybe_resize_stateful() {
  # If we're not minimizing, then just copy and go.
  if [ $FLAGS_minimize_image -eq $FLAGS_FALSE ]; then
    if [ "$FLAGS_image" != "$RECOVERY_IMAGE" ]; then
      cp "$FLAGS_image" "$RECOVERY_IMAGE"
    fi
    return 0
  fi

  # Rebuild the image with a 1 sector stateful partition
  local err=0
  local small_stateful=$(mktemp)
  dd if=/dev/zero of="$small_stateful" bs=512 \
    count=${FLAGS_statefulfs_sectors} 1>&2
  trap "rm $small_stateful" RETURN
  # Don't bother with ext3 for such a small image.
  /sbin/mkfs.ext2 -F -b 4096 "$small_stateful" 1>&2

  # If it exists, we need to copy the vblock over to stateful
  # This is the real vblock and not the recovery vblock.
  local new_stateful_mnt=$(mktemp -d)

  set +e
  sudo mount -o loop $small_stateful $new_stateful_mnt
  sudo cp "$INSTALL_VBLOCK" "$new_stateful_mnt/vmlinuz_hd.vblock"
  sudo mkdir "$new_stateful_mnt/var"
  sudo umount -d "$new_stateful_mnt"
  rmdir "$new_stateful_mnt"
  set -e

  # Create a recovery image of the right size
  # TODO(wad) Make the developer script case create a custom GPT with
  # just the kernel image and stateful.
  update_partition_table "$FLAGS_image" "$small_stateful" 4096 \
                         "$RECOVERY_IMAGE" 1>&2
  return $err
}

cleanup() {
  set +e
  if [ "$FLAGS_image" != "$RECOVERY_IMAGE" ]; then
    rm "$RECOVERY_IMAGE"
  fi
  rm "$INSTALL_VBLOCK"
}

# main process begins here.
set -u

IMAGE_DIR="$(dirname "$FLAGS_image")"
IMAGE_NAME="$(basename "$FLAGS_image")"
RECOVERY_IMAGE="${FLAGS_to:-$IMAGE_DIR/recovery_image.bin}"
RECOVERY_KERNEL_IMAGE=\
"${FLAGS_kernel_outfile:-${IMAGE_DIR}/recovery_vmlinuz.image}"
RECOVERY_KERNEL_VBLOCK="${RECOVERY_KERNEL_IMAGE}.vblock"
STATEFUL_DIR="$IMAGE_DIR/stateful_partition"
SCRIPTS_DIR=${SCRIPT_ROOT}

# Mounts gpt image and sets up var, /usr/local and symlinks.
# If there's a dev payload, mount stateful
#  offset=$(partoffset "${FLAGS_from}/${filename}" 1)
#  sudo mount ${ro_flag} -o loop,offset=$(( offset * 512 )) \
#    "${FLAGS_from}/${filename}" "${FLAGS_stateful_mountpt}"
# If not, resize stateful to 1 sector.
#

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE -a \
     -n "$FLAGS_kernel_image" ]; then
  die "Cannot use --kernel_image_only with --kernel_image"
fi

if [ $FLAGS_modify_in_place -eq $FLAGS_TRUE ]; then
  if [ $FLAGS_minimize_image -eq $FLAGS_TRUE ]; then
    die "Cannot use --modify_in_place and --minimize_image together."
  fi
  RECOVERY_IMAGE="${FLAGS_image}"
fi

echo "Creating recovery image from ${FLAGS_image}"

INSTALL_VBLOCK=$(get_install_vblock)
if [ -z "$INSTALL_VBLOCK" ]; then
  die "Could not copy the vblock from stateful."
fi

# Build the recovery kernel.
FACTORY_ROOT="${BOARD_ROOT}/factory-root"
USE="fbconsole initramfs" emerge_custom_kernel "$FACTORY_ROOT" ||
  failboat "Cannot emerge custom kernel"

if [ -z "$FLAGS_kernel_image" ]; then
  create_recovery_kernel_image
  echo "Recovery kernel created at $RECOVERY_KERNEL_IMAGE"
else
  RECOVERY_KERNEL_IMAGE="$FLAGS_kernel_image"
fi

if [ $FLAGS_kernel_image_only -eq $FLAGS_TRUE ]; then
  echo "Kernel emitted. Stopping there."
  rm "$INSTALL_VBLOCK"
  exit 0
fi

if [ $FLAGS_modify_in_place -eq $FLAGS_FALSE ]; then
  rm "$RECOVERY_IMAGE" || true  # Start fresh :)
fi

trap cleanup EXIT

maybe_resize_stateful  # Also copies the image if needed.

install_recovery_kernel

echo "Recovery image created at $RECOVERY_IMAGE"
print_time_elapsed
trap - EXIT
