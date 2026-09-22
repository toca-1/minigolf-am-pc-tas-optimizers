# Global exhaustive optimizer

This directory contains the exhaustive shot optimizer used for my *Minigolf am PC* TAS. Unlike the [local optimizer](https://github.com/toca-1/minigolf-am-pc-tas-optimizers/tree/main/local), this one does an exhaustive search for **one** shot (i.e., it does **not** exhaust all arbitrary sequences of mouse inputs that could theoretically be entered).

## Directory layout

```text
global/
├── patches/
│   ├── chimera-global-scanner.patch
│   ├── dosbox-x-hybrid-core.patch
│   └── minibox-gcc15-build-fix.patch
├── project/
│   └── minigolf.chimeraProject
└── scripts/
    ├── run_global_search.sh
    └── monitor_global_search.py
```

### `patches/`

- `chimera-global-scanner.patch` adds the headless exhaustive Minigolf scanner to `chimera-run`
- `dosbox-x-hybrid-core.patch` adds a search-only mechanism that switches DOSBox-X from the normal CPU core to `dynamic_x86` at runtime. The machine is booted and the search savestate is created using the normal core; the switch happens after loading the state
- `minibox-gcc15-build-fix.patch` is a build compatibility fix needed for the miniBox C++ guest toolchain in my Ubuntu 26.04, GCC 15 environment, and *not* part of the search algorithm itself

### `project/`

`minigolf.chimeraProject` is an unoptimized full playthrough that contains the input history used to recreate the search states. Beware that underlying HDD file is intentionally **not included**.

# TODO: link the published TAS submission here for exact HDD construction instructions.

### `scripts/`

The scripts wrap state generation, worker launching, monitoring, and result collection, cf. below

## Tested source revisions

| Component | Version/Revision |
| --- | --- |
| Chimera | [Nightly 2026-09-17 (82072264)](https://github.com/ToolAssisted-run/chimera/releases#release-nightly-2026-09-17) |
| chimera-common-minibox | [2026-09-22, forked for preservation at 7:50 pm](https://github.com/toca-1/chimera-common-minibox-2026-09-22) |
| chimera-core-dosbox-x | [Nightly 2026-09-18](https://github.com/ToolAssisted-run/chimera-core-dosbox-x/releases#release-nightly-2026-09-18) |
| DOSBox-X | [dosbox-x-v2026.08.02](https://github.com/joncampbell123/dosbox-x/releases/tag/dosbox-x-v2026.08.02) |

The DOSBox-X settings used by the TAS are:

```text
preset = 1997_ibm_aptiva_2140
boot drive = C:
memsize = -1
cycles = -1
mouse enabled = true
Mouse Relative Sensitivity = 1
joystick 1 = disabled
joystick 2 = disabled
```

## Search model

The Display Input coordinate range used by the mouse interface is X = 0..2560, Y = 0..2048 (basis for relative mouse movement). However, not all positions are valid (border of window, etc.) so the search rectangle is only X = 12..2536, Y = 260..2018 which, thus, contains 4,441,475 raw coordinates. However, because the OS resolution is only 640x480, many raw coordinates generate exactly the same mouse movement so there are only 261,016 unique input plans which the script has to search.

## Why the hybrid DOSBox-X core is needed

Booting directly with `dynamic_x86` did not reliably reproduce the same machine state, so what instead happens is:

1. boot and replay normally
2. create the search state while DOSBox-X is using the normal CPU core
3. load that state for each candidate
4. use an otherwise unused input (Player 2 Joystick Button 2) as an out-of-band request to switch the running CPU core to `dynamic_x86`
5. run the candidate using the faster dynamic core

# Building

## 0. Set up Ubuntu 26.04

The following is confirmed to work on Ubuntu 26.04 so, unless that is your system already, I recommend to install it or, if you have a Windows 11 machine, install it as a virtual machine through WSL:

1. Open PowerShell as Administrator
2. Run the commands
```
wsl --update
wsl ---list --online
wsl --install -d Ubuntu-26.04
```
3. Afterwards, restart your PC

# TO DO

## 1. Build patched Chimera

```bash
git clone https://github.com/ToolAssisted-run/chimera.git
cd chimera
git checkout e799a4078f9e757dad15ceb13db59f1d5b2dad26
git submodule update --init --recursive
```

Apply the scanner patch:

```bash
git apply /path/to/global/patches/chimera-global-scanner.patch
```

Build `chimera-run` and the runtime libraries it needs:

```bash
meson setup build/meson-linux \
  --prefix "$(pwd)/build" \
  --libdir dll

meson compile \
  -C build/meson-linux \
  chimera-run \
  miniboxhost \
  zstd
```

## 2. Build the miniBox C++ guest toolchain

```bash
git clone https://github.com/ToolAssisted-run/chimera-common-minibox.git
cd chimera-common-minibox
git checkout 427f6ed7972867638891d7ceb0e81ed9e9ab7db4
```

Apply:

```bash
git apply /path/to/global/patches/minibox-gcc15-build-fix.patch
```

Configure the C++ guest build:

```bash
meson setup build/meson-cpp -Dguest_cpp=true
```

Build the guest C++ sysroot:

```bash
meson compile -C build/meson-cpp libstdcxx
```

The DOSBox-X core link also requires these miniBox guest objects:

```bash
ninja \
  -C build/meson-cpp \
  source/guest/cxxglue.c.o \
  source/guest/emulibc.c.o
```

## 3. Build the hybrid DOSBox-X core

```bash
git clone https://github.com/ToolAssisted-run/chimera-core-dosbox-x.git
cd chimera-core-dosbox-x
git checkout 42c7f7fd0df71f7727f5139be06a3fe948660578
git submodule update --init --recursive
```

The nested DOSBox-X checkout should be:

```text
784240ad6d9cf3ae3f02fab819e2ed5cf5117dd4
tag: dosbox-x-v2026.08.02
```

Apply the hybrid patch:

```bash
git apply /path/to/global/patches/dosbox-x-hybrid-core.patch
```

Configure the Waterbox guest build:

```bash
./waterbox/setup-guest.sh \
  -m /path/to/chimera-common-minibox
```

Build:

```bash
meson compile \
  -C build/meson-guest \
  core.wbx
```

Package the core:

```bash
./waterbox/build-package.sh \
  -m /path/to/chimera-common-minibox \
  -r /path/to/chimera
```

# Running an exhaustive search

A search needs:

- the patched `chimera-run`
- the rebuilt hybrid DOSBox-X package
- `minigolf.chimeraProject`
- the matching Minigolf HDD
- a compatible state immediately before the shot
- the current cursor coordinates
- the starting mouse-axis carrier values
- the current and next course-byte values
- a maximum frame cutoff

Beware that Search states must be created using the **same** `core.wbx` build that will later load them (else you'll run into a "ELF hash mismatch"). See `scripts/run_global_search.sh` for the full worker launcher, and `monitor_global_search.py` for a monitor of the search once it is running. They should be executed in the terminal via
```
./run_global_search.sh currentHoleNumber initialX initialY frames_upperlimit
python3 monitor_global_search.py currentHoleNumber initialX initialY frames_upperlimit
```
e.g., 
```
./run_global_search.sh 10 1000 486 75
python3 monitor_global_search.py 10 1000 486 75
```
to brute-force hole 10 if it starts on frame 1000 with initial mouse coordinates X=486, Y=75. One other thing to note about the search is that workers share a memory-mapped incumbent file, so when one worker finds a faster result, the other workers can immediately adopt the lower frame cutoff.

## Monitoring

`monitor_global_search.py` reads worker logs incrementally and reports information such as number of candidates evaluated, current best score, and others

<img width="789" height="327" alt="image" src="https://github.com/user-attachments/assets/504cf44f-82b2-4e05-a2c3-fb93c55e0ba1" />
