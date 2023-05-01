
# reUpNix LCTES23 Artifact description

For the most part, we have automated tests produced by Nix builds that generate CSV files in `./out/`.
Those files are then processed further into PDF figures and `dref` LaTeX data points (also automated), which we directly include in our paper.

An exception to this are the reboot logs in `./data/logs/`.
Capturing the serial output of a Raspberry Pi (to get accurate reboot times in absence of a real-time clock), they need some manual steps (detailed below).

We are (sometimes intentionally and sometimes inevitably) doing things that cause Nix to reevaluate the package set and/or produce outputs with different addresses -- many times over.
Consequently, Nix sometimes evaluates several dozen package sets in a single run (we've seen RAM RES sizes of up to 40GiB, but usually it is not above 16GiB), and we need to download and/or build from source multiple instances of all packages in the base Linux system, plus all applications, plus (due to how Nix works) most of the tooling that builds those things.

In total, the build and evaluation steps take several hundred CPU (thread) hours and produce around 85GiB of output.
Due to the computational requirements and output size of the builds, we decided not to provide a virtual machine.
All Nix builds happen inside Nix's sandbox, and none of the evaluations have any hardware requirements (past what's listed below), so feel free to wrap the whole thing in your own VM environment, use cloud-hosted VMs, etc.


## Requirements

* For most evaluations: an `x86_64` build host with:
	* about 100GB disk space (excluding `/tmp`, compression is quite effective),
	* several hundred hours CPU time,
	* (estimated) at least 32GB RAM (complemented with swap to at least 64 GB memory).
* For the `rpi`/`aarch64` evaluations: an `aarch64` build host with:
	* about 50GB disk space (excluding `/tmp`, compression is quite effective),
	* a few hundred hours CPU time,
	* (estimated) at least 16GB RAM (complemented with swap to at least 48 GB memory).
* On those, some sort of recent-ish Linux with `nix` **or**:
	* `/usr/bin/env` (with support for `-S` flag, e.g. GNU coreutils),
	* `bash` (tested with v5.1) with basic utilities,
	* `docker` or `podman` able to run `--privileged` containers
		* ... as `root` (else some parts of the evaluation will require workarounds and/or may not work).
* For the reconfigure time benchmark: a Raspberry Pi 4 (B) with (ideally) a "SanDisk Extreme PRO" 32GB microSD card and an UART adapter.


## Step-by-Step Instructions

All commands below are meant to be run in a bash shell in the `./artifact/` directory (or a shell launched from there), and all paths from here on are expressed relative to that directory.


### Getting Nix

Depending on some choices regarding cross-compilation and the presence of a dedicated `aarch64` (Nix) builder, the `x64` build host will need to execute some `aarch64` ELFs.
This is enabled via a `binfmt_misc` registration -- either preexisting or performed as deemed necessary (and not suppressed, see the `--no-binfmt` option in the help output below).

