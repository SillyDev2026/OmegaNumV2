--!native
--!optimize 2

-- OmegaNum V2.4
-- Core rewrite focused on:
--   * compatibility normalization stays off arithmetic hot paths
--   * raw internal arithmetic/comparison
--   * faster constructors
--   * fixed integer/parity/root/pow behavior
--   * repaired arrow dispatch
--   * non-mutating serialization/formatting
--
-- Representation remains compatible with classic OmegaNum:
--     { sign, { data... } }
--
-- Treat OmegaNum values returned by this module as immutable.

local HttpService = game:GetService("HttpService")

local OmegaNum = {}

OmegaNum.VERSION = "2.4.0"
OmegaNum.API_VERSION = 2
OmegaNum.PERF_VERSION = 7
OmegaNum.LB_VERSION = 1
OmegaNum.SAFE_LB_VERSION = 2

local NAN = 0 / 0
local INF = math.huge

local MAX_SAFE = 2 ^ 53 - 1
local LOG_MAX_SAFE = math.log10(MAX_SAFE)
local MAX_NATIVE = 1.7976931348623157e308
local MIN_NATIVE_LOG10 = -323
local SIGNIFICANT_DIFF = 20
local PRECISION_DISPLAY = 3
local MAX_ES = 10
local ARROW_LIMIT = 254

local E = 2.7182818284590452353602874
local INV_E_EXP = math.exp(1 / E)

local CANONICAL = setmetatable({}, { __mode = "k" })

local function newRaw(sign, data)
	local out = { sign, data }
	CANONICAL[out] = true
	return out
end

local ZERO = newRaw(1, { 0 })
local ONE = newRaw(1, { 1 })
local NEG_ONE = newRaw(-1, { 1 })
local TWO = newRaw(1, { 2 })
local THREE = newRaw(1, { 3 })
local TEN = newRaw(1, { 10 })
local HALF = newRaw(1, { 0.5 })
local E_OMEGA = newRaw(1, { E })
local LOG10_E_OMEGA = newRaw(1, { math.log10(E) })
local STIRLING_CORRECTION = newRaw(1, { 0.9189385332046727 })
local NAN_OMEGA = newRaw(1, { NAN })
local POS_INF = newRaw(1, { INF })
local NEG_INF = newRaw(-1, { INF })

OmegaNum.ZERO = ZERO
OmegaNum.ONE = ONE
OmegaNum.NAN = NAN_OMEGA
OmegaNum.INF = POS_INF

local LOG_MAX_NATIVE = math.log10(MAX_NATIVE)

-- PERF v7 bounded immutable interning.
-- OmegaNum values are documented as immutable. A single MRU entry removes the
-- dominant allocation from repeated values/results while keeping unique-value
-- overhead and retained memory extremely small.
local NUMBER_CACHE_N = NAN
local NUMBER_CACHE_V = nil

local LAYER_CACHE_SIGN = 0
local LAYER_CACHE_PAYLOAD = NAN
local LAYER_CACHE_V = nil

local STRING_CACHE_S = nil
local STRING_CACHE_V = nil

local function newLayer1Raw(sign, payload)
	if sign == LAYER_CACHE_SIGN and payload == LAYER_CACHE_PAYLOAD then
		return LAYER_CACHE_V
	end

	local out = newRaw(sign, { payload, 1 })
	LAYER_CACHE_SIGN = sign
	LAYER_CACHE_PAYLOAD = payload
	LAYER_CACHE_V = out
	return out
end

local function isNaNNumber(n)
	return n ~= n
end

local function copyArray(t)
	local n = #t
	local out = table.create(n)
	for i = 1, n do
		out[i] = t[i]
	end
	return out
end

-- Raw functions only receive values created/canonicalized by this module.
-- Special values are therefore unique constants and can be checked by identity.
local function isNaNRaw(x)
	return x == NAN_OMEGA
end

local function isInfRaw(x)
	return x == POS_INF or x == NEG_INF
end

local function isZeroRaw(x)
	return x == ZERO
end

local function isOneRaw(x)
	return x == ONE
end

local function trimTrailingZeros(data)
	local i = #data
	while i > 1 and data[i] == 0 do
		data[i] = nil
		i -= 1
	end
end

-- Trusted native constructor. All internal call sites already hold a number,
-- so this deliberately avoids type() on the hottest allocation path.
local function fromNumberRaw(n)
	if n ~= n then
		return NAN_OMEGA
	end

	-- Constants stay ahead of the cache so their path remains as small as possible.
	if n == 0 then
		return ZERO
	elseif n == 1 then
		return ONE
	elseif n == -1 then
		return NEG_ONE
	elseif n == 2 then
		return TWO
	elseif n == 3 then
		return THREE
	elseif n == 0.5 then
		return HALF
	elseif n == 10 then
		return TEN
	elseif n == INF then
		return POS_INF
	elseif n == -INF then
		return NEG_INF
	end

	if n == NUMBER_CACHE_N then
		return NUMBER_CACHE_V
	end

	local sign = n < 0 and -1 or 1
	local a = n < 0 and -n or n
	local out

	if a <= MAX_SAFE then
		out = newRaw(sign, { a })
	else
		out = newLayer1Raw(sign, math.log10(a))
	end

	NUMBER_CACHE_N = n
	NUMBER_CACHE_V = out

	return out
end

-- Fast constructor for a magnitude already expressed as log10(value).
local function fromLog10Raw(sign, logMagnitude)
	if logMagnitude ~= logMagnitude then
		return NAN_OMEGA
	end

	if sign == 0 then
		return ZERO
	end

	sign = sign < 0 and -1 or 1

	if logMagnitude == INF then
		return sign < 0 and NEG_INF or POS_INF
	elseif logMagnitude == -INF or logMagnitude < MIN_NATIVE_LOG10 then
		return ZERO
	end

	if logMagnitude < LOG_MAX_SAFE then
		return fromNumberRaw(sign * (10 ^ logMagnitude))
	end

	return newLayer1Raw(sign, logMagnitude)
end

-- Compatibility canonicalizer. V2.3 keeps this deliberately off the arithmetic
-- hot path: it is for user/legacy/raw inputs, not already-canonical results.
local function canonicalize(sign, data, owned)
	if type(sign) ~= "number" or sign ~= sign then
		return NAN_OMEGA
	end

	if sign == 0 then
		return ZERO
	end

	if type(data) ~= "table" then
		return ZERO
	end

	local len = #data
	if len == 0 then
		return ZERO
	end

	local first = tonumber(data[1])
	if first == nil or first ~= first then
		return NAN_OMEGA
	end

	sign = sign < 0 and -1 or 1

	if first == INF then
		return sign < 0 and NEG_INF or POS_INF
	end

	-- Scalar input is overwhelmingly common and requires no defensive array copy.
	if len == 1 then
		if first < 0 then
			sign = -sign
			first = -first
		end

		if first == INF then
			return sign < 0 and NEG_INF or POS_INF
		end

		return fromNumberRaw(sign * first)
	end

	-- Layer-1 / repeated-e input is the second dominant compatibility shape.
	-- Normalize it using locals and allocate only the final representation.
	if len == 2 then
		local layer = tonumber(data[2])
		if layer == nil or layer ~= layer then
			return NAN_OMEGA
		end

		if first == INF then
			return sign < 0 and NEG_INF or POS_INF
		end

		if layer < 0 then
			layer = 0
		end
		layer = math.floor(layer)

		-- Extremely large rank counters need the generic carry path below.
		if layer <= MAX_SAFE then
			if layer == 0 then
				if first == 0 then
					return ZERO
				end

				-- Preserve legacy odd raw shapes rather than changing compatibility.
				if first < 0 then
					return newRaw(sign, { first })
				end

				return fromNumberRaw(sign * first)
			end

			if first > MAX_SAFE then
				first = math.log10(first)
				layer += 1
			end

			if layer == 1 and first < MIN_NATIVE_LOG10 then
				return ZERO
			end

			while layer > 0
				and first >= MIN_NATIVE_LOG10
				and first < LOG_MAX_SAFE
			do
				first = 10 ^ first
				layer -= 1
			end

			if layer == 0 then
				return fromNumberRaw(sign * first)
			end

			return layer == 1 and newLayer1Raw(sign, first) or newRaw(sign, { first, layer })
		end
	end

	if not owned then
		data = copyArray(data)
	end

	data[1] = first

	for i = 2, #data do
		local v = tonumber(data[i])
		if v == nil or v ~= v then
			return NAN_OMEGA
		end

		if v < 0 then
			v = 0
		end

		data[i] = math.floor(v)
	end

	trimTrailingZeros(data)

	if #data <= 2 then
		return canonicalize(sign, data, true)
	end

	local i = 2
	while i <= #data do
		if data[i] > MAX_SAFE then
			data[i] = 0
			data[i + 1] = (data[i + 1] or 0) + 1
		end
		i += 1
	end

	if data[1] > MAX_SAFE then
		data[1] = math.log10(data[1])
		data[2] = (data[2] or 0) + 1
	end

	trimTrailingZeros(data)

	if #data <= 2 then
		return canonicalize(sign, data, true)
	end

	return newRaw(sign, data)
end

local function parseScientificString(str)
	-- Avoid Lua patterns on the common scientific path.
	local lowerE = string.find(str, "e", 1, true)
	local upperE = string.find(str, "E", 1, true)
	local ePos

	if lowerE ~= nil and upperE ~= nil then
		ePos = math.min(lowerE, upperE)
	else
		ePos = lowerE or upperE
	end

	if ePos == nil or ePos <= 1 or ePos >= #str then
		return nil
	end

	-- Multiple e/E characters belong to the repeated-E parser instead.
	if string.find(str, "e", ePos + 1, true) ~= nil
		or string.find(str, "E", ePos + 1, true) ~= nil
	then
		return nil
	end

	local mantissa = tonumber(string.sub(str, 1, ePos - 1))
	local exponent = tonumber(string.sub(str, ePos + 1))

	if mantissa == nil or exponent == nil then
		return NAN_OMEGA
	end

	if mantissa == 0 then
		return ZERO
	end

	local sign = mantissa < 0 and -1 or 1
	local magnitude = mantissa < 0 and -mantissa or mantissa
	return fromLog10Raw(sign, exponent + math.log10(magnitude))
end

