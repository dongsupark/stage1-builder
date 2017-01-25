#!/bin/bash

test -n "${DEBUG}" && set -x || DEBUG=
set -eu
set -o pipefail

if [[ $# -gt 3 ]]; then
  echo "Usage: $0 [<kernel version> [<target dir> [<build dir>]]]" >&2
  echo "Example: $0 4.9.4 aci/ /tmp/aci-build" >&2
  exit 1
fi

readonly kernel_latest_stable="4.9.4"

readonly dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly kernel_version="${1:-${kernel_latest_stable}}"
readonly kernel_version_suffix="-kinvolk-v1"
readonly aci_dir="${2:-${dir}/aci/${kernel_version}}"
mkdir -p "${aci_dir}"
readonly target_aci="stage1-kvm-linux-${kernel_version}.aci"
readonly rootfs_dir="${aci_dir}/rootfs"
mkdir -p "${rootfs_dir}"
readonly build_dir="${3:-${dir}/build/${kernel_version}}"
mkdir -p "${build_dir}"
readonly kernel_url="https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-${kernel_version}.tar.xz"
readonly kernel_dir="${build_dir}/kernel"
mkdir -p "${kernel_dir}"
readonly kernel_source_dir="${kernel_dir}/source"
mkdir -p "${kernel_source_dir}"
readonly kernel_config="${dir}/config/linux-${kernel_version}.config"
readonly kernel_bzimage="${kernel_source_dir}/arch/x86/boot/bzImage"
readonly kernel_reboot_patch_url="https://raw.githubusercontent.com/coreos/rkt/v1.22.0/stage1/usr_from_kvm/kernel/patches/0001-reboot.patch"
readonly kernel_header_dir="/lib/modules/${kernel_version}${kernel_version_suffix}/source"
readonly busybox_mkdir_url="https://busybox.net/downloads/binaries/1.26.2-i686/busybox_MKDIR"

test -f "${kernel_config}" ||
{
  echo "couldn't find config for kernel ${kernel_version} in ${dir}/config - aborting" >&2
  exit 1
}

# download kernel
test -f "${kernel_dir}/kernel.tar.xz" || curl -LsS "${kernel_url}" -o "${kernel_dir}/kernel.tar.xz"

# unpack kernel
test "$(find "${kernel_source_dir}" -maxdepth 0 -type d -empty 2>/dev/null)" && tar -C "${kernel_source_dir}" --strip-components=1 -xf "${kernel_dir}/kernel.tar.xz"

# configure kernel
test -f "${kernel_source_dir}/.config" || sed -e "s/-rkt-v1/${kernel_version_suffix}/g" "${kernel_config}" >"${kernel_source_dir}/.config"

# build kernel
test -f "${kernel_bzimage}" ||
(
  cd "${kernel_source_dir}"
  curl -LsS "${kernel_reboot_patch_url}" -O
  # TODO(schu) fails when patch was applied already
  patch --silent -p1 < *.patch
  make bzImage
)

# import kernel
rsync -a "${kernel_bzimage}" "${rootfs_dir}/bzImage"

# import kernel header
mkdir -p "${rootfs_dir}/${kernel_header_dir}"
(
  cd "${kernel_source_dir}"
  make headers_install INSTALL_HDR_PATH="${rootfs_dir}/${kernel_header_dir}" >/dev/null
  rsync -a "${kernel_source_dir}/include/" "${rootfs_dir}/${kernel_header_dir}/include/"
)

# add busybox mkdir to stage1
mkdir -p "${rootfs_dir}/usr/bin"
test -f "${rootfs_dir}/usr/bin/mkdir" ||
(
  cd "${rootfs_dir}/usr/bin"
  curl -LsS "${busybox_mkdir_url}" -o "mkdir"
  chmod +x "mkdir"
)

# add systemd drop-in to bind mount kernel headers
mkdir -p "${rootfs_dir}/etc/systemd/system/prepare-app@.service.d"
cat <<EOF >"${rootfs_dir}/etc/systemd/system/prepare-app@.service.d/10-bind-mount-kernel-header.conf"
[Service]
ExecStartPost=/usr/bin/mkdir -p %I/${kernel_header_dir}
ExecStartPost=/usr/bin/mount --bind "${kernel_header_dir}" %I/${kernel_header_dir}
EOF

# include manifest
sed -e "s/{{kernel_version}}/${kernel_version}/" "${dir}/manifest.tmpl.json" >"${aci_dir}/manifest"

# build aci
tar -czf "${target_aci}" -C "${aci_dir}" .
echo "Successfully build ${target_aci}"
