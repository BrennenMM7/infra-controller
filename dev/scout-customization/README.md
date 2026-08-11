# Custom Scout image end-to-end test

This workflow boots the branch-built x86 Scout loader and root filesystem in a
plain QEMU virtual machine, delivers the site customization through the
branch-built PXE service, controls power through bmc-mock, and verifies the
result over SSH. It uses this repository and public Debian, Rust, and Ubuntu
package sources only; no private simulator or internal repository is required.

The pass condition is deterministic and independent of package repositories.
NICo writes an input file and a systemd unit into Scout. The unit copies the
input to `/run/nico-scout-customization-e2e/passed`, verifies its exact
contents, and prints `NICO_SCOUT_CUSTOMIZATION_E2E_PASS` to the serial console.
SSH starts only after the Scout customization gate succeeds, so reading that
marker over SSH covers file delivery, unit enablement and start, cloud-init
completion, and the resulting live image.

## Components

- Tilt and Kind run the branch-built NICo API with the opt-in customization
  fixture from [`../deployment/tilt/values.yaml`](../deployment/tilt/values.yaml).
- The test container builds bmc-mock and `carbide-pxe` from the current checkout.
- The same container owns an isolated libvirt network and x86 QEMU VM. QEMU uses
  KVM on an x86 Linux host when available and software emulation elsewhere.
- A local TCP proxy makes Tilt's API port available to the guest without
  changing the guest-visible source address used by PXE client resolution.

The VM stays online after a passing run so the boot can be inspected. The
`restore` command removes only the test container/network and the one static
interface address assigned by the harness.

## Requirements

- The local Kind cluster and Tilt requirements from
  [`../deployment/tilt/README.md`](../deployment/tilt/README.md).
- Docker with at least 6 GiB of memory available to the test container.
- The commands `cargo-make`, `curl`, `docker`, `jq`, `kubectl`, `openssl`,
  and `tilt`.
- An x86 host for fast KVM execution, or enough CPU time for x86 software
  emulation on an Arm host.

Start Tilt if it is not already running:

```bash
tilt up -f dev/deployment/tilt/Tiltfile
```

## Build and run

Build the real x86 Scout UKI and SquashFS. The build runs in the repository's
privileged PXE build container and writes the artifacts under
`pxe/static/blobs/internal/x86_64/`. The wrapper uses a test-specific Linux
Cargo cache so a macOS host's Cargo binaries are never mounted into the build
container:

```bash
dev/scout-customization/test.sh build
```

Run the test:

```bash
dev/scout-customization/test.sh run
```

The harness performs these scoped actions:

1. Enables the Tilt `scout-customization` profile and rebuilds `nico-api`.
2. Selects an unused secondary machine-a-tron host interface, gives the
   interface and QEMU guest the address `172.30.0.10`, and uses its real MAC.
3. Signs a short-lived PXE client certificate with the committed local-dev CA.
4. Builds the public-image QEMU/bmc-mock/PXE container from this checkout.
5. Powers on the VM through bmc-mock's Redfish endpoint.
6. Waits up to 15 minutes for the exact customization marker over SSH.

## Inspect and clean up

Show the container, VM state, and serial console tail:

```bash
dev/scout-customization/test.sh status
```

Connect to the live Scout VM after the test passes:

```bash
docker exec -it nico-scout-customization-test \
  sshpass -p password ssh -o StrictHostKeyChecking=no root@172.30.0.10
```

Tear down the isolated lab and remove the temporary NICo address assignment:

```bash
dev/scout-customization/test.sh restore
```

Temporary certificates remain under `/tmp/nico-scout-customization-test` for
debugging. Inspect the runtime logs with `status` before `restore` removes the
test container. A subsequent `run` creates fresh certificates.
