---
name: verify-jamberry-image-change
description: Build and verify a jamberry-os image change locally before opening a PR. Use whenever editing Containerfile, build/*.sh, custom/ (Brewfiles, Flatpaks, ujust), Justfile, or iso/*.toml — adding or removing a package, swapping a default app, changing build scripts, or bumping a base image. Builds rootful with podman, runs the container contract test, optionally boots the image in a KVM VM to assert on a real booted system, then commits on a branch and opens a PR.
---

# Verify a jamberry-os image change

Nothing here is theoretical: every command below has been run on this machine.
Work through the tiers in order and stop at the first failure.

## Host requirement (enforced)

Both tier scripts call `require_supported_host` from `scripts/preflight.sh` and
refuse to run anywhere they cannot produce a trustworthy result. **x86-64 Linux
with KVM.** Tier 2 additionally needs `/dev/kvm` plus `virsh`, `virt-install`,
`qemu-img` and `expect`.

This is fatal rather than advisory because of how it fails on Apple Silicon.
The pinned silverblue base is a multi-arch index carrying both `linux/amd64`
and `linux/arm64`, while CI publishes **amd64 only**. So on an M-series Mac
`podman build` does not error — it selects the arm64 base, builds an arm64
image, and passes `tests/image-contract.sh`. You get a green run for an
artifact that will never ship. A false pass is worse than a crash.

macOS is refused outright: podman there runs inside its own Linux VM with no
`/dev/kvm` to nest a bootc VM inside, so tier 2 cannot boot anything.

`VERIFY_ALLOW_UNSUPPORTED_HOST=1` overrides the arch check for **tier 1 only**,
printing a warning and marking results advisory. There is no override for tier
2 — without KVM there is nothing to boot. When you are on an unsupported
machine, push a branch and let CI verify instead:

```bash
gh workflow run build-image.yml --ref <your-branch>
```

## Choose a tier before you start

| Tier | Cost | Run it when |
| --- | --- | --- |
| 1 — build + container contract | ~3 min warm | **Always.** Every change. |
| 2 — boot the image in a VM | ~15 min | The change could affect boot, services, `/opt`, `/var`, systemd units, or anything whose behaviour differs between a container and a booted system. |
| 3 — rebase an existing system | ~20 min | Rarely. Only to validate the upgrade path itself. Needs the image published, so it happens *after* merge, not before. |

Tier 1 catches most regressions. Tier 2 exists because a container test
structurally cannot tell you whether `/opt` survived, whether a unit started, or
whether a compiled gschema actually resolves. Reach for it when the change
touches those.

## Tier 1 — build and contract (always)

```bash
.claude/skills/verify-jamberry-image-change/scripts/tier1-build-contract.sh
```

That runs, in order: `just lint` (shellcheck), `just check` (Justfile syntax),
`sudo -E just build`, then `tests/image-contract.sh` against the built image.

**Build rootful.** `sudo -E just build …`, not plain `just build`. A rootless
build fails at the final `bootc container lint` step with
`Permission denied` on `/sys/kernel/security/ima/binary_runtime_measurements`.
That is a rootless artifact, not a defect in the image — CI runs rootful and
reports `Checks passed: 13`.

**Don't trust OCI labels on a local build.** `GITHUB_REPOSITORY_OWNER` and
`GITHUB_SHA` are unset outside Actions, so the Justfile falls back to `REPO_ORG`
and you get `vendor="projectbluefin"` and a `source` URL with empty segments.
CI sets both. Labels are only meaningful on published images.

If the change adds or removes a package, extend `tests/image-contract.sh` in the
same PR. A change that nothing asserts on is a change nobody will notice
breaking later.

## Tier 2 — boot it in a VM

```bash
.claude/skills/verify-jamberry-image-change/scripts/tier2-vm-boot.sh
```

Builds a qcow2 from the **local** image with bootc-image-builder, boots it
headless under KVM, bootstraps SSH over the serial console, and runs
`.claude/skills/verify-jamberry-image-change/assets/booted-contract.sh` against the running system.

This boots the locally built image rather than rebasing onto a published one,
which is the whole point pre-PR: your change is not on ghcr yet.

Add assertions to `.claude/skills/verify-jamberry-image-change/assets/booted-contract.sh` for anything runtime-visible.
It already covers the ones that burned us: `/opt` being a real directory
(the base image ships it as a symlink to `var/opt`, so packages installing
there vanish on a real system), `gsettings` resolving the compiled gschema
override, `xdg-settings` reporting the default browser, and
`systemctl is-system-running` reporting `running` with no failed units.

## Tier 3 — rebase path (post-merge)

Once CI has published, rebase a stock Silverblue VM onto it:

```bash
sudo bootc switch --transport registry ghcr.io/multigl/jamberry-os:stable-daily
sudo systemctl reboot
```

Use `stable-daily`, not `stable`. CI's `generate-tags` emits
`stable-daily` as the default tag; `:stable` is promoted separately by a
**weekly scheduled workflow**, so it deliberately lags and is not what you want
when verifying a change you just merged.

## Then, and only then: the PR

Per `AGENTS.md`, before committing:

1. Conventional Commit format — `<type>(<scope>): <subject>`, types and scopes in `.github/commit-convention.md`
2. `shellcheck` any modified `*.sh`
3. `python3 -c "import yaml; yaml.safe_load(open('FILE'))"` any modified YAML
4. `just --list` to verify Justfile syntax
5. **Confirm with the user before committing and pushing**

Never push to `main` — branch and PR. Add the attribution footer:

```
Assisted-by: [Model Name] via [Tool Name]
```

Pushing anything under `.github/workflows/` needs the PAT's **Workflows: write**
permission, and `gh workflow run` needs **Actions: write**. These are separate
fine-grained permissions. On a 403, run `gh api -i <path>` and read the
`X-Accepted-Github-Permissions` header — it names exactly what is missing.

## Failure modes that cost real time here

These all fail *silently* — several while returning exit code 0.

- **`bootc-image-builder` needs `--rootfs btrfs`.** The Fedora silverblue base
  carries no `bootc.diskimage-rootfs` label; without the flag bib dies with
  `missing required info: DefaultRootFs`.
- **bib rejects `[customizations.services]` for qcow2** — it prints
  `blueprint validation failed … not supported`, then *continues and exits 0*,
  handing you an image without your customization. A zero exit from bib does not
  mean the blueprint applied. This is why the VM scripts enable sshd over the
  serial console instead.
- **Fedora Silverblue ships `sshd` disabled.** A fresh VM answers port 22 with
  `Connection refused` until it is enabled.
- **The interactive shell here is zsh, which does not word-split unquoted
  variables.** `ssh $OPTS host` passes one giant argument. Inline ssh options or
  use an array. This silently caused a reboot to never happen while every exit
  code stayed 0.
- **`pkill -f "virsh console"` matches its own command line** and kills the job
  it is running inside. Use `pkill -f "[v]irsh console"`.
- **Always confirm a reboot happened** (`uptime -p`) before asserting on a
  rebooted system. A TCP connect to port 22 can succeed against the *pre-reboot*
  sshd, making stale results look like a pass.

## Environment facts

Fedora 44 Cloud, 8 vCPU / 15 GiB, passwordless sudo, `/dev/kvm` with nested virt,
libvirt 12 + QEMU 10.2. Podman builds with native overlay on btrfs — a full cold
image build is ~90 s locally.
