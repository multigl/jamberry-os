#!/usr/bin/env bash
###############################################################################
# Tier 2: boot the locally built image in a KVM VM and assert on the result.
#
# Builds a qcow2 from the LOCAL image rather than rebasing onto a published one,
# because pre-PR the change is not on ghcr yet. That makes this an install test
# rather than an upgrade test - the upgrade path is tier 3, after merge.
#
# Idempotent: safe to re-run. Recreates the domain each time.
###############################################################################
set -euo pipefail

# Refuse hosts where this loop cannot produce a trustworthy result.
# Resolved at runtime relative to this script; shellcheck cannot follow it
# from the repo root, where `just lint` runs.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
require_supported_host 2

# This skill lives outside the repo (~/.claude/skills), so the repo is wherever
# the caller is, not wherever this script is. Resolve them independently and
# refuse to run anywhere that is not a jamberry-os checkout.
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "Not inside a git repository. cd to your jamberry-os checkout first." >&2
	exit 1
}
cd "${REPO_ROOT}"
if [[ ! -f Containerfile || ! -f Justfile || ! -f tests/image-contract.sh ]]; then
	echo "${REPO_ROOT} does not look like a jamberry-os checkout." >&2
	exit 1
fi

IMAGE_NAME=${IMAGE_NAME:-jamberry-os}
TAG=${TAG:-stable}
VM=${VM:-jamberry-verify}
WORK=${WORK:-${HOME}/.local/share/jamberry-vmtest}
BIB=${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}
VMUSER=tester
VMPASS=tester
DISK=/var/lib/libvirt/images/${VM}.qcow2

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
# Rootful sudo preserves XDG_RUNTIME_DIR, which lets root-owned state land in
# the user's runtime dir and breaks later rootless just/podman calls with
# EACCES. Scrub it from every rootful invocation.
sudoif() { sudo -E env -u XDG_RUNTIME_DIR "$@"; }
die() {
	printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2
	exit 1
}

mkdir -p "${WORK}/output"
[[ -f ${WORK}/id_vmtest ]] ||
	ssh-keygen -t ed25519 -N '' -f "${WORK}/id_vmtest" -C jamberry-vmtest >/dev/null

# Inline every ssh option. This shell is zsh in interactive use and does not
# word-split unquoted variables, so a collected "$SSHOPTS" would arrive as one
# argument and fail in ways that still return 0.
vm_ssh() {
	ssh -i "${WORK}/id_vmtest" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR \
		"${VMUSER}@${1}" "${@:2}"
}

sudoif podman image exists "localhost/${IMAGE_NAME}:${TAG}" ||
	die "localhost/${IMAGE_NAME}:${TAG} not in rootful storage. Run tier 1 first."

step "Writing bootc-image-builder blueprint"
# No [customizations.services] block: bib rejects it for qcow2, prints
# "blueprint validation failed ... not supported", and then exits 0 anyway,
# silently handing back an image without it. sshd is enabled post-boot instead.
cat >"${WORK}/verify.toml" <<EOF
[[customizations.user]]
name = "${VMUSER}"
password = "${VMPASS}"
key = "$(cat "${WORK}/id_vmtest.pub")"
groups = ["wheel"]

[[customizations.filesystem]]
mountpoint = "/"
minsize = "30 GiB"
EOF

step "Building qcow2 from localhost/${IMAGE_NAME}:${TAG}"
# --rootfs is required: the Fedora silverblue base carries no
# bootc.diskimage-rootfs label, and bib refuses to guess.
sudo rm -rf "${WORK}/output/qcow2"
sudoif podman run --rm --privileged --security-opt label=type:unconfined_t \
	-v "${WORK}/verify.toml":/config.toml:ro \
	-v "${WORK}/output":/output \
	-v /var/lib/containers/storage:/var/lib/containers/storage \
	"${BIB}" --type qcow2 --rootfs btrfs "localhost/${IMAGE_NAME}:${TAG}"

[[ -f ${WORK}/output/qcow2/disk.qcow2 ]] || die "bib produced no disk.qcow2"

step "Recreating VM ${VM}"
sudoif virsh destroy "${VM}" 2>/dev/null || true
sudoif virsh undefine "${VM}" --nvram 2>/dev/null || true
sudo cp "${WORK}/output/qcow2/disk.qcow2" "${DISK}"
sudo chown qemu:qemu "${DISK}"
sudo restorecon -F "${DISK}" 2>/dev/null || true
sudoif qemu-img resize "${DISK}" 40G >/dev/null

sudoif virt-install --name "${VM}" \
	--memory 4096 --vcpus 4 --cpu host-passthrough \
	--import --disk "path=${DISK},format=qcow2,bus=virtio" \
	--network network=default,model=virtio \
	--osinfo detect=on,name=fedora-rawhide \
	--boot uefi --graphics none \
	--console pty,target_type=serial --noautoconsole

step "Waiting for the VM to reach a login prompt"
MAC=$(sudoif virsh domiflist "${VM}" | awk '/network/{print $5; exit}')
IP=""
for _ in $(seq 1 60); do
	sleep 5
	IP=$(sudoif virsh net-dhcp-leases default 2>/dev/null |
		awk -v m="${MAC}" '$0 ~ m {split($5,a,"/"); print a[1]; exit}')
	[[ -n ${IP} ]] && break
done
[[ -n ${IP} ]] || die "VM never took a DHCP lease"
echo "VM address: ${IP}"

step "Bootstrapping sshd and sudo over the serial console"
# Silverblue-derived images ship sshd disabled, and wheel needs a password, so
# a non-interactive ssh cannot sudo. Fix both once, here, over the console.
sudoif "${SKILL_DIR}/assets/console.exp" "${VM}" "${VMUSER}" "${VMPASS}" \
	"sudo systemctl enable --now sshd; echo '${VMUSER} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-${VMUSER} >/dev/null; sudo chmod 0440 /etc/sudoers.d/90-${VMUSER}; systemctl is-active sshd" |
	sed 's/\r$//' | grep -E '^(active|__RC=)' || true

step "Waiting for SSH"
for _ in $(seq 1 40); do
	vm_ssh "${IP}" true 2>/dev/null && break
	sleep 5
done
vm_ssh "${IP}" true 2>/dev/null || die "SSH never came up on ${IP}"

step "Booted image identity"
vm_ssh "${IP}" 'sudo bootc status --format=yaml' |
	grep -E '^  (staged|booted|rollback):|^      (version|timestamp):|^        image:' || true

step "Booted-system contract"
# Piped over stdin rather than scp'd: /tmp is tmpfs and does not survive a
# reboot, and this avoids depending on the sftp subsystem.
vm_ssh "${IP}" 'bash -s' <"${SKILL_DIR}/assets/booted-contract.sh" ||
	die "booted contract assertions failed"

cat <<EOF

Tier 2 passed. VM '${VM}' is still running at ${IP}:

  ssh -i ${WORK}/id_vmtest ${VMUSER}@${IP}

Tear it down with:

  sudo virsh destroy ${VM} && sudo virsh undefine ${VM} --nvram
EOF