It would probably be easiest to [install Nix](https://nixos.org/download.html) (plus the `aarch64` `binfmt_extra` registration and an `extra-platforms = aarch64-linux` in the `nix.conf`).
Alternatively, follow these steps to run things in a privileged docker (or podman) container:

```bash
./utils/container-nix --help
./utils/container-nix --options=... -- # decide based on the above what options you need
./utils/container-nix --options=... --init -- # if the command failed the first time, and now says it can't find bash
nix store ping && echo good || echo bad # once a shell in the container opens, this should succeed (inside that shell)
# now either just keep working in the container shell (and feel free to open more than one with the same arguments), and/or:
alias nix='./utils/container-nix --options=... --' # outside the container, set this to automatically run nix commands in the container
nix store ping && echo good || echo bad # in any shell with the above alias set, "nix" should now work
```


### Builds and Experiments

The next steps replace/(re-)create files in `./out/`.
One may want to start by clearing that directory to ensure that everything will actually be generated from scratch.


#### Fully Automated Things

Then run these commands to (re-)create the first of the `out`-files:
```bash
nix build --no-link --keep-going .'#'checks.x86_64-linux.nix_store_send .'#'checks.x86_64-linux.container-sizes .'#'checks.x86_64-linux.install-size-x64 # running this is optional, but makes it clear when (intermittent or setup-related) build errors happen -- see #troubleshooting below if that happens
nix run .'#'check:nix_store_send
nix run .'#'check:container-sizes
nix run .'#'check:install-size-x64
```

If all commands competed successfully, they should have (re-)created these files:
```
out/nix_store_send.csv
out/oci-individual.csv
out/oci-variants.csv
out/dref-ext/install-x64-baseline.tex
out/dref-ext/install-x64-minimal.tex
out/systems/x64_baseline.csv
out/systems/x64_minimal.csv
```


#### `aarch64` Builds + Installations

The `data/systems/rpi_*.csv` files and the Raspberry Pi image for the `data/logs/*` (next section) we tested with were generated using native `aarch64` compilation (in our case on a powerful `aarch64` host).
By default, `./utils/container-nix` ensures that the build host has a `binfmt_misc` registration for `aarch64` ELFs.
With that, Nix (any anything else on the system) can transparently use `qemu-user` emulated execution of `aarch64` ELFs, and can thus run the native build toolchains -- but at a performance penalty of about `10x`.

Unfortunately, `qemu-user` does not quite execute all ELFs the exact same way as they would be natively (some error messages / exit codes are different (making tests fail), some binaries just don't run at all, ...).
As a consequence, on our machines, some of the required packages did not build, and working around those issues is not just very time consuming, but could very well also affect the outcome of the evaluations.

There are two general alternatives to this: cross-compilation (not fully working here) and setting up an external `aarch64` Nix builder (out of scope here).
The next test will therefore have to run on an actual `aarch64` build host (as specified above).
Start by moving a copy of the artifact (sources) to that host, and [enable (container-)nix](#getting-nix) there (the host will also need to run small bits of `x86_64` binaries, i.e. will require the `binfmt` registration).

Run:
```bash
nix build --no-link --keep-going .'#'checks.aarch64-linux.install-size-rpi
nix run .'#'check:install-size-rpi
```

If the last command competed successfully, it should have (re-)created these files (which can then be copied to the main build host):
```
out/dref-ext/install-rpi-baseline.tex
out/dref-ext/install-rpi-minimal.tex
out/systems/rpi_baseline.csv
out/systems/rpi_minimal.csv
```


#### Reboot Timing Logs

For the breakdown of the reconfiguration (i.e., reboot) times, we repeatedly measured the reboot of an actual Raspberry Pi.
The variance between our test runs was very low, but other hardware (microSD, cooling, eeprom settings) may very well have somewhat different performance.

Since the Model B Pis don't have real-time clocks (and the RTC on the Compute Module is not supported by NixOS out of the box), the Pi can't measure its own reboot time.
We therefore captured its (externally timestamped) serial output and looked at the times of specific trace lines.

We used a 4GB Raspberry Pi 4 Model B, with a sizable passive cooler, a "SanDisk Extreme PRO" 32GB, and a 3.3V UART to USB adapter (connected as described in `hosts/rpi/README.md`).
(I am fairly sure that, though not required for the test, we also had an HDMI monitor attached.)
Since we stripped DHCP from our system, it has to use a fixed IP setup. Replacing the IP numbers in `hosts/rpi/machine.nix` (before the installation) should not affect the test itself.
Also, the `fs.disks.devices.primary.size` declared in that file has to match the size of the boot medium (get it with `blockdev --getsize64 /dev/...`).

Here is the semi-automated boot performance test:
```bash
 # Install the system to a microSD card (or an image first, and then flash manually):
 nix run .'#'checks.aarch64-linux.reconfig-time.passthru.installers.withUpdate.rpi -- install-system /dev/mmcblk0 # (adjust the /dev/* path as needed; can also provide any other path as an image location; with »./utils/container-nix« this requires »--pass-dev«))
 # Then boot the system on a rPI4, and make sure that »$ssh« works to log in and that the PI logs to this host's »/dev/ttyUSB0«:
 mkdir -p out/logs ; LC_ALL=C nix-shell -p openssh -p tio -p moreutils --run bash # open a shell with the required programs, then in that shell:
 ssh='ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i utils/res/ssh_testkey_1 root@192.168.8.85'
 function wait4boot () { for i in $(seq 20) ; do sleep 1 ; if $ssh -- true &>/dev/null ; then return 0 ; fi ; printf . ; done ; return 1 ; }
 wait4boot
 ( set -x ; logPid= ; trap '[[ ! $logPid ]] || kill $logPid' EXIT ; for run in $(seq 20) ; do
     target=mqtt-new ; (( run % 2 )) || target=mqtt-old
     [[ ! $logPid ]] || kill $logPid ; logPid=
     log=out/logs/reboot-$(( run - 1 ))-to-$target.txt ; rm -f $log
     sleep infinity | tio --timestamp --timestamp-format 24hour-start /dev/ttyUSB0 --log --log-strip --log-file $log >/dev/null & logPid=$!
     $ssh -- "echo 'next-boot $target' >/dev/ttyS1 ; set -x ; next-boot $target && reboot" || true
     wait4boot || exit ; echo
 done ) || { echo 'oh noo' ; false ; }
```

Running the above should have created the 20 files (which can then be copied to the main build host):
```
out/logs/reboot-{0..19}-to-$target.txt
```


### Evaluation

You can now re-generate the paper's plots in `./out/` with:
```bash
nix run .'#'eval:fig-oci_combined # (requires out/oci-*.csv)
nix run .'#'eval:fig-reboot # (requires out/logs/*)
nix run .'#'eval:fig-update-size # (requires out/nix_store_send.csv)
```

All data points in the paper (in the text or tables) are read from `out/dref.tex` or `ou/dref-ext/*.tex`. Re-generate the former with:
```bash
nix run .'#'eval:dref
```

The reproduced PDF figures and `data.ref` in `./out` should closely match those provided with the artifact and used in the current revision of the paper.


## Troubleshooting

This project builds quite a lot of stuff, and Nix tends to be a bit over-eager, making it fail when running in a less than ideal build host setup.
Here are some likely problems and workarounds for them:

Depending on where and how Nix is started, and how much it needs to build at once, it may run out of file descriptors.
`ulimit -Sn "$( ulimit -Hn )"` raises the soft limit of open files to the hard limit for the current bash shell and its children.
That should be enough to avoid the problem (unless Nix runs in multi-user mode, in which case the daemons limit needs to be adjusted).

When Nix starts too many large builds at once, it may run out of (temporary) file system space, or test time out.
When that happens, either run Nix with a lower `--max-jobs` value, or repeatedly run it with `--keep-going` until all builds succeed (or change strategy if it keeps failing the same way).