local function parseEChain(str)
	local signText, es, payloadText =
		string.match(str, "^([%-]?)([eE][eE]+)([%+%-]?[%d]*%.?[%d]+)$")

	if not es then
		return nil
	end

	local payload = tonumber(payloadText)
	if payload == nil then
		return NAN_OMEGA
	end

	local sign = signText == "-" and -1 or 1
	return canonicalize(sign, { payload, #es }, true)
end

local function fromStringUncached(str)
	if str == "" then
		return NAN_OMEGA
	end

	-- Fastest path first. tonumber handles ordinary integers/decimals/scientific
	-- strings without running any Lua patterns.
	local native = tonumber(str)
	if native ~= nil and native ~= INF and native ~= -INF then
		return fromNumberRaw(native)
	end

	-- Only clean whitespace when the native path did not finish the parse.
	local firstByte = string.byte(str, 1)
	local lastByte = string.byte(str, #str)
	if firstByte == 32 or firstByte == 9 or firstByte == 10 or firstByte == 13
		or lastByte == 32 or lastByte == 9 or lastByte == 10 or lastByte == 13
	then
		str = string.match(str, "^%s*(.-)%s*$") or str
		if str == "" then
			return NAN_OMEGA
		end
	end

	local sci = parseScientificString(str)
	if sci then
		return sci
	end

	local chain = parseEChain(str)
	if chain then
		return chain
	end

	if string.sub(str, 1, 1) == "[" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, str)
		if not ok or type(decoded) ~= "table" or #decoded == 0 then
			return NAN_OMEGA
		end

		local first = tonumber(decoded[1]) or 0
		local sign = first < 0 and -1 or 1
		decoded[1] = math.abs(first)
		return canonicalize(sign, decoded, true)
	end

	if string.find(str, ",", 1, true) then
		local compact = string.gsub(str, ",", "")
		local commaNative = tonumber(compact)
		if commaNative ~= nil then
			return fromNumberRaw(commaNative)
		end
	end

	-- Preserve the old Infinity/native fallback behavior.
	if native ~= nil then
		return fromNumberRaw(native)
	end

	return NAN_OMEGA
end


local function fromStringRaw(str)
	if type(str) ~= "string" then
		return NAN_OMEGA
	end

	if str == STRING_CACHE_S then
		return STRING_CACHE_V
	end

	local out = fromStringUncached(str)
	STRING_CACHE_S = str
	STRING_CACHE_V = out

	return out
end

local function normalize(value)
	local kind = type(value)

	if kind == "table" then
		if CANONICAL[value] then
			return value
		end
		if type(value[2]) == "table" then
			return canonicalize(tonumber(value[1]) or 1, value[2])
		end

		if #value == 2
			and type(value[1]) == "number"
			and type(value[2]) == "number"
		then
			local mantissa = value[1]
			local exponent = value[2]

			if mantissa == 0 then
				return ZERO
			end

			local sign = mantissa < 0 and -1 or 1
			return fromLog10Raw(sign, exponent + math.log10(math.abs(mantissa)))
		end

		return canonicalize(1, value)
	end

	if kind == "number" then
		return fromNumberRaw(value)
	end

	if kind == "string" then
		return fromStringRaw(value)
	end

	if value == nil then
		return ZERO
	end

	return NAN_OMEGA
end

local function absRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	end

	if x[1] > 0 then
		return x
	end

	if x == NEG_INF then
		return POS_INF
	end

	local d = x[2]
	if #d == 1 then
		return fromNumberRaw(d[1])
	end

	return newRaw(1, d)
end

local function negRaw(x)
	if x == NAN_OMEGA or x == ZERO then
		return x
	end

	if x == POS_INF then
		return NEG_INF
	elseif x == NEG_INF then
		return POS_INF
	end

	local d = x[2]
	if #d == 1 then
		return fromNumberRaw(-(x[1] * d[1]))
	end

	return newRaw(-x[1], d)
end

local function cmpMagnitudeData(ad, bd)
	local al = #ad
	local bl = #bd

	if al ~= bl then
		return al > bl and 1 or -1
	end

	if al == 1 then
		local av = ad[1]
		local bv = bd[1]
		if av > bv then
			return 1
		elseif av < bv then
			return -1
		end
		return 0
	end

	for i = al, 1, -1 do
		local av = ad[i]
		local bv = bd[i]

		if av > bv then
			return 1
		elseif av < bv then
			return -1
		end
	end

	return 0
end

local function cmpRaw(a, b)
	if a == b then
		return a == NAN_OMEGA and NAN or 0
	end

	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad
	local bl = #bd

	if al == 1 and bl == 1 then
		local av = a[1] * ad[1]
		local bv = b[1] * bd[1]

		if av < bv then
			return -1
		elseif av > bv then
			return 1
		end

		return 0
	end

	local as = a[1]
	local bs = b[1]

	if as ~= bs then
		return as < bs and -1 or 1
	end

	-- Layer-1 values are the overwhelmingly common huge-number representation.
	-- Compare their payloads directly instead of calling generic rank comparison.
	if al == 2 and bl == 2 and ad[2] == 1 and bd[2] == 1 then
		local av = ad[1]
		local bv = bd[1]
		local c

		if av < bv then
			c = -1
		elseif av > bv then
			c = 1
		else
			return 0
		end

		return as < 0 and -c or c
	end

	local c = cmpMagnitudeData(ad, bd)
	return as < 0 and -c or c
end

local function eqRaw(a, b)
	if a == b then
		return a ~= NAN_OMEGA
	end

	if a == NAN_OMEGA or b == NAN_OMEGA or a[1] ~= b[1] then
		return false
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad

	if al ~= #bd then
		return false
	elseif al == 1 then
		return ad[1] == bd[1]
	elseif al == 2 then
		return ad[1] == bd[1] and ad[2] == bd[2]
	end

	return cmpMagnitudeData(ad, bd) == 0
end

local function maxAbsRaw(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN_OMEGA
	end

	local chosen = cmpMagnitudeData(a[2], b[2]) >= 0 and a or b
	return absRaw(chosen)
end

local function maxRaw(a, b)
	local c = cmpRaw(a, b)
	if c ~= c then
		return NAN_OMEGA
	end
	return c >= 0 and a or b
end

local function minRaw(a, b)
	local c = cmpRaw(a, b)
	if c ~= c then
		return NAN_OMEGA
	end
	return c <= 0 and a or b
end

local function toNumberRaw(x)
	local d = x[2]
	local len = #d

	if len == 1 then
		return x[1] * d[1]
	end

	if len == 2 and d[2] == 1 then
		local payload = d[1]
		if payload > LOG_MAX_NATIVE then
			return x[1] * INF
		end
		return x[1] * (10 ^ payload)
	end

	return x[1] * INF
end

local function magnitudeToNumberData(d)
	local len = #d

	if len == 1 then
		return d[1]
	end

	if len == 2 and d[2] == 1 then
		local payload = d[1]
		if payload > LOG_MAX_NATIVE then
			return INF
		end
		return 10 ^ payload
	end

	return INF
end

local function withSignRaw(magnitude, sign)
	if magnitude == NAN_OMEGA or magnitude == ZERO then
		return magnitude
	end

	local target = sign < 0 and -1 or 1
	if magnitude[1] == target then
		return magnitude
	end

	if magnitude == POS_INF or magnitude == NEG_INF then
		return target < 0 and NEG_INF or POS_INF
	end

	local d = magnitude[2]
	if #d == 1 then
		return fromNumberRaw(target * d[1])
	end

	return newRaw(target, d)
end

local function log10MagnitudeRaw(x)
	local d = x[2]
	local len = #d

	if len == 1 then
		return fromNumberRaw(math.log10(d[1]))
	end

	if len == 2 then
		local layer = d[2]
		if layer == 1 then
			return fromNumberRaw(d[1])
		end
		return newRaw(1, { d[1], layer - 1 })
	end

	local out = copyArray(d)

	if out[2] > 0 then
		out[2] -= 1
		return newRaw(1, out)
	end

	for i = 3, #out do
		if out[i] > 0 then
			out[i] -= 1
			out[i - 1] = MAX_SAFE
			trimTrailingZeros(out)
			return newRaw(1, out)
		end
	end

	return NAN_OMEGA
end

local function log10Raw(x)
	if x == NAN_OMEGA or x[1] < 0 then
		return NAN_OMEGA
	end

	if x == ONE then
		return ZERO
	elseif x == TEN then
		return ONE
	elseif x == ZERO then
		return NEG_INF
	elseif x == POS_INF then
		return POS_INF
	end

	return log10MagnitudeRaw(x)
end

local function pow10Raw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	elseif x == POS_INF then
		return POS_INF
	elseif x == NEG_INF then
		return ZERO
	end

	local d = x[2]
	local len = #d

	if len == 1 then
		return fromLog10Raw(1, x[1] * d[1])
	end

	if x[1] < 0 then
		return ZERO
	end

	if len == 2 then
		local layer = d[2]
		if layer < MAX_SAFE then
			return newRaw(1, { d[1], layer + 1 })
		end
	end

	local out = copyArray(d)
	out[2] = (out[2] or 0) + 1

	if out[2] <= MAX_SAFE then
		return newRaw(1, out)
	end

	return canonicalize(1, out, true)
end

local function magnitudeLog10Data(d)
	local len = #d

	if len == 1 then
		local value = d[1]
		return value <= 0 and -INF or math.log10(value)
	end

	if len == 2 and d[2] == 1 then
		return d[1]
	end

	return INF
end

local function addMagnitudeSigned(a, b, sign)
	local ad = a[2]
	local bd = b[2]
	local c = cmpMagnitudeData(ad, bd)
	local largeObject = c >= 0 and a or b
	local smallObject = c >= 0 and b or a
	local large = largeObject[2]
	local small = smallObject[2]

	local ll = #large
	local sl = #small

	if ll == 1 and sl == 1 then
		return fromNumberRaw(sign * (large[1] + small[1]))
	end

	if ll > 2 or (ll == 2 and large[2] > 1) then
		return withSignRaw(largeObject, sign)
	end

	local logLarge = magnitudeLog10Data(large)
	local logSmall = magnitudeLog10Data(small)

	if logLarge == INF then
		return withSignRaw(largeObject, sign)
	end

	local diff = logLarge - logSmall
	if diff > SIGNIFICANT_DIFF then
		return withSignRaw(largeObject, sign)
	end

	return fromLog10Raw(sign, logLarge + math.log10(1 + 10 ^ (-diff)))
end

local function subMagnitudeSigned(largeObject, smallObject, sign)
	local large = largeObject[2]
	local small = smallObject[2]
	local ll = #large
	local sl = #small

	if ll == 1 and sl == 1 then
		return fromNumberRaw(sign * (large[1] - small[1]))
	end

	if ll > 2 or (ll == 2 and large[2] > 1) then
		return withSignRaw(largeObject, sign)
	end

	local logLarge = magnitudeLog10Data(large)
	local logSmall = magnitudeLog10Data(small)

	if logLarge == INF then
		return withSignRaw(largeObject, sign)
	end

	local diff = logLarge - logSmall
	if diff > SIGNIFICANT_DIFF then
		return withSignRaw(largeObject, sign)
	end

	local ratio = 10 ^ (-diff)
	if ratio >= 1 then
		return ZERO
	end

	return fromLog10Raw(sign, logLarge + math.log10(1 - ratio))
end

local addRaw
local subRaw
local mulRaw
local divRaw
local powRaw
local rootRaw
local tetrateRaw
local pentateRaw

addRaw = function(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN_OMEGA
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad
	local bl = #bd

	if al == 1 and bl == 1 then
		return fromNumberRaw((a[1] * ad[1]) + (b[1] * bd[1]))
	end

	-- Direct layer-1 lane: avoid cmpMagnitudeData/magnitudeLog10Data/helper calls.
	if al == 2 and bl == 2 and ad[2] == 1 and bd[2] == 1 then
		local as = a[1]
		local bs = b[1]
		local ae = ad[1]
		local be = bd[1]

		if as == bs then
			if ae >= be then
				local diff = ae - be
				if diff > SIGNIFICANT_DIFF then
					return a
				end
				return fromLog10Raw(as, ae + math.log10(1 + 10 ^ (-diff)))
			end

			local diff = be - ae
			if diff > SIGNIFICANT_DIFF then
				return b
			end
			return fromLog10Raw(as, be + math.log10(1 + 10 ^ (-diff)))
		end

		if ae == be then
			return ZERO
		elseif ae > be then
			local diff = ae - be
			if diff > SIGNIFICANT_DIFF then
				return a
			end
			return fromLog10Raw(as, ae + math.log10(1 - 10 ^ (-diff)))
		end

		local diff = be - ae
		if diff > SIGNIFICANT_DIFF then
			return b
		end
		return fromLog10Raw(bs, be + math.log10(1 - 10 ^ (-diff)))
	end

	local aInf = a == POS_INF or a == NEG_INF
	local bInf = b == POS_INF or b == NEG_INF

	if aInf or bInf then
		if aInf and bInf and a[1] ~= b[1] then
			return NAN_OMEGA
		end
		return aInf and a or b
	end

	if a == ZERO then
		return b
	elseif b == ZERO then
		return a
	end

	local as = a[1]
	local bs = b[1]

	if as == bs then
		return addMagnitudeSigned(a, b, as)
	end

	local c = cmpMagnitudeData(ad, bd)
	if c == 0 then
		return ZERO
	elseif c > 0 then
		return subMagnitudeSigned(a, b, as)
	end

	return subMagnitudeSigned(b, a, bs)
end

subRaw = function(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN_OMEGA
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad
	local bl = #bd

	if al == 1 and bl == 1 then
		return fromNumberRaw((a[1] * ad[1]) - (b[1] * bd[1]))
	end

	-- Direct layer-1 subtraction. Treat this as a + (-b) without allocating -b.
	if al == 2 and bl == 2 and ad[2] == 1 and bd[2] == 1 then
		local as = a[1]
		local bs = -b[1]
		local ae = ad[1]
		local be = bd[1]

		if as == bs then
			if ae >= be then
				local diff = ae - be
				if diff > SIGNIFICANT_DIFF then
					return a
				end
				return fromLog10Raw(as, ae + math.log10(1 + 10 ^ (-diff)))
			end

			local diff = be - ae
			if diff > SIGNIFICANT_DIFF then
				return withSignRaw(b, bs)
			end
			return fromLog10Raw(as, be + math.log10(1 + 10 ^ (-diff)))
		end

		if ae == be then
			return ZERO
		elseif ae > be then
			local diff = ae - be
			if diff > SIGNIFICANT_DIFF then
				return a
			end
			return fromLog10Raw(as, ae + math.log10(1 - 10 ^ (-diff)))
		end

		local diff = be - ae
		if diff > SIGNIFICANT_DIFF then
			return withSignRaw(b, bs)
		end
		return fromLog10Raw(bs, be + math.log10(1 - 10 ^ (-diff)))
	end

	if b == ZERO then
		return a
	elseif a == ZERO then
		return negRaw(b)
	end

	local aInf = a == POS_INF or a == NEG_INF
	local bInf = b == POS_INF or b == NEG_INF

	if aInf or bInf then
		if aInf and bInf and a[1] == b[1] then
			return NAN_OMEGA
		end
		if aInf then
			return a
		end
		return negRaw(b)
	end

	local as = a[1]
	local bs = b[1]

	if as ~= bs then
		return addMagnitudeSigned(a, b, as)
	end

	local c = cmpMagnitudeData(ad, bd)
	if c == 0 then
		return ZERO
	elseif c > 0 then
		return subMagnitudeSigned(a, b, as)
	end

	return subMagnitudeSigned(b, a, -as)
end

mulRaw = function(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN_OMEGA
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad
	local bl = #bd

	if al == 1 and bl == 1 then
		return fromNumberRaw((a[1] * ad[1]) * (b[1] * bd[1]))
	end

	if a == ZERO or b == ZERO then
		return ZERO
	end

	local sign = a[1] * b[1]

	if a == POS_INF or a == NEG_INF or b == POS_INF or b == NEG_INF then
		return sign < 0 and NEG_INF or POS_INF
	end

	if al == 2 and ad[2] == 1 and bl == 2 and bd[2] == 1 then
		return fromLog10Raw(sign, ad[1] + bd[1])
	end

	if al == 1 and ad[1] == 1 then
		return withSignRaw(b, sign)
	elseif bl == 1 and bd[1] == 1 then
		return withSignRaw(a, sign)
	end

	local an = magnitudeToNumberData(ad)
	local bn = magnitudeToNumberData(bd)

	if an ~= INF and bn ~= INF then
		local n = an * bn
		if n == n and n ~= INF then
			return fromNumberRaw(sign * n)
		end
	end

	local exponent = addRaw(log10MagnitudeRaw(a), log10MagnitudeRaw(b))
	local magnitude = pow10Raw(exponent)
	return withSignRaw(magnitude, sign)
end

divRaw = function(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA then
		return NAN_OMEGA
	end

	local ad = a[2]
	local bd = b[2]
	local al = #ad
	local bl = #bd

	if al == 1 and bl == 1 then
		local bv = b[1] * bd[1]
		if bv == 0 then
			return NAN_OMEGA
		end
		return fromNumberRaw((a[1] * ad[1]) / bv)
	end

	if b == ZERO then
		return NAN_OMEGA
	elseif a == ZERO then
		return ZERO
	end

	local aInf = a == POS_INF or a == NEG_INF
	local bInf = b == POS_INF or b == NEG_INF

	if aInf and bInf then
		return NAN_OMEGA
	end

	local sign = a[1] * b[1]

	if aInf then
		return sign < 0 and NEG_INF or POS_INF
	elseif bInf then
		return ZERO
	end

	if al == 2 and ad[2] == 1 and bl == 2 and bd[2] == 1 then
		return fromLog10Raw(sign, ad[1] - bd[1])
	end

	if bl == 1 and bd[1] == 1 then
		return withSignRaw(a, sign)
	end

	local an = magnitudeToNumberData(ad)
	local bn = magnitudeToNumberData(bd)

	if an ~= INF and bn ~= INF then
		local n = an / bn
		if n == n and n ~= INF then
			return fromNumberRaw(sign * n)
		end
	end

	local exponent = subRaw(log10MagnitudeRaw(a), log10MagnitudeRaw(b))
	local magnitude = pow10Raw(exponent)
	return withSignRaw(magnitude, sign)
end

local function recipRaw(x)
	if x == NAN_OMEGA or x == ZERO then
		return NAN_OMEGA
	elseif x == POS_INF or x == NEG_INF then
		return ZERO
	end

	local d = x[2]
	local len = #d

	if len == 1 then
		return fromNumberRaw(1 / (x[1] * d[1]))
	end

	if len == 2 and d[2] == 1 then
		return fromLog10Raw(x[1], -d[1])
	end

	return ZERO
end

local function isIntRaw(x)
	if x == NAN_OMEGA or x == POS_INF or x == NEG_INF then
		return false
	end

	local d = x[2]
	local len = #d

	if len == 1 then
		local n = x[1] * d[1]
		return n == math.floor(n)
	end

	if len == 2 then
		local layer = d[2]
		if layer >= 2 then
			return true
		end
		return layer == 1 and d[1] >= 0 and d[1] == math.floor(d[1])
	end

	return true
end

local function modRaw(a, b)
	if a == NAN_OMEGA or b == NAN_OMEGA or b == ZERO then
		return NAN_OMEGA
	end

	local ad = a[2]
	local bd = b[2]

	if #ad == 1 and #bd == 1 then
		local av = a[1] * ad[1]
		local bv = b[1] * bd[1]

		if av == INF or av == -INF or bv == INF or bv == -INF then
			return NAN_OMEGA
		end

		return fromNumberRaw(av % bv)
	end

	local an = toNumberRaw(a)
	local bn = toNumberRaw(b)

	if an == INF or an == -INF or bn == INF or bn == -INF then
		return NAN_OMEGA
	end

	return fromNumberRaw(an % bn)
end

powRaw = function(base, exponent)
	if base == NAN_OMEGA or exponent == NAN_OMEGA then
		return NAN_OMEGA
	end

	local bd = base[2]
	local ed = exponent[2]
	local bl = #bd
	local el = #ed

	if bl == 1 and el == 1 then
		local b = base[1] * bd[1]
		local e = exponent[1] * ed[1]

		if e == 0 then
			return ONE
		elseif b == 0 then
			return e < 0 and NAN_OMEGA or ZERO
		end

		if b < 0 and (e ~= math.floor(e) or math.abs(e) > MAX_SAFE) then
			return NAN_OMEGA
		end

		local n = b ^ e
		if n == n and n ~= INF and n ~= -INF then
			return fromNumberRaw(n)
		end
	end

	if exponent == ZERO then
		return ONE
	elseif base == ONE then
		return ONE
	elseif base == ZERO then
		return exponent[1] < 0 and NAN_OMEGA or ZERO
	end

	if base[1] > 0 then
		local bn = toNumberRaw(base)
		local en = toNumberRaw(exponent)

		if bn ~= INF and en ~= INF and en ~= -INF then
			local native = bn ^ en
			if native == native and native ~= INF and native > 0 then
				return fromNumberRaw(native)
			end
		end
	end

	if exponent[1] < 0 then
		return recipRaw(powRaw(base, negRaw(exponent)))
	end

	local resultSign = 1

	if base[1] < 0 then
		if not isIntRaw(exponent) then
			return NAN_OMEGA
		end

		local en = toNumberRaw(exponent)
		if en == INF or en > MAX_SAFE then
			return NAN_OMEGA
		end

		if en % 2 ~= 0 then
			resultSign = -1
		end

		local bn = magnitudeToNumberData(bd)
		if bn ~= INF then
			local native = bn ^ en
			if native == native and native ~= INF and native > 0 then
				return fromNumberRaw(resultSign * native)
			end
		end
	end

	-- +/-10 needs no logarithm at all.
	if bl == 1 and bd[1] == 10 then
		local magnitude = pow10Raw(exponent)
		return withSignRaw(magnitude, resultSign)
	end

	local power = mulRaw(log10MagnitudeRaw(base), exponent)
	local magnitude = pow10Raw(power)
	return withSignRaw(magnitude, resultSign)
end

rootRaw = function(value, degree)
	if value == NAN_OMEGA or degree == NAN_OMEGA or degree == ZERO then
		return NAN_OMEGA
	end

	local vd = value[2]
	local dd = degree[2]

	if #vd == 1 and #dd == 1 then
		local v = value[1] * vd[1]
		local d = degree[1] * dd[1]

		if d == 0 then
			return NAN_OMEGA
		end

		if v >= 0 then
			local n = v ^ (1 / d)
			if n == n and n ~= INF then
				return fromNumberRaw(n)
			end
		elseif d == math.floor(d) and math.abs(d) <= MAX_SAFE and d % 2 ~= 0 then
			local n = (-v) ^ (1 / math.abs(d))
			if d < 0 then
				n = 1 / n
			end
			return fromNumberRaw(-n)
		else
			return NAN_OMEGA
		end
	end

	local vn = toNumberRaw(value)
	local dn = toNumberRaw(degree)

	if dn ~= INF and dn ~= -INF and vn ~= INF and vn ~= -INF then
		if vn >= 0 then
			return fromNumberRaw(vn ^ (1 / dn))
		end

		if dn == math.floor(dn) and math.abs(dn) <= MAX_SAFE and dn % 2 ~= 0 then
			local magnitude = (-vn) ^ (1 / math.abs(dn))
			if dn < 0 then
				magnitude = 1 / magnitude
			end
			return fromNumberRaw(-magnitude)
		end

		return NAN_OMEGA
	end

	if degree[1] < 0 then
		return recipRaw(rootRaw(value, negRaw(degree)))
	end

	if value[1] < 0 then
		if not isIntRaw(degree) or dn == INF or dn > MAX_SAFE or dn % 2 == 0 then
			return NAN_OMEGA
		end

		local positive = newRaw(1, vd)
		return negRaw(rootRaw(positive, degree))
	end

	return powRaw(value, recipRaw(degree))
end

local function sqrtRaw(x)
	if x == NAN_OMEGA or x[1] < 0 then
		return NAN_OMEGA
	end

	if x == ZERO or x == POS_INF then
		return x
	end

	local d = x[2]
	if #d == 1 then
		return fromNumberRaw(math.sqrt(d[1]))
	end

	local n = toNumberRaw(x)
	if n ~= INF then
		return fromNumberRaw(math.sqrt(n))
	end

	return rootRaw(x, TWO)
end

local function expRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	elseif x == NEG_INF then
		return ZERO
	elseif x == POS_INF then
		return POS_INF
	end

	local d = x[2]
	if #d == 1 then
		local native = math.exp(x[1] * d[1])
		if native ~= INF then
			return fromNumberRaw(native)
		end
	end

	local n = toNumberRaw(x)
	if n ~= INF and n ~= -INF then
		local native = math.exp(n)
		if native ~= INF then
			return fromNumberRaw(native)
		end
	end

	return powRaw(E_OMEGA, x)
end

local function floorRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	elseif x == POS_INF or x == NEG_INF then
		return x
	end

	local d = x[2]
	if #d ~= 1 then
		return x
	end

	local n = x[1] * d[1]
	local floored = math.floor(n)
	return floored == n and x or fromNumberRaw(floored)
end

local function ceilRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	elseif x == POS_INF or x == NEG_INF then
		return x
	end

	local d = x[2]
	if #d ~= 1 then
		return x
	end

	local n = x[1] * d[1]
	local ceiled = math.ceil(n)
	return ceiled == n and x or fromNumberRaw(ceiled)
end

local function logRaw(x, base)
	if base == nil then
		base = E_OMEGA
	end

	local xn = toNumberRaw(x)
	local bn = toNumberRaw(base)

	if xn ~= INF
		and xn ~= -INF
		and bn ~= INF
		and bn ~= -INF
		and xn > 0
		and bn > 0
		and bn ~= 1
	then
		return fromNumberRaw(math.log(xn) / math.log(bn))
	end

	if base == TEN then
		return log10Raw(x)
	elseif base == E_OMEGA then
		return divRaw(log10Raw(x), LOG10_E_OMEGA)
	end

	return divRaw(log10Raw(x), log10Raw(base))
end

local function symbolicHyper(base, arrows, height)
	local baseLog = log10MagnitudeRaw(base)
	local payload = toNumberRaw(baseLog)

	if payload == INF or payload ~= payload then
		payload = base[2][1] or 1
	end

	payload = math.abs(payload)
	if payload < 1 then
		payload = 1
	end

	local data = table.create(math.min(arrows + 1, ARROW_LIMIT + 1), 0)
	data[1] = payload
	data[2] = 0

	local index = math.min(arrows + 1, ARROW_LIMIT + 1)
	local h = toNumberRaw(height)

	if h == INF or h ~= h then
		h = 1
	end

	data[index] = math.max(1, math.floor(math.abs(h)))
	return canonicalize(base[1] < 0 and -1 or 1, data, true)
end

local function slogRaw(value, base)
	if isNaNRaw(value) or isNaNRaw(base) then
		return NAN_OMEGA
	end

	local vn = toNumberRaw(value)
	local bn = toNumberRaw(base)

	if vn ~= INF
		and vn ~= -INF
		and bn ~= INF
		and bn ~= -INF
		and vn > 0
		and bn > INV_E_EXP
		and bn ~= 1
	then
		local x = vn
		local logBase = math.log(bn)
		local count = 0

		for _ = 1, 100 do
			if x <= 1 then
				return fromNumberRaw(count + x - 1)
			end

			x = math.log(x) / logBase
			count = count + 1

			if x ~= x then
				return NAN_OMEGA
			end
		end

		return fromNumberRaw(count)
	end

	if cmpRaw(value, ZERO) <= 0 then
		return fromNumberRaw(-1)
	end

	if cmpRaw(value, ONE) == 0 then
		return ZERO
	end

	if cmpRaw(value, base) == 0 then
		return ONE
	end

	if bn ~= INF and bn <= INV_E_EXP then
		return value
	end

	local x = value
	local count = 0

	if #x[2] == 2 and x[2][2] > 3 then
		local skip = x[2][2] - 3
		x = newRaw(x[1], { x[2][1], 3 })
		count = count + skip
	end

	for _ = 1, 100 do
		local c = cmpRaw(x, ONE)

		if c <= 0 then
			local xn = toNumberRaw(x)
			if xn ~= INF and xn ~= -INF then
				return fromNumberRaw(count + xn - 1)
			end
			return fromNumberRaw(count)
		end

		x = logRaw(x, base)
		count = count + 1

		if isNaNRaw(x) then
			return NAN_OMEGA
		end
	end

	return fromNumberRaw(count)
end

tetrateRaw = function(base, height)
	if isNaNRaw(base) or isNaNRaw(height) then
		return NAN_OMEGA
	end

	local h = toNumberRaw(height)

	if h == INF or h > MAX_SAFE then
		return symbolicHyper(base, 2, height)
	end

	if h < -1 then
		return NAN_OMEGA
	end

	if h == -1 then
		return ZERO
	end

	if h == 0 then
		return ONE
	end

	if isZeroRaw(base) then
		if h == 0 then
			return ONE
		end

		if h == math.floor(h) then
			return (h % 2 == 0) and ONE or ZERO
		end

		return NAN_OMEGA
	end

	if isOneRaw(base) then
		return ONE
	end

	-- Exact native tower fast path for the small integer heights used most
	-- often in gameplay and benchmarks.
	if h == math.floor(h) and h >= 1 and h <= 4 then
		local bn = toNumberRaw(base)

		if bn ~= INF and bn ~= -INF and bn > 0 then
			local native = 1

			for _ = 1, h do
				native = bn ^ native

				if native == INF or native ~= native then
					break
				end
			end

			if native ~= INF and native == native then
				return fromNumberRaw(native)
			end
		end
	end

	local whole = math.floor(h)
	local frac = h - whole
	local result

	if frac == 0 then
		result = ONE
	else
		result = powRaw(base, fromNumberRaw(frac))
	end

	local steps = math.min(whole, 100)

	for _ = 1, steps do
		result = powRaw(base, result)

		if isNaNRaw(result) or isInfRaw(result) then
			return result
		end
	end

	local remaining = whole - steps

	if remaining > 0 then
		local d = copyArray(result[2])
		d[2] = (d[2] or 0) + remaining
		if d[2] <= MAX_SAFE then
			result = newRaw(result[1], d)
		else
			result = canonicalize(result[1], d, true)
		end
	end

	return result
end

pentateRaw = function(base, height)
	if isNaNRaw(base) or isNaNRaw(height) then
		return NAN_OMEGA
	end

	local h = toNumberRaw(height)

	if h == INF or h > MAX_SAFE then
		return symbolicHyper(base, 3, height)
	end

	if h < -1 then
		return NAN_OMEGA
	end

	if h == -1 then
		return ZERO
	end

	if h == 0 then
		return ONE
	end

	if isZeroRaw(base) then
		if h == math.floor(h) then
			return (h % 2 == 0) and ONE or ZERO
		end
		return NAN_OMEGA
	end

	if isOneRaw(base) then
		return ONE
	end

	if h ~= math.floor(h) then
		-- Fractional pentation is not uniquely defined by classic OmegaNum.
		-- Keep V2 deterministic rather than silently inventing an interpolation.
		return NAN_OMEGA
	end

	if h == 1 then
		return base
	end

	if h == 2 then
		return tetrateRaw(base, base)
	end

	if h == 3 then
		local second = tetrateRaw(base, base)
		return tetrateRaw(base, second)
	end

	local result = ONE
	local steps = math.min(h, 20)

	for _ = 1, steps do
		result = tetrateRaw(base, result)

		if isNaNRaw(result) or isInfRaw(result) then
			return result
		end

		if #result[2] > 4 then
			break
		end
	end

	if h > steps or #result[2] > 4 then
		return symbolicHyper(base, 3, height)
	end

	return result
end

local function arrowRaw(base, arrows, height)
	if type(arrows) ~= "number"
		or isNaNNumber(arrows)
		or arrows < 0
		or arrows ~= math.floor(arrows)
	then
		return NAN_OMEGA
	end

	if arrows > ARROW_LIMIT then
		return symbolicHyper(base, ARROW_LIMIT, height)
	end

	if arrows == 0 then
		return mulRaw(base, height)
	elseif arrows == 1 then
		return powRaw(base, height)
	elseif arrows == 2 then
		return tetrateRaw(base, height)
	elseif arrows == 3 then
		return pentateRaw(base, height)
	end

	local h = toNumberRaw(height)

	if h == INF or h > 2 then
		return symbolicHyper(base, arrows, height)
	end

	if h < 0 or h ~= math.floor(h) then
		return NAN_OMEGA
	end

	if h == 0 then
		return ONE
	elseif h == 1 then
		return base
	end

	-- a ↑^n 2 = a ↑^(n-1) a
	return arrowRaw(base, arrows - 1, base)
end

local function nativeLambertW(z)
	if z ~= z then
		return NAN
	end

	if z == 0 then
		return 0
	end

	if z < -1 / E then
		return NAN
	end

	if z == 1 then
		return 0.5671432904097839
	end

	local w

	if z < 1 then
		w = z
	elseif z < 10 then
		w = math.log(1 + z)
	else
		w = math.log(z) - math.log(math.log(z))
	end

	for _ = 1, 50 do
		local ew = math.exp(w)
		local f = w * ew - z
		local wp1 = w + 1
		local denom = ew * wp1 - ((w + 2) * f) / (2 * wp1)
		local nextW = w - f / denom

		if math.abs(nextW - w) <= 1e-12 * math.max(1, math.abs(nextW)) then
			return nextW
		end

		w = nextW
	end

	return w
end

local LANCZOS = {
	0.99999999999980993,
	676.5203681218851,
	-1259.1392167224028,
	771.32342877765313,
	-176.61502916214059,
	12.507343278686905,
	-0.13857109526572012,
	9.9843695780195716e-6,
	1.5056327351493116e-7,
}

local function nativeGamma(z)
	if z < 0.5 then
		return math.pi / (math.sin(math.pi * z) * nativeGamma(1 - z))
	end

	z = z - 1

	local x = LANCZOS[1]
	for i = 2, #LANCZOS do
		x = x + LANCZOS[i] / (z + i - 1)
	end

	local t = z + 7.5
	return math.sqrt(2 * math.pi) * (t ^ (z + 0.5)) * math.exp(-t) * x
end

local FACTORIAL_CACHE = table.create(171)
FACTORIAL_CACHE[1] = 1

do
	local value = 1
	for i = 1, 170 do
		value *= i
		FACTORIAL_CACHE[i + 1] = value
	end
end

local function factorialNative(n)
	return FACTORIAL_CACHE[n + 1]
end

local function gammaRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	end

	local n = toNumberRaw(x)

	if n ~= INF and n ~= -INF and n <= 171 then
		if n >= 1 and n == math.floor(n) then
			return fromNumberRaw(FACTORIAL_CACHE[n])
		end
		return fromNumberRaw(nativeGamma(n))
	end

	if x[1] < 0 then
		return NAN_OMEGA
	end

	-- Stirling: Gamma(x) ~= sqrt(2*pi/x) * (x/e)^x
	local xMinusHalf = subRaw(x, HALF)
	local main = subRaw(mulRaw(xMinusHalf, logRaw(x, E_OMEGA)), x)
	return powRaw(E_OMEGA, addRaw(main, STIRLING_CORRECTION))
end

local function factRaw(x)
	if x == NAN_OMEGA then
		return NAN_OMEGA
	end

	local n = toNumberRaw(x)

	if n ~= INF and n ~= -INF and n >= 0 and n <= 170 and n == math.floor(n) then
		return fromNumberRaw(factorialNative(n))
	end

	return gammaRaw(addRaw(x, ONE))
end

local function normalizeBigNum(mantissa, exponent)
	if mantissa == 0 then
		return { 0, 0 }
	end

	local sign = mantissa < 0 and -1 or 1
	mantissa = math.abs(mantissa)

	local shift = math.floor(math.log10(mantissa))
	mantissa = mantissa / (10 ^ shift)
	exponent = exponent + shift

	return { sign * mantissa, math.floor(exponent) }
end

local function toBigNumRaw(x)
	if isNaNRaw(x) then
		return { NAN, 0 }
	end

	if isInfRaw(x) then
		return { x[1] * INF, INF }
	end

	local d = x[2]

	if #d == 1 then
		return normalizeBigNum(x[1] * d[1], 0)
	end

	if #d == 2 and d[2] == 1 then
		local exponent = math.floor(d[1])
		local mantissa = 10 ^ (d[1] - exponent)
		return { x[1] * mantissa, exponent }
	end

	if #d == 2 and d[2] == 2 and d[1] <= LOG_MAX_NATIVE then
		return { x[1], 10 ^ d[1] }
	end

	return { x[1], INF }
end

local FIRST_ONES = {
	"", "U", "D", "T", "q", "Q", "s", "S", "O", "N",
}

local SECOND_ONES = {
	"", "d", "v", "t", "qg", "Qg", "sg", "Sg", "o", "n",
}

local THIRD_ONES = {
	"", "C", "Du", "Tr", "Qa", "Qi", "Se", "Si", "Ot", "Ni",
}

local MULT_ONES = {
	"", "Mi", "Mc", "Na", "Pi", "Fm", "At", "Zp", "Yc", "Xo", "Ve", "Me",
	"Due", "Tre", "Te", "Pt", "He", "Hp", "Oct", "En", "Ic", "Mei", "Dui",
	"Tri", "Teti", "Pti", "Hei", "Hp", "Oci", "Eni", "Tra", "TeC", "MTc",
	"DTc", "TrTc", "TeTc", "PeTc", "HTc", "HpT", "OcT", "EnT", "TetC",
	"MTetc", "DTetc", "TrTetc", "TeTetc", "PeTetc", "HTetc", "HpTetc",
	"OcTetc", "EnTetc", "PcT", "MPcT", "DPcT", "TPCt", "TePCt", "PePCt",
	"HePCt", "HpPct", "OcPct", "EnPct", "HCt", "MHcT", "DHcT", "THCt",
	"TeHCt", "PeHCt", "HeHCt", "HpHct", "OcHct", "EnHct", "HpCt", "MHpcT",
	"DHpcT", "THpCt", "TeHpCt", "PeHpCt", "HeHpCt", "HpHpct", "OcHpct",
	"EnHpct", "OCt", "MOcT", "DOcT", "TOCt", "TeOCt", "PeOCt", "HeOCt",
	"HpOct", "OcOct", "EnOct", "Ent", "MEnT", "DEnT", "TEnt", "TeEnt",
	"PeEnt", "HeEnt", "HpEnt", "OcEnt", "EnEnt", "Hect", "MeHect",
}

local function roundDown(value, digits)
	local scale = 10 ^ digits
	return math.floor(value * scale + 1e-12) / scale
end

local function commaInteger(value)
	local str = tostring(math.floor(value))
	local sign = ""

	if string.sub(str, 1, 1) == "-" then
		sign = "-"
		str = string.sub(str, 2)
	end

	local out = str
	local count

	repeat
		out, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
	until count == 0

	return sign .. out
end

local function shortBigNum(bnum)
	local mantissa = bnum[1]
	local exponent = bnum[2]

	if mantissa ~= mantissa then
		return "NaN"
	end

	if mantissa == INF or mantissa == -INF or exponent == INF then
		return mantissa < 0 and "-Infinity" or "Infinity"
	end

	if mantissa == 0 then
		return "0"
	end

	local sign = mantissa < 0 and "-" or ""
	mantissa = math.abs(mantissa)

	if exponent < 3 then
		return sign .. tostring(roundDown(mantissa * (10 ^ exponent), 2))
	end

	local group = math.floor(exponent / 3) - 1
	local leftover = exponent % 3
	local shown = roundDown(mantissa * (10 ^ leftover), 2)

	if group == 0 then
		return sign .. commaInteger(shown * 1000)
	elseif group == 1 then
		return sign .. tostring(shown) .. "M"
	elseif group == 2 then
		return sign .. tostring(shown) .. "B"
	end

	local text = ""

	local function suffixPart(n)
		local hundreds = math.floor(n / 100)
		n = n % 100
		local tens = math.floor(n / 10)
		local ones = n % 10

		text = text
			.. (FIRST_ONES[ones + 1] or "")
			.. (SECOND_ONES[tens + 1] or "")
			.. (THIRD_ONES[hundreds + 1] or "")
	end

	local function suffixPart2(n)
		if n > 0 then
			n = n + 1
		end

		if n > 1000 then
			n = n % 1000
		end

		suffixPart(n)
	end

	if group < 1000 then
		suffixPart(group)
		return sign .. tostring(shown) .. text
	end

	local remaining = group

	for i = #MULT_ONES, 0, -1 do
		local power = 10 ^ (i * 3)

		if remaining >= power then
			suffixPart2(math.floor(remaining / power) - 1)
			text = text .. (MULT_ONES[i + 1] or "")
			remaining = remaining % power
		end
	end

	if text == "" then
		return sign .. tostring(shown) .. "e" .. tostring(exponent)
	end

	return sign .. tostring(shown) .. text
end

local function toScientificRaw(x)
	if isNaNRaw(x) then
		return "NaN"
	end

	if isInfRaw(x) then
		return x[1] < 0 and "-Infinity" or "Infinity"
	end

	local d = x[2]
	local sign = x[1] < 0 and "-" or ""

	if #d == 1 then
		if d[1] < 1000 then
			return x[1] * d[1]
		end

		local exponent = math.floor(math.log10(d[1]))
		local mantissa = d[1] / (10 ^ exponent)
		return sign .. tostring(roundDown(mantissa, PRECISION_DISPLAY)) .. "e" .. tostring(exponent)
	end

	if #d == 2 and d[2] == 1 then
		local exponent = math.floor(d[1])
		local mantissa = 10 ^ (d[1] - exponent)
		return sign .. tostring(roundDown(mantissa, PRECISION_DISPLAY)) .. "e" .. tostring(exponent)
	end

	if #d == 2 then
		if d[2] <= MAX_ES then
			return sign
				.. string.rep("e", d[2])
				.. tostring(roundDown(d[1], PRECISION_DISPLAY))
		end

		return sign
			.. "e["
			.. tostring(d[2])
			.. "]"
			.. tostring(roundDown(d[1], PRECISION_DISPLAY))
	end

	return nil
end

local function toHyperERaw(x, useShort)
	if isNaNRaw(x) then
		return "NaN"
	end

	if isInfRaw(x) then
		return x[1] < 0 and "-Infinity" or "Infinity"
	end

	local d = x[2]
	local sign = x[1] < 0 and "-" or ""

	if #d == 1 then
		return sign .. tostring(shortBigNum(toBigNumRaw(absRaw(x))))
	end

	if #d == 2 then
		if d[2] <= MAX_ES then
			return sign
				.. string.rep("e", d[2])
				.. tostring(roundDown(d[1], useShort and 2 or PRECISION_DISPLAY))
		end

		return sign
			.. "E"
			.. tostring(roundDown(d[1], useShort and 2 or PRECISION_DISPLAY))
			.. "#"
			.. tostring(d[2])
	end

	local first = useShort
		and shortBigNum(toBigNumRaw(fromNumberRaw(d[1])))
		or tostring(roundDown(d[1], PRECISION_DISPLAY))

	local out = sign .. "E" .. tostring(first) .. "#" .. tostring(d[2] or 0)

	for i = 3, #d do
		out = out .. "#" .. tostring(d[i])
	end

	return out
end

local function abbreviateRaw(x)
	if isNaNRaw(x) then
		return "NaN"
	end

	if isZeroRaw(x) then
		return "0"
	end

	if isInfRaw(x) then
		return x[1] < 0 and "-Infinity" or "Infinity"
	end

	if x[1] < 0 then
		return "-" .. abbreviateRaw(absRaw(x))
	end

	local d = x[2]

	if #d == 1 then
		return shortBigNum(toBigNumRaw(x))
	end

	if #d == 2 and d[2] == 1 and d[1] <= 3000000 then
		return shortBigNum(toBigNumRaw(x))
	end

	local sci = toScientificRaw(x)
	if sci ~= nil then
		return tostring(sci)
	end

	return toHyperERaw(x, true)
end

-- Safe-integer lossy compatibility encoding.
-- V2 deliberately keeps the result <= 2^53-1.
local LB_MODE_SCALE = 1e13
local LB_BODY_SCALE = 1e9
local LB_MAX_MODE = 899

local function clamp01(n)
	if n < 0 then
		return 0
	elseif n > 1 then
		return 1
	end
	return n
end

local function lbencodeSafeRaw(x)
	if isNaNRaw(x) then
		return NAN
	end

	if isZeroRaw(x) then
		return 0
	end

	local sign = x[1]
	local d = x[2]
	local len = #d

	if len == 1 then
		local p = clamp01(math.log10(d[1] + 1) / 309)
		return sign * math.floor(p * (LB_MODE_SCALE - 1))
	end

	if len == 2 then
		local layer = math.min(9999, math.max(0, math.floor(d[2])))
		local p = clamp01((math.log10(math.abs(d[1]) + 1) + 324) / 648)
		local body = layer * LB_BODY_SCALE + math.floor(p * (LB_BODY_SCALE - 1))
		return sign * (LB_MODE_SCALE + body)
	end

	local rank = math.min(LB_MAX_MODE - 2, len - 2)
	local mode = rank + 2
	local top = d[len]
	local p = clamp01(math.log10(math.abs(top) + 1) / 16)
	local body = math.floor(p * (LB_MODE_SCALE - 1))

	return sign * (mode * LB_MODE_SCALE + body)
end

local function lbdecodeSafeRaw(code)
	if type(code) ~= "number" or isNaNNumber(code) then
		return NAN_OMEGA
	end

	if code == 0 then
		return ZERO
	end

	local sign = code < 0 and -1 or 1
	code = math.abs(code)

	local mode = math.floor(code / LB_MODE_SCALE)
	local body = code - mode * LB_MODE_SCALE

	if mode == 0 then
		local p = body / (LB_MODE_SCALE - 1)
		local value = 10 ^ (p * 309) - 1
		return fromNumberRaw(sign * value)
	end

	if mode == 1 then
		local layer = math.floor(body / LB_BODY_SCALE)
		local frac = body - layer * LB_BODY_SCALE
		local p = frac / (LB_BODY_SCALE - 1)
		local payload = 10 ^ (p * 648 - 324) - 1
		return canonicalize(sign, { payload, layer }, true)
	end

	local rank = math.max(1, mode - 2)
	local p = body / (LB_MODE_SCALE - 1)
	local top = 10 ^ (p * 16) - 1

	local data = table.create(rank + 2, 0)
	data[1] = 1
	data[2] = 0
	data[rank + 2] = math.max(1, math.floor(top))

	return canonicalize(sign, data, true)
end


-- Legacy lb codec -------------------------------------------------------------
-- Kept on the original public names so V1 saved numeric payloads still decode.
-- This format is inherently lossy above 2^53-1 because Luau numbers are doubles.

local function lbencodeLegacyRaw(x)
	if isNaNRaw(x) then
		return NAN
	end

	if isZeroRaw(x) then
		return 0
	end

	local sign = x[1]
	local data = x[2]
	local amount = #data

	if amount == 1 then
		return sign * math.floor(math.log10(data[1] + 1) * 6.26775e14)
	elseif amount == 2 and data[2] < 4 then
		return sign * (
			math.floor(math.log10(data[1] + 1) * 6.26775e14)
				+ data[2] * 1e16
		)
	elseif amount == 2 and data[2] <= 9999 then
		local code = 4e16
		code = code + math.log10(data[1] + 1) * 6.26775e8
		code = code + data[2] * 1e10
		return sign * code
	elseif amount == 2 then
		local code = 5e16
		code = code
			+ math.log10(data[2] + (math.log10(data[1]) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount == 3 and data[3] == 1 then
		local code = 6e16
		code = code
			+ math.log10(data[2] + (math.log10(data[1]) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount == 3 and data[3] == 2 then
		local code = 7e16
		code = code
			+ math.log10(data[2] + (math.log10(data[1]) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount == 3 and data[3] < 9999 then
		local code = 8e16
		code = code
			+ math.log10(data[2] + (math.log10(data[1]) / 16) + 1) * 6.26775e8
		code = code + data[3] * 1e10
		return sign * code
	elseif amount == 3 then
		local code = 9e16
		code = code
			+ math.log10(data[3] + (math.log10(data[2] + 1) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount == 4 then
		local code = 1e17
		code = code
			+ math.log10(data[4] + (math.log10(data[3] + 1) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount == 5 then
		local code = 1.1e17
		code = code
			+ math.log10(data[5] + (math.log10(data[4] + 1) / 16) + 1) * 6.26775e14
		return sign * code
	elseif amount > 5 and amount < 917 then
		local code = amount * 1e16 + 6e16
		code = code
			+ math.log10(
				data[amount]
				+ (math.log10(data[amount - 1] + 1) / 16)
				+ 1
			) * 6.26775e14
		return sign * code
	end

	return sign * 9223372036854775808
end

local function lbdecodeLegacyRaw(code)
	if type(code) ~= "number" or isNaNNumber(code) then
		return NAN_OMEGA
	end

	if code == 0 then
		return ZERO
	end

	local sign = code < 0 and -1 or 1
	code = math.abs(code)
	local mode = math.floor(code / 1e16)

	if mode >= 3 then
		code = code - 1
	end

	if mode == 0 then
		return canonicalize(sign, {
			10 ^ (code / 6.26775e14) - 1,
		}, true)
	elseif mode < 4 then
		return canonicalize(sign, {
			10 ^ (math.fmod(code, 1e16) / 6.26775e14) - 1,
			mode,
		}, true)
	elseif mode == 4 then
		local remainder = math.fmod(code, 1e10)
		return canonicalize(sign, {
			10 ^ (remainder / 6.26775e8) - 1,
			math.floor((code - 4e16) / 1e10),
		}, true)
	elseif mode == 5 then
		local remainder = math.fmod(code, 1e16)
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		return canonicalize(sign, { arg1, math.floor(arrows) }, true)
	elseif mode == 6 then
		local remainder = math.fmod(code, 1e16)
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		return canonicalize(sign, { arg1, math.floor(arrows), 1 }, true)
	elseif mode == 7 then
		local remainder = math.fmod(code, 1e16)
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		return canonicalize(sign, { arg1, math.floor(arrows), 2 }, true)
	elseif mode == 8 then
		local arg3 = math.floor((code - 8e16) / 1e10)
		local remainder = math.fmod(code, 1e10) * 1e6
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		return canonicalize(sign, { arg1, math.floor(arrows), math.floor(arg3) }, true)
	elseif mode == 9 then
		local remainder = math.fmod(code, 1e16)
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		return canonicalize(sign, { 1, math.floor(arg1), math.floor(arrows) }, true)
	elseif mode == 10 then
		local remainder = math.fmod(code, 1e16)
		local arrows = 10 ^ (remainder / 6.26775e14) - 1
		local arg1 = 10 ^ (math.fmod(arrows, 1) * 16)
		local data = { 1, 0, math.floor(arg1), math.floor(arrows) }

		if data[4] == 0 then
			data[4] = nil
		end

		return canonicalize(sign, data, true)
	end

	local zeros = mode - 10
	local remainder = math.fmod(code, 1e16)
	local arrows = 10 ^ (remainder / 6.26775e14) - 1
	local arg1 = MAX_SAFE ^ math.fmod(arrows, 1)
	local data = { 1, 0 }

	for _ = 1, zeros do
		data[#data + 1] = 0
	end

	data[#data + 1] = math.floor(arg1)
	data[#data + 1] = math.floor(arrows)

	if data[#data] == 0 then
		data[#data] = nil
	end

	return canonicalize(sign, data, true)
end

-- Public API -----------------------------------------------------------------
-- PERF v7:
--   * bounded immutable interning removes repeated scalar/layer/string allocations
--   * direct layer-1 add/sub/compare avoids generic magnitude helpers
--   * compatibility inputs still preserve the classic API/representation

local function canonicalOrNormalize(value)
	if type(value) == "table" and CANONICAL[value] then
		return value
	end
	return normalize(value)
end

local function numericCmp(a, b)
	if a ~= a or b ~= b then
		return NAN
	elseif a < b then
		return -1
	elseif a > b then
		return 1
	end
	return 0
end

function OmegaNum.correct(value)
	return canonicalOrNormalize(value)
end

function OmegaNum.fromNumber(value)
	if type(value) ~= "number" then
		return NAN_OMEGA
	end
	return fromNumberRaw(value)
end

function OmegaNum.toNumber(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "table" and CANONICAL[value] then
		return toNumberRaw(value)
	end
	return toNumberRaw(normalize(value))
end

function OmegaNum.fromString(str)
	return fromStringRaw(str)
end

function OmegaNum.toOmega(value)
	return canonicalOrNormalize(value)
end

function OmegaNum.toString(value)
	local x = canonicalOrNormalize(value)
	if x == NAN_OMEGA then
		return "[null]"
	end
	local data = copyArray(x[2])
	data[1] = data[1] * x[1]
	return HttpService:JSONEncode(data)
end

function OmegaNum.cmp(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return numericCmp(a, b)
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return cmpRaw(a, b)
	end

	return cmpRaw(normalize(a), normalize(b))
end

function OmegaNum.eq(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return a == a and b == b and a == b
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return eqRaw(a, b)
	end

	return eqRaw(normalize(a), normalize(b))
end

function OmegaNum.le(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return a == a and b == b and a < b
	end

	local c
	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		c = cmpRaw(a, b)
	else
		c = cmpRaw(normalize(a), normalize(b))
	end

	return c == c and c < 0
end

function OmegaNum.me(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return a == a and b == b and a > b
	end

	local c
	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		c = cmpRaw(a, b)
	else
		c = cmpRaw(normalize(a), normalize(b))
	end

	return c == c and c > 0
end

function OmegaNum.meeq(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return a == a and b == b and a >= b
	end

	local c
	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		c = cmpRaw(a, b)
	else
		c = cmpRaw(normalize(a), normalize(b))
	end

	return c == c and c >= 0
end

function OmegaNum.leeq(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		return a == a and b == b and a <= b
	end

	local c
	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		c = cmpRaw(a, b)
	else
		c = cmpRaw(normalize(a), normalize(b))
	end

	return c == c and c <= 0
end

OmegaNum.lt = OmegaNum.le
OmegaNum.gt = OmegaNum.me
OmegaNum.gte = OmegaNum.meeq
OmegaNum.lte = OmegaNum.leeq

function OmegaNum.abs(value)
	local kind = type(value)

	if kind == "number" then
		return fromNumberRaw(math.abs(value))
	end
	if kind == "table" and CANONICAL[value] then
		return absRaw(value)
	end
	return absRaw(normalize(value))
end

function OmegaNum.neg(value)
	local kind = type(value)

	if kind == "number" then
		return fromNumberRaw(-value)
	end
	if kind == "table" and CANONICAL[value] then
		return negRaw(value)
	end
	return negRaw(normalize(value))
end

function OmegaNum.max(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if a ~= a or b ~= b then
			return NAN_OMEGA
		end
		return fromNumberRaw(a >= b and a or b)
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return maxRaw(a, b)
	end

	return maxRaw(normalize(a), normalize(b))
end

function OmegaNum.min(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if a ~= a or b ~= b then
			return NAN_OMEGA
		end
		return fromNumberRaw(a <= b and a or b)
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return minRaw(a, b)
	end

	return minRaw(normalize(a), normalize(b))
end

function OmegaNum.maxabs(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		local aa = math.abs(a)
		local bb = math.abs(b)
		if aa ~= aa or bb ~= bb then
			return NAN_OMEGA
		end
		return fromNumberRaw(aa >= bb and aa or bb)
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return maxAbsRaw(a, b)
	end

	return maxAbsRaw(normalize(a), normalize(b))
end

function OmegaNum.add(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" then
		if tb == "number" then
			return fromNumberRaw(a + b)
		elseif tb == "table" and CANONICAL[b] then
			return addRaw(fromNumberRaw(a), b)
		end
	elseif ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return addRaw(a, b)
		elseif tb == "number" then
			return addRaw(a, fromNumberRaw(b))
		end
	end

	return addRaw(normalize(a), normalize(b))
end

function OmegaNum.sub(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" then
		if tb == "number" then
			return fromNumberRaw(a - b)
		elseif tb == "table" and CANONICAL[b] then
			return subRaw(fromNumberRaw(a), b)
		end
	elseif ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return subRaw(a, b)
		elseif tb == "number" then
			return subRaw(a, fromNumberRaw(b))
		end
	end

	return subRaw(normalize(a), normalize(b))
end

function OmegaNum.mul(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" then
		if tb == "number" then
			return fromNumberRaw(a * b)
		elseif tb == "table" and CANONICAL[b] then
			return mulRaw(fromNumberRaw(a), b)
		end
	elseif ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return mulRaw(a, b)
		elseif tb == "number" then
			return mulRaw(a, fromNumberRaw(b))
		end
	end

	return mulRaw(normalize(a), normalize(b))
end

function OmegaNum.div(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if b == 0 or a ~= a or b ~= b then
			return NAN_OMEGA
		end
		return fromNumberRaw(a / b)
	end

	if ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return divRaw(a, b)
		elseif tb == "number" then
			return divRaw(a, fromNumberRaw(b))
		end
	elseif ta == "number" and tb == "table" and CANONICAL[b] then
		return divRaw(fromNumberRaw(a), b)
	end

	return divRaw(normalize(a), normalize(b))
end

function OmegaNum.recip(value)
	local kind = type(value)

	if kind == "number" then
		if value == 0 or value ~= value then
			return NAN_OMEGA
		elseif value == INF or value == -INF then
			return ZERO
		end
		return fromNumberRaw(1 / value)
	end

	if kind == "table" and CANONICAL[value] then
		return recipRaw(value)
	end

	return recipRaw(normalize(value))
end

function OmegaNum.mod(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if b == 0 or a ~= a or b ~= b or a == INF or a == -INF or b == INF or b == -INF then
			return NAN_OMEGA
		end
		return fromNumberRaw(a % b)
	end

	if ta == "table" and tb == "table" and CANONICAL[a] and CANONICAL[b] then
		return modRaw(a, b)
	end

	return modRaw(normalize(a), normalize(b))
end

function OmegaNum.pow(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if a ~= a or b ~= b then
			return NAN_OMEGA
		elseif b == 0 then
			return ONE
		elseif a == 0 then
			return b < 0 and NAN_OMEGA or ZERO
		elseif a < 0 and (b ~= math.floor(b) or math.abs(b) > MAX_SAFE) then
			return NAN_OMEGA
		end

		local n = a ^ b
		if n == n and n ~= INF and n ~= -INF then
			return fromNumberRaw(n)
		end

		return powRaw(fromNumberRaw(a), fromNumberRaw(b))
	end

	if ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return powRaw(a, b)
		elseif tb == "number" then
			return powRaw(a, fromNumberRaw(b))
		end
	elseif ta == "number" and tb == "table" and CANONICAL[b] then
		return powRaw(fromNumberRaw(a), b)
	end

	return powRaw(normalize(a), normalize(b))
end

function OmegaNum.root(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta == "number" and tb == "number" then
		if b == 0 or a ~= a or b ~= b then
			return NAN_OMEGA
		end

		if a >= 0 then
			local n = a ^ (1 / b)
			if n == n and n ~= INF then
				return fromNumberRaw(n)
			end
		elseif b == math.floor(b) and math.abs(b) <= MAX_SAFE and b % 2 ~= 0 then
			local n = (-a) ^ (1 / math.abs(b))
			if b < 0 then
				n = 1 / n
			end
			return fromNumberRaw(-n)
		else
			return NAN_OMEGA
		end

		return rootRaw(fromNumberRaw(a), fromNumberRaw(b))
	end

	if ta == "table" and CANONICAL[a] then
		if tb == "table" and CANONICAL[b] then
			return rootRaw(a, b)
		elseif tb == "number" then
			return rootRaw(a, fromNumberRaw(b))
		end
	elseif ta == "number" and tb == "table" and CANONICAL[b] then
		return rootRaw(fromNumberRaw(a), b)
	end

	return rootRaw(normalize(a), normalize(b))
end

function OmegaNum.sqrt(value)
	local kind = type(value)

	if kind == "number" then
		if value < 0 or value ~= value then
			return NAN_OMEGA
		end
		return fromNumberRaw(math.sqrt(value))
	end

	if kind == "table" and CANONICAL[value] then
		return sqrtRaw(value)
	end

	return sqrtRaw(normalize(value))
end

function OmegaNum.pow10(value)
	local kind = type(value)

	if kind == "number" then
		return fromLog10Raw(1, value)
	end

	if kind == "table" and CANONICAL[value] then
		return pow10Raw(value)
	end

	return pow10Raw(normalize(value))
end

function OmegaNum.log10(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value or value < 0 then
			return NAN_OMEGA
		elseif value == 0 then
			return NEG_INF
		elseif value == INF then
			return POS_INF
		end
		return fromNumberRaw(math.log10(value))
	end

	if kind == "table" and CANONICAL[value] then
		return log10Raw(value)
	end

	return log10Raw(normalize(value))
end

function OmegaNum.log(value, base)
	if type(value) == "number" and (base == nil or type(base) == "number") then
		local b = base == nil and E or base

		if value > 0 and b > 0 and b ~= 1 and value == value and b == b then
			return fromNumberRaw(math.log(value) / math.log(b))
		end

		return logRaw(fromNumberRaw(value), base == nil and E_OMEGA or fromNumberRaw(b))
	end

	local x = canonicalOrNormalize(value)
	local b = base == nil and E_OMEGA or canonicalOrNormalize(base)
	return logRaw(x, b)
end

function OmegaNum.exp(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			return NAN_OMEGA
		end

		local native = math.exp(value)
		if native ~= INF then
			return fromNumberRaw(native)
		end

		return expRaw(fromNumberRaw(value))
	end

	if kind == "table" and CANONICAL[value] then
		return expRaw(value)
	end

	return expRaw(normalize(value))
end

function OmegaNum.isint(value)
	local kind = type(value)

	if kind == "number" then
		return value == value and value ~= INF and value ~= -INF and value == math.floor(value)
	end

	if kind == "table" and CANONICAL[value] then
		return isIntRaw(value)
	end

	return isIntRaw(normalize(value))
end

function OmegaNum.floor(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			return NAN_OMEGA
		elseif value == INF then
			return POS_INF
		elseif value == -INF then
			return NEG_INF
		end
		return fromNumberRaw(math.floor(value))
	end

	if kind == "table" and CANONICAL[value] then
		return floorRaw(value)
	end

	return floorRaw(normalize(value))
end

function OmegaNum.ceil(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			return NAN_OMEGA
		elseif value == INF then
			return POS_INF
		elseif value == -INF then
			return NEG_INF
		end
		return fromNumberRaw(math.ceil(value))
	end

	if kind == "table" and CANONICAL[value] then
		return ceilRaw(value)
	end

	return ceilRaw(normalize(value))
end

function OmegaNum.gamma(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			return NAN_OMEGA
		end

		if value ~= INF and value ~= -INF and value <= 171 then
			if value >= 1 and value == math.floor(value) then
				return fromNumberRaw(FACTORIAL_CACHE[value])
			end
			return fromNumberRaw(nativeGamma(value))
		end

		return gammaRaw(fromNumberRaw(value))
	end

	if kind == "table" and CANONICAL[value] then
		return gammaRaw(value)
	end

	return gammaRaw(normalize(value))
end

function OmegaNum.fact(value)
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			return NAN_OMEGA
		end

		if value >= 0 and value <= 170 and value == math.floor(value) then
			return fromNumberRaw(FACTORIAL_CACHE[value + 1])
		end

		return factRaw(fromNumberRaw(value))
	end

	if kind == "table" and CANONICAL[value] then
		return factRaw(value)
	end

	return factRaw(normalize(value))
end

function OmegaNum.rand(minimum, maximum)
	if type(minimum) == "number" and type(maximum) == "number" then
		return fromNumberRaw(minimum + (maximum - minimum) * math.random())
	end

	local min
	local max

	if type(minimum) == "table" and type(maximum) == "table" and CANONICAL[minimum] and CANONICAL[maximum] then
		min = minimum
		max = maximum
	else
		min = normalize(minimum)
		max = normalize(maximum)
	end

	local t = fromNumberRaw(math.random())
	return addRaw(min, mulRaw(subRaw(max, min), t))
end

function OmegaNum.exporand(minimum, maximum)
	if type(minimum) == "number" and type(maximum) == "number" and minimum > 0 and maximum > 0 then
		local lo = math.log(minimum)
		local hi = math.log(maximum)
		return fromNumberRaw(math.exp(lo + (hi - lo) * math.random()))
	end

	local min
	local max

	if type(minimum) == "table" and type(maximum) == "table" and CANONICAL[minimum] and CANONICAL[maximum] then
		min = minimum
		max = maximum
	else
		min = normalize(minimum)
		max = normalize(maximum)
	end

	local logMin = logRaw(min, E_OMEGA)
	local logMax = logRaw(max, E_OMEGA)
	local span = subRaw(logMax, logMin)
	local offset = mulRaw(span, fromNumberRaw(math.random()))
	return powRaw(E_OMEGA, addRaw(logMin, offset))
end

function OmegaNum.lambertw(value)
	local kind = type(value)

	if kind == "number" then
		return fromNumberRaw(nativeLambertW(value))
	end

	local x = canonicalOrNormalize(value)
	local n = toNumberRaw(x)

	if n ~= INF and n ~= -INF then
		return fromNumberRaw(nativeLambertW(n))
	end

	if x[1] < 0 then
		return NAN_OMEGA
	end

	local lnX = logRaw(x, E_OMEGA)
	return subRaw(lnX, logRaw(lnX, E_OMEGA))
end

function OmegaNum.slog(value, base)
	local x = canonicalOrNormalize(value)
	local b

	if base == nil then
		b = TEN
	elseif type(base) == "table" and CANONICAL[base] then
		b = base
	else
		b = normalize(base)
	end

	return slogRaw(x, b)
end

function OmegaNum.tetrate(base, height)
	if type(base) == "table" and type(height) == "table" and CANONICAL[base] and CANONICAL[height] then
		return tetrateRaw(base, height)
	end
	return tetrateRaw(normalize(base), normalize(height))
end

function OmegaNum.pentate(base, height)
	if type(base) == "table" and type(height) == "table" and CANONICAL[base] and CANONICAL[height] then
		return pentateRaw(base, height)
	end
	return pentateRaw(normalize(base), normalize(height))
end

function OmegaNum.arrow(base, arrows, height)
	if type(base) == "table" and type(height) == "table" and CANONICAL[base] and CANONICAL[height] then
		return arrowRaw(base, arrows, height)
	end
	return arrowRaw(normalize(base), arrows, normalize(height))
end

function OmegaNum.eternitytoOmega(num)
	if type(num) ~= "table" then
		return NAN_OMEGA
	end

	local sign = tonumber(num[1]) or 1
	local layer = tonumber(num[2]) or 0
	local payload = tonumber(num[3]) or 0
	return canonicalize(sign, { payload, layer >= 1 and layer or 0 }, true)
end

function OmegaNum.toBigNum(value)
	local x = canonicalOrNormalize(value)
	return toBigNumRaw(x)
end

function OmegaNum.toScientific(value)
	local x = canonicalOrNormalize(value)
	local out = toScientificRaw(x)
	if out ~= nil then
		return out
	end
	return toHyperERaw(x, false)
end

function OmegaNum.toShortScientific(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d <= 2 then
		local out = toScientificRaw(x)
		if out ~= nil then
			return out
		end
	end

	return toHyperERaw(x, true)
end

function OmegaNum.short(value)
	local x = canonicalOrNormalize(value)
	return abbreviateRaw(x)
end

function OmegaNum.toEs(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d > 2 then
		return toHyperERaw(x, false)
	elseif #d == 1 then
		return abbreviateRaw(x)
	elseif d[2] > MAX_ES then
		return toHyperERaw(x, false)
	end

	local sign = x[1] < 0 and "-" or ""
	return sign .. string.rep("e", d[2]) .. tostring(roundDown(d[1], 4))
end

function OmegaNum.toShortEs(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d > 2 then
		return toHyperERaw(x, true)
	elseif #d == 1 then
		return abbreviateRaw(x)
	elseif d[2] > MAX_ES then
		return toHyperERaw(x, true)
	end

	local sign = x[1] < 0 and "-" or ""
	return sign .. string.rep("e", d[2]) .. tostring(roundDown(d[1], 4))
end

function OmegaNum.toEnt(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d > 2 then
		return toHyperERaw(x, false)
	elseif #d == 1 then
		return abbreviateRaw(x)
	end

	local sign = x[1] < 0 and "-" or ""
	return sign .. "E(" .. tostring(d[2]) .. ")" .. tostring(d[1])
end

function OmegaNum.toShortEnt(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d > 2 then
		return toHyperERaw(x, true)
	elseif #d == 1 then
		return abbreviateRaw(x)
	end

	local sign = x[1] < 0 and "-" or ""
	return sign .. "E(" .. abbreviateRaw(fromNumberRaw(d[2])) .. ")" .. abbreviateRaw(fromNumberRaw(d[1]))
end

function OmegaNum.toHyperE(value)
	local x = canonicalOrNormalize(value)
	return toHyperERaw(x, false)
end

function OmegaNum.toShortHyperE(value)
	local x = canonicalOrNormalize(value)
	return toHyperERaw(x, true)
end

function OmegaNum.toDisplay(value)
	local x = canonicalOrNormalize(value)
	local d = x[2]

	if #d <= 2 then
		local out = toScientificRaw(x)
		if out ~= nil then
			return out
		end
	end

	return toHyperERaw(x, false)
end

function OmegaNum.abbreviate(value)
	local x = canonicalOrNormalize(value)
	return abbreviateRaw(x)
end

function OmegaNum.lbencode(value)
	local x = canonicalOrNormalize(value)
	return lbencodeLegacyRaw(x)
end

function OmegaNum.lbdecode(value)
	return lbdecodeLegacyRaw(value)
end

function OmegaNum.lbencodeSafe(value)
	local x = canonicalOrNormalize(value)
	return lbencodeSafeRaw(x)
end

function OmegaNum.lbdecodeSafe(value)
	return lbdecodeSafeRaw(value)
end

-- Trusted mixed-number helpers. These avoid normalize() when one operand is a
-- native Lua number and the other is already a canonical Omega.
local function addNumberRightRaw(a, b)
	return addRaw(a, fromNumberRaw(b))
end

local function subNumberRightRaw(a, b)
	return subRaw(a, fromNumberRaw(b))
end

local function mulNumberRightRaw(a, b)
	return mulRaw(a, fromNumberRaw(b))
end

local function divNumberRightRaw(a, b)
	return divRaw(a, fromNumberRaw(b))
end

local function powNumberRightRaw(a, b)
	return powRaw(a, fromNumberRaw(b))
end

local function rootNumberRightRaw(a, b)
	return rootRaw(a, fromNumberRaw(b))
end

-- Trusted hot-path API ---------------------------------------------------------
-- Inputs must already be valid for the selected operation. Canonical Omega
-- arguments must have been produced by this module.
OmegaNum.fast = {
	fromNumber = fromNumberRaw,
	fromLog10 = fromLog10Raw,
	toNumber = toNumberRaw,

	add = addRaw,
	sub = subRaw,
	mul = mulRaw,
	div = divRaw,
	mod = modRaw,
	pow = powRaw,
	root = rootRaw,
	recip = recipRaw,

	cmp = cmpRaw,
	eq = eqRaw,
	max = maxRaw,
	min = minRaw,
	maxabs = maxAbsRaw,

	abs = absRaw,
	neg = negRaw,
	sqrt = sqrtRaw,
	exp = expRaw,
	log = logRaw,
	log10 = log10Raw,
	pow10 = pow10Raw,
	isint = isIntRaw,
	floor = floorRaw,
	ceil = ceilRaw,

	addNumber = addNumberRightRaw,
	subNumber = subNumberRightRaw,
	mulNumber = mulNumberRightRaw,
	divNumber = divNumberRightRaw,
	powNumber = powNumberRightRaw,
	rootNumber = rootNumberRightRaw,

	gamma = gammaRaw,
	fact = factRaw,
	slog = slogRaw,
	tetrate = tetrateRaw,
	pentate = pentateRaw,
}

-- Compatibility aliases -------------------------------------------------------

function OmegaNum.onflt(onum)
	return OmegaNum.toNumber(onum)
end

function OmegaNum.flton(flt)
	return OmegaNum.toOmega(flt)
end

function OmegaNum.onstr(onum)
	return OmegaNum.toString(onum)
end

function OmegaNum.stron(str)
	return OmegaNum.toOmega(str)
end

function OmegaNum.equal(a, b)
	return OmegaNum.eq(a, b)
end

function OmegaNum.moreequal(a, b)
	return OmegaNum.meeq(a, b)
end

function OmegaNum.lessequal(a, b)
	return OmegaNum.leeq(a, b)
end

function OmegaNum.more(a, b)
	return OmegaNum.me(a, b)
end

function OmegaNum.less(a, b)
	return OmegaNum.le(a, b)
end

return OmegaNum
