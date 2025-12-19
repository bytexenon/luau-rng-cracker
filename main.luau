--[[
	Reconstruct the initial state of Luau's global PCG32 generator.

	In luau/VM/src/lmathlib.cpp, luaopen_math seeds global_State::rngstate as:

			uint64_t seed = uintptr_t(L);
			seed ^= time(NULL);
			seed ^= clock();
			pcg32_seed(&L->global->rngstate, seed);

	From Luau, the only term that is not directly observable is the sampled
	process clock value. The remaining inputs can be reconstructed and the clock
	term can then be searched over a bounded window.
--]]

local TARGET_UPPER_BOUND = 2 ^ 28
local CLOCK_SEARCH_START = -50000
local CLOCK_SEARCH_END = 50000

local observedOutput = math.random(TARGET_UPPER_BOUND)
local currentTime = os.time()

local ASLR_ANCHOR = tostring(assert)

-- Empirical delta between luaB_assert and lua_State for the target build.
local ANCHOR_TO_L_OFFSET = 0x11900

local state_hi, state_lo = 0, 0

-- 64-bit arithmetic is carried as two 32-bit halves to stay within Luau's number model.
local function u32(x)
	return bit32.band(x, 0xFFFFFFFF)
end

local function add64(ahi, alo, bhi, blo)
	local lo = u32(alo + blo)
	local carry = (alo + blo) >= 2 ^ 32 and 1 or 0
	local hi = u32(ahi + bhi + carry)
	return hi, lo
end

local function bxor64(ahi, alo, bhi, blo)
	return bit32.bxor(ahi, bhi), bit32.bxor(alo, blo)
end

-- Mirror pcg32_random() from lmathlib.cpp without materializing a native uint64_t.
local function pcg32_next_u32()
	-- uint64_t oldstate = *state;
	-- *state = oldstate * 6364136223846793005ULL + (PCG32_INC | 1);
	-- uint32_t xorshifted = uint32_t(((oldstate >> 18u) ^ oldstate) >> 27u);
	-- uint32_t rot = uint32_t(oldstate >> 59u);
	-- return (xorshifted >> rot) | (xorshifted << ((-int32_t(rot)) & 31));

	local old_hi, old_lo = state_hi, state_lo

	-- state = old * 0x5851F42D4C957F2D + 105  (mod 2^64), base-2^16 limbs
	local o0 = bit32.band(old_lo, 0xFFFF)
	local o1 = old_lo // 2 ^ 16
	local o2 = bit32.band(old_hi, 0xFFFF)

	local s0 = o0 * 32557 + 105 -- 105 = PCG32_INC | 1
	local s1 = o0 * 19605 + o1 * 32557 + s0 // 2 ^ 16
	local s2 = o0 * 62509 + o1 * 19605 + o2 * 32557 + s1 // 2 ^ 16

	state_hi, state_lo =
		bit32.band(s2, 0xFFFF) + bit32.band(
			o0 * 22609 + o1 * 62509 + o2 * 19605 + old_hi // 2 ^ 16 * 32557 + s2 // 2 ^ 16,
			0xFFFF
		) * 2 ^ 16,
		bit32.band(s0, 0xFFFF) + bit32.band(s1, 0xFFFF) * 2 ^ 16

	-- output transform from old state (XSH-RR)
	-- uint32_t xorshifted = uint32_t(((oldstate >> 18u) ^ oldstate) >> 27u);
	-- uint32_t rot = uint32_t(oldstate >> 59u);
	-- return (xorshifted >> rot) | (xorshifted << ((-int32_t(rot)) & 31));
	return bit32.rrotate(
		bit32.bor(
			bit32.bxor(bit32.bor(old_lo / 2 ^ 18, old_hi * 2 ^ 14), old_lo) / 2 ^ 27,
			bit32.bxor(old_hi / 2 ^ 18, old_hi) * 32
		),
		bit32.band((old_hi / 2 ^ 27), 31)
	)
end

-- Replay the single-argument math.random(n) path from Luau's math library.
local function random_one_arg(upperLim)
	-- Inline: x_hi = hi32(uint32(upperLim) * rand)
	local rand = pcg32_next_u32()
	local a = bit32.band(upperLim, 0xFFFFFFFF)
	if a == 0 then
		return 1
	end

	local a0 = bit32.band(a, 0xFFFF)
	local b0 = bit32.band(rand, 0xFFFF)
	local a1 = a // 2 ^ 16
	local b1 = rand // 2 ^ 16
	local mid = a0 * b1 + a1 * b0

	return 1 + (a1 * b1 + mid // 2 ^ 16) + a0 * b0 + bit32.band(mid, 0xFFFF) * 2 ^ 16 // 2 ^ 32 % 2 ^ 32
end

-- Mirror pcg32_seed(): advance once from zero, add the seed, then advance again.
local function seed_pcg32(hi, lo)
	state_hi, state_lo = add64(0, 105, hi, lo)
	pcg32_next_u32()
end

-- Parse the hexadecimal pointer rendered by tostring(assert).
local function parse_pointer_u64(str)
	local hex = str:match("0x(%x+)$")
	assert(hex, "anchor string did not contain a hexadecimal pointer")

	if #hex > 8 then
		local hi_hex = hex:sub(1, #hex - 8)
		local lo_hex = hex:sub(#hex - 7)
		return u32(tonumber(hi_hex, 16) or 0), u32(tonumber(lo_hex, 16) or 0)
	end

	return 0, u32(tonumber(hex, 16) or 0)
end

print("----------------------------")

-- Recover lua_State from the exported anchor and the build-specific offset.
state_hi, state_lo = parse_pointer_u64(ASLR_ANCHOR)
state_hi, state_lo = add64(state_hi, state_lo, 0, -ANCHOR_TO_L_OFFSET)
print(string.format("aslr: 0x%08X%08X", state_hi, state_lo))

-- Fold in the wall-clock contribution. The process clock sample remains unknown.
local time_hi = currentTime // 2 ^ 32
local time_lo = currentTime % 2 ^ 32
state_hi, state_lo = bxor64(state_hi, state_lo, time_hi, time_lo)
print(string.format("time: 0x%08X%08X", time_hi, time_lo))

local saved_state_hi, saved_state_lo = state_hi, state_lo
print(string.format("seed: 0x%08X%08X", state_hi, state_lo))

print("----------------------------")

local found = false

-- Enumerate plausible clock() samples until the first observed draw matches.
for clockSample = CLOCK_SEARCH_START, CLOCK_SEARCH_END do
	seed_pcg32(bxor64(saved_state_hi, saved_state_lo, 0, u32(clockSample)))

	if random_one_arg(TARGET_UPPER_BOUND) == observedOutput then
		print(`Found matching seed with clock sample: {clockSample}`)
		found = true
		break
	end
end

if not found then
	error("could not reconstruct the seed within the configured search window")
end

for i = 1, 5 do
	print("----------------------------")
	print(`Predicted: {random_one_arg(TARGET_UPPER_BOUND)}`)
	print(`Actual:    {math.random(TARGET_UPPER_BOUND)}`)
end
