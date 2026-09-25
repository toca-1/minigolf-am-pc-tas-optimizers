# Global exhaustive optimizer

This directory contains the exhaustive shot optimizer used for my *Minigolf am PC* TAS. Unlike the [local optimizer](https://github.com/toca-1/minigolf-am-pc-tas-optimizers/tree/main/local), this one does an exhaustive search for **one** shot (i.e., it does **not** exhaust all arbitrary sequences of mouse inputs that could theoretically be entered).

For a detailed explanation of the input model and the development of both optimizers, see the corresponding toolassisted.run forum post [here](https://forum.toolassisted.run/t/minigolf-am-pc-pc-minigolf-am-pc/1540/2)

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

## Search model

The Display Input coordinate range used by the mouse interface is X = 0..2560, Y = 0..2048 (basis for relative mouse movement). However, not all positions are valid (border of window, etc.) so the search rectangle is only X = 12..2536, Y = 260..2018 which, thus, contains 4,441,475 raw coordinates. However, because the OS resolution is only 640x480, many raw coordinates generate exactly the same mouse movement so there are only 261,016 unique input plans which the script has to search.

## Why the hybrid DOSBox-X core is needed

Booting directly with `dynamic_x86` did not reliably reproduce the same machine state, so what instead happens is:

1. boot and replay normally
2. create the search state while DOSBox-X is using the normal CPU core
3. load that state for each candidate
4. use an otherwise unused input (Player 2 Joystick Button 2) as an out-of-band request to switch the running CPU core to `dynamic_x86`
5. run the candidate using the faster dynamic core

# Building & Setup

## 0. Set up Ubuntu 26.04

The following is confirmed to work on Ubuntu 26.04 so, unless that is your system already, I recommend to install it or, if you have a Windows 11 machine, install it as a virtual machine through WSL:

1. Open PowerShell as Administrator
2. Run the commands
```
wsl --update
wsl --list --online
wsl --install -d Ubuntu-26.04
```
3. Go through the installation. Name the user account `tas2604` (with a password of your choice)
4. Restart Windows
5. Re-launch PowerShell
6. Enter `wsl -d Ubuntu-26.04` in PowerShell to get into the Ubuntu VM
7. Run
```
sudo apt update
sudo apt full-upgrade -y
```
8. Install all the dependencies this project needs by pasting the following into the terminal:
```
sudo apt install -y \
  build-essential \
  git \
  meson \
  ninja-build \
  cmake \
  curl \
  python3 \
  perl \
  time \
  procps \
  util-linux \
  gawk \
  xz-utils \
  patch \
  pkg-config \
  ca-certificates \
  libegl-dev
```
9. Clone this repository:
```
mkdir -p ~/src
cd ~/src

git clone https://github.com/toca-1/minigolf-am-pc-tas-optimizers.git
```

## 1. Build patched Chimera

```
git clone https://github.com/ToolAssisted-run/chimera.git
cd chimera
git checkout e799a4078f9e757dad15ceb13db59f1d5b2dad26
git submodule update --init --recursive
```

Apply the scanner patch:

```
git apply ~/src/minigolf-am-pc-tas-optimizers/global/patches/chimera-global-scanner.patch
```

Build `chimera-run` and the runtime libraries it needs:

```
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

```
git clone https://github.com/ToolAssisted-run/chimera-common-minibox.git
cd chimera-common-minibox
git checkout 427f6ed7972867638891d7ceb0e81ed9e9ab7db4
```

Apply:

```
git apply ~/src/minigolf-am-pc-tas-optimizers/global/patches/minibox-gcc15-build-fix.patch
```

Configure the C++ guest build:

```
meson setup build/meson-cpp -Dguest_cpp=true
```

Build the guest C++ sysroot:

```
meson compile -C build/meson-cpp libstdcxx
```

The DOSBox-X core link also requires these miniBox guest objects:

```
ninja \
  -C build/meson-cpp \
  source/guest/cxxglue.c.o \
  source/guest/emulibc.c.o
```

## 3. Build the hybrid DOSBox-X core

```
git clone https://github.com/ToolAssisted-run/chimera-core-dosbox-x.git
cd chimera-core-dosbox-x
git checkout 42c7f7fd0df71f7727f5139be06a3fe948660578
git submodule update --init --recursive
```

Apply the hybrid patch:

```
git apply ~/src/minigolf-am-pc-tas-optimizers/global/patches/dosbox-x-hybrid-core.patch
```

Configure the Waterbox guest build:

```
./waterbox/setup-guest.sh \
  -m ~/src/chimera/chimera-common-minibox
```

Build:

```
meson compile \
  -C build/meson-guest \
  core.wbx
```

Package the core:

```
./waterbox/build-package.sh \
  -m ~/src/chimera/chimera-common-minibox \
  -r ~/src/chimera
```

and move it to where the optimizer expects it

```
mkdir -p ~/minigolf-headless/core

cp ~/src/chimera/build/Cores/dosbox-x.chimeraCore \
   ~/minigolf-headless/core/dosbox-x-hybrid-search.chimeraCore
```

## 4. Copy install.hdd

If your install.hdd is located at, say, `C:\PATH\SUBPATH\install.hdd`, then the command to get it into your Ubuntu VM is
```
cp "/mnt/c/PATH/SUBPATH/install.hdd" ~/install.hdd
```
(note how the \ become /). If the .hdd file is not on C: but another drive (X:), change the command to
```
cp "/mnt/x/PATH/install.hdd" ~/install.hdd
```

Then check it with `sha1sum ~/install.hdd`; the correct SHA1 is b63a81c7ef613fb42e725e625ebe0eae18e91119

## 5. Make the launcher executable

```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts

chmod +x run_global_search.sh
```

# Running an exhaustive search

Start the search is done with the following syntax: 
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
./run_global_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit
```
e.g., 
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
./run_global_search.sh 10 1997 1000 486 75
```
to brute-force hole 10 if it starts on frame 1997 with initial mouse coordinates X=1000, Y=486 and an upper limit of 75 frames per candidate. One other thing to note about the search is that workers share a memory-mapped incumbent file, so when one worker finds a faster result, the other workers can immediately adopt the lower frame cutoff.

To monitor the progress of the search, open another PowerShell window and go into the VM (`wsl -d Ubuntu-26.04`). The monitor is started with the following syntax:
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 monitor_global_search.py currentHoleNumber frames_upperlimit
```
e.g.,
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 monitor_global_search.py 10 75
```

<img width="783" height="301" alt="image" src="https://github.com/user-attachments/assets/7f090e4a-eccf-42f0-813e-26c0c5898caa" />

# Running a restricted exhaustive search

The script includes a possibility of searching a smaller window via
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
MINIGOLF_SCAN_X_MIN=X1 MINIGOLF_SCAN_X_MAX=X2 MINIGOLF_SCAN_Y_MIN=Y1 MINIGOLF_SCAN_Y_MAX=Y2 ./run_global_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit
```
