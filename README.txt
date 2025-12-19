Luau RNG cracker
================

Reconstruct the initial Luau math.random stream in standalone Luau builds,
effectively cracking the RNG state.

OVERVIEW
--------
This repository contains a Luau proof of concept that reproduces the
seeding path used by Luau's math library and replays the resulting PCG32
stream. The script recovers the observable seed inputs, searches the
remaining process clock term, and then predicts subsequent outputs from
math.random.

IMPLEMENTATION MODEL
--------------------
In luau/VM/src/lmathlib.cpp, the RNG state is initialized from three
inputs:

  1. the address of lua_State
  2. time(NULL)
  3. clock()

The script derives an approximate lua_State address from tostring(assert),
folds in the current wall-clock time, and brute-forces the remaining
clock() sample until the first observed draw is reproduced.

SCOPE
-----
The implementation targets standalone Luau builds whose object layout still
allows the lua_State address to be inferred from the selected anchor.
Builds that encode or obscure this pointer relationship invalidate the
current method.

This POC wouldn't work in the Roblox environment, as it encodes all pointers
with a random key, preventing the lua_State address from being derived from
a known anchor.

REQUIREMENTS
------------
The target build must expose a stable offset between the exported anchor
function and lua_State.

The configured search window must cover the clock() value observed during
RNG initialization.

The validation sample must be taken from the single-argument math.random(n)
path implemented by Luau.

OUTPUT
------
After a matching seed is found, the script prints the recovered clock()
sample and compares predicted values against live math.random results.

LIMITATIONS
-----------
This is a version-sensitive POC tool, not a general solution. Changes
to pointer formatting, state layout, seeding inputs, or RNG implementation
will invalidate the reconstruction logic.
