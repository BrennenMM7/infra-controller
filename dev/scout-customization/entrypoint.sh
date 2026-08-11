#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly domain_name=nico-scout-test
readonly network_name=nico-scout-test
readonly runtime_dir=/var/lib/nico-scout-test
readonly log_dir=/var/log/nico-scout-test

health() {
    curl --fail --silent --show-error http://127.0.0.1:18080/metrics >/dev/null
    curl --insecure --fail --silent --show-error \
        https://127.0.0.1:1266/redfish/v1/Systems >/dev/null
    virsh --connect qemu:///system dominfo "${domain_name}" >/dev/null
}

if [[ "${1:-}" == health ]]; then
    health
    exit 0
fi

: "${SCOUT_TEST_INTERFACE_ID:?SCOUT_TEST_INTERFACE_ID is required}"
: "${SCOUT_TEST_MAC_ADDRESS:?SCOUT_TEST_MAC_ADDRESS is required}"

readonly scout_efi=/forge-boot-artifacts/blobs/internal/x86_64/scout.efi
readonly scout_rootfs=/forge-boot-artifacts/blobs/internal/x86_64/scout.squashfs

for artifact in "${scout_efi}" "${scout_rootfs}" /certs/ca.crt /certs/tls.crt /certs/tls.key; do
    if [[ ! -s "${artifact}" ]]; then
        echo "required test artifact is missing or empty: ${artifact}" >&2
        exit 1
    fi
done

mkdir -p "${runtime_dir}" "${log_dir}"
chmod 0777 "${log_dir}"

objcopy \
    --dump-section ".linux=${runtime_dir}/scout-loader-kernel" \
    --dump-section ".initrd=${runtime_dir}/scout-loader-initrd" \
    "${scout_efi}"
chmod 0644 "${runtime_dir}/scout-loader-kernel" "${runtime_dir}/scout-loader-initrd"

domain_type=qemu
if [[ "$(uname -m)" == x86_64 && -c /dev/kvm ]]; then
    domain_type=kvm
fi

sed \
    -e "s/@DOMAIN_TYPE@/${domain_type}/g" \
    -e "s/@SCOUT_TEST_INTERFACE_ID@/${SCOUT_TEST_INTERFACE_ID}/g" \
    -e "s/@SCOUT_TEST_MAC_ADDRESS@/${SCOUT_TEST_MAC_ADDRESS}/g" \
    /opt/nico-scout-test/domain.xml.tmpl >"${runtime_dir}/domain.xml"
sed \
    -e "s/@SCOUT_TEST_MAC_ADDRESS@/${SCOUT_TEST_MAC_ADDRESS}/g" \
    /opt/nico-scout-test/network.xml >"${runtime_dir}/network.xml"

# The daemon and QEMU live together in this disposable privileged container.
# Running QEMU as root avoids host-specific DAC/AppArmor differences in the
# bind-mounted Scout artifacts and generated serial log.
printf '\nuser = "root"\ngroup = "root"\nsecurity_driver = "none"\n' >>/etc/libvirt/qemu.conf

virtlogd -d
libvirtd -d
for ((libvirt_attempt = 0; libvirt_attempt < 60; libvirt_attempt++)); do
    if virsh --connect qemu:///system list >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
virsh --connect qemu:///system list >/dev/null

virsh --connect qemu:///system net-define "${runtime_dir}/network.xml" >/dev/null
virsh --connect qemu:///system net-start "${network_name}" >/dev/null
virsh --connect qemu:///system net-autostart "${network_name}" >/dev/null
virsh --connect qemu:///system define "${runtime_dir}/domain.xml" >/dev/null

export CARBIDE_API_INTERNAL_URL=https://host.docker.internal:1079
export CARBIDE_API_URL=https://host.docker.internal:1079
export CARBIDE_PXE_URL=http://172.30.0.1:18080
export CARBIDE_STATIC_PXE_URL=http://172.30.0.1:18080
export FORGE_ROOT_CAFILE_PATH=/certs/ca.crt
export FORGE_BOOTSTRAP_ROOT_CAFILE_PATH=/certs/ca.crt
export FORGE_CLIENT_CERT_PATH=/certs/tls.crt
export FORGE_CLIENT_KEY_PATH=/certs/tls.key
export PXE_BIND_ADDRESS=0.0.0.0
export PXE_BIND_PORT=18080
export CARBIDE_PXE_TEMPLATE_DIRECTORY=/opt/carbide/pxe/templates

/usr/local/bin/carbide -s /forge-boot-artifacts >"${log_dir}/pxe.log" 2>&1 &
pxe_pid=$!
socat TCP-LISTEN:1079,reuseaddr,fork TCP:host.docker.internal:1079 \
    >"${log_dir}/api-proxy.log" 2>&1 &
api_proxy_pid=$!
socat TCP-LISTEN:2222,reuseaddr,fork TCP:172.30.0.10:22 \
    >"${log_dir}/ssh-proxy.log" 2>&1 &
ssh_proxy_pid=$!
/usr/local/bin/bmc-mock \
    --cert-path /opt/carbide/bmc-tls \
    --port 1266 \
    --machine-role host \
    --state-backend libvirt \
    --libvirt-domain "${domain_name}" \
    --hardware-profile generic_ami \
    --dpu-count 0 \
    --instance-index 1 \
    --libvirt-uri qemu:///system >"${log_dir}/bmc-mock.log" 2>&1 &
bmc_pid=$!

cleanup() {
    virsh --connect qemu:///system destroy "${domain_name}" >/dev/null 2>&1 || true
    kill "${bmc_pid}" "${pxe_pid}" "${api_proxy_pid}" "${ssh_proxy_pid}" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT TERM INT

wait -n "${bmc_pid}" "${pxe_pid}" "${api_proxy_pid}" "${ssh_proxy_pid}"
echo "a Scout lab service exited unexpectedly" >&2
exit 1
