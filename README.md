# Minigolf am PC TAS optimizers

Local and exhaustive shot optimizers for TASing the 1997 Windows game *Minigolf am PC* with TAStudio and DOSBox-X. This repository contains:

- [`local/`](local/): an iterative local optimizer implemented as a TAStudio Lua script. It searches around an existing shot and is convenient for quickly improving a known solution
- [`global/`](global/): a headless exhaustive optimizer which searches all distinct mouse input plans within a configured target area in order to find the fastest one-shot solution (if such a thing exists, of course)

Each directory has its own README with usage, setup, and implementation-specific information. For a detailed explanation of how the optimizers work, cf. the accompanying [toolAssisted.run forum post](https://forum.toolassisted.run/t/minigolf-am-pc-pc-minigolf-am-pc/1540/2).

## AI assistance

Parts of this project were developed with substantial assistance from ChatGPT. Some of the code was not reviewed by me line by line. I did, however, build the project from scratch and test the complete workflow, verifying that everything works as intended in the setup described here.
