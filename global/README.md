# Global exhaustive optimizer

This directory contains the exhaustive shot optimizer used for my *Minigolf am PC* TAS. Unlike the [local optimizer](https://github.com/toca-1/minigolf-am-pc-tas-optimizers/tree/main/local), this one does an exhaustive search for **one** shot (i.e., it does **not** exhaust all arbitrary sequences of mouse inputs that could theoretically be entered).

In addition to searching for the fastest hole-in-one, the optimizer can also record and rank the landing state reached by every first shot. This is useful for courses where no hole-in-one exists, so promising first shots can then be continued with the local optimizer.

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
    ├── monitor_global_search.py
    ├── run_global_landing_search.sh
    ├── monitor_global_landing_search.py
    ├── rank_global_results.py
    └── plot_global_landings.py
```

### `patches/`

- `chimera-global-scanner.patch` adds the headless exhaustive Minigolf scanner to `chimera-run`, including both the hole-in-one and landing-state search modes
- `dosbox-x-hybrid-core.patch` adds a search-only mechanism that switches DOSBox-X from the normal CPU core to `dynamic_x86` at runtime. The machine is booted and the search savestate is created using the normal core; the switch happens after loading the state
- `minibox-gcc15-build-fix.patch` is a build compatibility fix needed for the miniBox C++ guest toolchain in my Ubuntu 26.04, GCC 15 environment, and *not* part of the search algorithm itself

### `project/`

`minigolf.chimeraProject` is an unoptimized full playthrough that contains the input history used to recreate the search states. Beware that underlying HDD file is intentionally **not included**; instructions on how to build it can be found [here](https://toolassisted.run/runs/M100095/) (under "Reproduction Steps").

### `scripts/`

The scripts wrap state generation, worker launching, monitoring, result collection, landing-state reranking, and visualization of landing positions, cf. below

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
  python3-pil \
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

Then check it with `sha1sum ~/install.hdd`; the correct SHA1 is f1bb3175f01f2cb4ad52c3dba261da1c3d9415c9

## 5. Make the launchers executable

```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts

chmod +x \
  run_global_search.sh \
  run_global_landing_search.sh
```

# Running an exhaustive hole-in-one search

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

# Running a restricted exhaustive search

The script includes a possibility of searching a smaller window via
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
MINIGOLF_SCAN_X_MIN=X1 MINIGOLF_SCAN_X_MAX=X2 MINIGOLF_SCAN_Y_MIN=Y1 MINIGOLF_SCAN_Y_MAX=Y2 ./run_global_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit
```

# Running an exhaustive landing-state search

The scanner can also be used to exhaustively test every first-shot input plan, record where the ball ends up, and rank the resulting positions by their distance from a chosen target point (e.g., for courses where no hole-in-one exists). The syntax is:
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
./run_global_landing_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit targetX targetY
```

`currentHoleNumber`, `startingFrame`, `initialX`, and `initialY` have the same meaning as for the hole-in-one search. `targetX` and `targetY` are coordinates in the same coordinate system as the ball-position values read from Physical RAM (may be the hole itself or an intermediate point chosen because of the course geometry). These values are used only to rank the recorded landing states and do not affect which input plans are searched. `frames_upperlimit` is the maximum number of frames simulated for each candidate. A candidate whose shot-ending signal has not occurred within that limit is recorded as a timeout and is not included in the ranked landing states.

To monitor the landing-state search, use:
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 monitor_global_landing_search.py currentHoleNumber frames_upperlimit targetX targetY
```
e.g.,
if the search command was
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
./run_global_landing_search.sh 17 3366 624 900 250 530 200
```
then the monitor command is
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 monitor_global_landing_search.py 17 250 530 200
```

The `ended` value shown by the monitor is the frame offset at which the game's shot-state flag returns from 0 to 1 and the final ball position is recorded. A subsequent shot can in practice be entered a few frames before this signal, so `ended` is useful for comparing first shots but is not necessarily the earliest possible frame on which the next shot can be entered.

## Visualizing landing positions on a course screenshot

`plot_global_landings.py` overlays the final ball positions from an exhaustive landing-state search onto a screenshot of the course (taken by default with F12 while in the emulator). Each distinct landing position is marked with a colored circle. The syntax is:
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 plot_global_landings.py currentHoleNumber /PATH/TP/course-screenshot.png
```
e.g., for hole 7, with the screenshot saved in the search output directory as `course7.png`:
```
python3 plot_global_landings.py 7 ~/minigolf-hole7-exhaustive/course7.png
```
By default, the script reads all `worker-*.log` files in `~/minigolf-hole7*-exhaustive/` and saves the annotated image alongside the screenshot as `ORIGINAL-FILENAME_landings.png`. The first run also extracts the landing coordinates and their occurrence counts into `landing-positions.tsv`, with `landing-positions.meta.json` alongside it, in the search output directory. Later runs reuse this cache instead of rereading the worker logs, unless the logs have changed. To use the cached data even if the logs have changed, add `--cache-only`; to force a fresh extraction, add `--refresh-cache`. The default mapping from RAM coordinates to an uncropped 640×480 game screenshot (including the title/menu area) is image X = RAM X + 6, image Y = RAM Y + 45. For differently cropped or scaled images, override the mapping with `--offset-x`, `--offset-y`, `--scale-x`, and `--scale-y`.
The default marker is a solid blue circle with a radius of 2 pixels. To draw single pixels instead, use:
```
python3 plot_global_landings.py 7 ~/minigolf-hole7-exhaustive/course7.png --radius 0
```
Other optional arguments include `--color '#xxxxxx'` (marker color), `--opacity 180` (transparency), `--output /PATH/TO/output.png` (output filename), and `--logs /PATH/TO/search-directory` (non-default log location).

Example images (original / output):

<img width="640" height="480" alt="install 2026-10-09 11 26 48" src="https://github.com/user-attachments/assets/ff884e06-b65e-4c41-8801-07002b3735b0" />

<img width="640" height="480" alt="install 2026-10-09 11 26 48_landings" src="https://github.com/user-attachments/assets/b9d35fc0-32f7-4250-81ed-ae5ed728eb52" />


## Reranking a completed landing-state search

Every completed landing position remains stored as a log. A finished search can therefore be ranked against a different target point without running the emulator search again:
```
cd ~/src/minigolf-am-pc-tas-optimizers/global/scripts
python3 rank_global_results.py currentHoleNumber targetX targetY --top 10
```
e.g.,
```
python3 rank_global_results.py 17 530 200 --top 10
```

The ranker can also show the distance/time Pareto frontier (useful for finding candidates which land somewhat farther from the target but finish their first shot earlier):
```
python3 rank_global_results.py 17 530 200 --pareto --top 30
```
