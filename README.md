# OmegaNum

**OmegaNum v1.0.0** is a high-performance huge-number library for Roblox Luau.

It is designed for simulators, incremental games, clickers, tycoons, and other systems that need numbers far beyond normal Lua `number` range while keeping common arithmetic and comparisons fast.

```text
VERSION      1.0.0
API_VERSION  2
PERF_VERSION 7
LB_VERSION   1
SAFE_LB      2
```

## Highlights

- Native Luau optimization with `--!native` and `--!optimize 2`
- Fast native-number paths
- Fast canonical Omega-to-Omega arithmetic
- Huge scientific and repeated-`e` values
- Hyper operations: tetration, pentation, and Knuth-style arrows
- Comparison functions with direct numeric fast paths
- Formatting for scientific, `e`, Eternity-style, Hyper-E, and abbreviations
- Gamma, factorial, Lambert W, logarithms, roots, and exponentials
- Legacy OmegaNum/BigNum-compatible input normalization
- Bounded immutable result caching for repeated hot values
- Optional `OmegaNum.fast` API for trusted hot loops
- Non-mutating formatting and serialization
- Representation compatible with classic OmegaNum-style tables

---

## Installation

Place the module in `ReplicatedStorage`:

```text
ReplicatedStorage
└── OmegaNum
```

Then require it:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OmegaNum = require(ReplicatedStorage.OmegaNum)
```

---

## Quick Start

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OmegaNum = require(ReplicatedStorage.OmegaNum)

local clicks = OmegaNum.fromNumber(1_000)
local multiplier = OmegaNum.fromNumber(25)

clicks = OmegaNum.mul(clicks, multiplier)

print(OmegaNum.toDisplay(clicks))
```

You can also pass native numbers directly to the normal public API:

```lua
local result = OmegaNum.add(100, 250)

print(OmegaNum.toNumber(result))
-- 350
```

---

# Representation

OmegaNum keeps the classic representation:

```lua
{
	sign,
	{
		payload,
		layer1,
		layer2,
		...
	}
}
```

For example, conceptually:

```lua
{ 1, { 100 } }
```

represents an ordinary positive scalar.

A larger value may use exponential layers:

```lua
{ 1, { 1000, 1 } }
```

The exact representation should normally be treated as an implementation detail.

## Important: OmegaNum Values Are Immutable

Values returned by OmegaNum should be treated as immutable.

Do **not** modify their tables manually:

```lua
-- Do not do this:
local x = OmegaNum.fromNumber(100)
x[2][1] = 999
```

Instead create a new result:

```lua
local x = OmegaNum.fromNumber(100)
x = OmegaNum.add(x, 899)
```

This is especially important in v2.4 because the performance system may safely reuse immutable results.

---

# Constants

OmegaNum exposes common constants:

```lua
OmegaNum.ZERO
OmegaNum.ONE
OmegaNum.NAN
OmegaNum.INF
```

Example:

```lua
if OmegaNum.eq(value, OmegaNum.ZERO) then
	print("Value is zero")
end
```

---

# Creating Values

## `fromNumber`

```lua
local value = OmegaNum.fromNumber(123456)
```

```lua
local hugeNative = OmegaNum.fromNumber(1e300)
```

## `fromString`

```lua
local value = OmegaNum.fromString("123456789")
```

Scientific notation:

```lua
local huge = OmegaNum.fromString("1e1000")
```

Repeated-E notation:

```lua
local massive = OmegaNum.fromString("ee100")
```

## `toOmega`

Normalizes a supported value into OmegaNum form:

```lua
local a = OmegaNum.toOmega(100)
local b = OmegaNum.toOmega("1e500")
```

The compatibility API can normalize supported native numbers, strings, Omega-style tables, and legacy BigNum-style pairs.

## `correct`

```lua
local value = OmegaNum.correct(input)
```

Normalizes/canonicalizes a compatible input.

---

# Converting Values

## `toNumber`

```lua
local x = OmegaNum.fromNumber(500)
local n = OmegaNum.toNumber(x)

print(n)
-- 500
```

Values too large for a native Lua number may convert to infinity.

## `toString`

```lua
local encoded = OmegaNum.toString(value)
```

Produces OmegaNum's JSON-compatible serialized data representation.

## `toBigNum`

```lua
local bigNumPair = OmegaNum.toBigNum(value)
```

Returns a classic mantissa/exponent-style pair when representable.

---

# Arithmetic

All arithmetic functions return an OmegaNum value.

## Addition

```lua
local result = OmegaNum.add(a, b)
```

Example:

```lua
local clicks = OmegaNum.fromString("1e100")
clicks = OmegaNum.add(clicks, "1e50")
```

## Subtraction

```lua
local result = OmegaNum.sub(a, b)
```

## Multiplication

```lua
local result = OmegaNum.mul(a, b)
```

## Division

```lua
local result = OmegaNum.div(a, b)
```

Division by zero returns `OmegaNum.NAN`.

## Reciprocal

```lua
local result = OmegaNum.recip(value)
```

Equivalent to:

```text
1 / value
```

## Modulo

```lua
local result = OmegaNum.mod(a, b)
```

## Absolute Value

```lua
local result = OmegaNum.abs(value)
```

## Negation

```lua
local result = OmegaNum.neg(value)
```

## Minimum / Maximum

```lua
local smallest = OmegaNum.min(a, b)
local largest = OmegaNum.max(a, b)
local largestMagnitude = OmegaNum.maxabs(a, b)
```

---

# Comparisons

## Three-Way Compare

```lua
local comparison = OmegaNum.cmp(a, b)
```

Returns:

```text
-1  a < b
 0  a == b
 1  a > b
NaN invalid comparison
```

## Equality

```lua
OmegaNum.eq(a, b)
```

## Less Than

Preferred alias:

```lua
OmegaNum.lt(a, b)
```

Original API name:

```lua
OmegaNum.le(a, b)
```

## Less Than or Equal

```lua
OmegaNum.lte(a, b)
```

Original API name:

```lua
OmegaNum.leeq(a, b)
```

## Greater Than

```lua
OmegaNum.gt(a, b)
```

Original API name:

```lua
OmegaNum.me(a, b)
```

## Greater Than or Equal

```lua
OmegaNum.gte(a, b)
```

Original API name:

```lua
OmegaNum.meeq(a, b)
```

Example:

```lua
local cost = OmegaNum.fromString("1e100")
local clicks = OmegaNum.fromString("1e120")

if OmegaNum.gte(clicks, cost) then
	clicks = OmegaNum.sub(clicks, cost)
	print("Purchased!")
end
```

---

# Powers, Roots, and Logs

## Power

```lua
local value = OmegaNum.pow(10, 1000)
```

## Root

```lua
local value = OmegaNum.root(1e12, 3)
```

## Square Root

```lua
local value = OmegaNum.sqrt(144)
```

## Power of 10

```lua
local value = OmegaNum.pow10(1000)
```

Conceptually:

```text
10^1000
```

## Base-10 Logarithm

```lua
local result = OmegaNum.log10(value)
```

## Arbitrary Logarithm

```lua
local result = OmegaNum.log(value, base)
```

Natural logarithm:

```lua
local result = OmegaNum.log(value)
```

## Exponential

```lua
local result = OmegaNum.exp(value)
```

Conceptually:

```text
e^value
```

---

# Integer Operations

## Integer Check

```lua
local isInteger = OmegaNum.isint(value)
```

## Floor

```lua
local result = OmegaNum.floor(value)
```

## Ceiling

```lua
local result = OmegaNum.ceil(value)
```

---

# Advanced Math

## Factorial

```lua
local value = OmegaNum.fact(100)
```

Small native integer factorials use an internal cache.

## Gamma

```lua
local value = OmegaNum.gamma(10)
```

## Lambert W

```lua
local value = OmegaNum.lambertw(1)
```

## Super-Logarithm

```lua
local value = OmegaNum.slog(x, 10)
```

The base defaults to `10` when omitted:

```lua
local value = OmegaNum.slog(x)
```

---

# Hyper Operations

OmegaNum supports values beyond ordinary exponentiation.

## Tetration

```lua
local value = OmegaNum.tetrate(10, 3)
```

Conceptually:

```text
10 ↑↑ 3
```

## Pentation

```lua
local value = OmegaNum.pentate(10, 3)
```

Conceptually:

```text
10 ↑↑↑ 3
```

## Arrow

```lua
local value = OmegaNum.arrow(base, arrows, height)
```

Examples:

```lua
local exponentiation = OmegaNum.arrow(10, 1, 100)
local tetration = OmegaNum.arrow(10, 2, 3)
local pentation = OmegaNum.arrow(10, 3, 3)
```

The current symbolic arrow representation supports arrow counts up to the module's configured internal limit.

---

# Random Values

## Uniform Random

```lua
local value = OmegaNum.rand(minimum, maximum)
```

Example:

```lua
local roll = OmegaNum.rand(1, 100)
```

## Exponential Random

Useful when the range spans many orders of magnitude:

```lua
local value = OmegaNum.exporand(1, 1e100)
```

---

# Formatting

OmegaNum contains multiple formatting systems.

## Display

Recommended general-purpose formatter:

```lua
print(OmegaNum.toDisplay(value))
```

## Abbreviation

```lua
print(OmegaNum.abbreviate(value))
```

Alias:

```lua
print(OmegaNum.short(value))
```

## Scientific

```lua
print(OmegaNum.toScientific(value))
```

Short scientific:

```lua
print(OmegaNum.toShortScientific(value))
```

## Repeated-E

```lua
print(OmegaNum.toEs(value))
```

Short version:

```lua
print(OmegaNum.toShortEs(value))
```

## Eternity-Style

```lua
print(OmegaNum.toEnt(value))
```

Short version:

```lua
print(OmegaNum.toShortEnt(value))
```

## Hyper-E

```lua
print(OmegaNum.toHyperE(value))
```

Short version:

```lua
print(OmegaNum.toShortHyperE(value))
```

### Example

```lua
local value = OmegaNum.fromString("1e1000")

print(OmegaNum.toScientific(value))
print(OmegaNum.toEs(value))
print(OmegaNum.toEnt(value))
print(OmegaNum.toHyperE(value))
print(OmegaNum.toDisplay(value))
```

---

# LB Encoding

Legacy encoding:

```lua
local encoded = OmegaNum.lbencode(value)
local decoded = OmegaNum.lbdecode(encoded)
```

Safe encoding:

```lua
local encoded = OmegaNum.lbencodeSafe(value)
local decoded = OmegaNum.lbdecodeSafe(encoded)
```

Versions:

```lua
print(OmegaNum.LB_VERSION)
print(OmegaNum.SAFE_LB_VERSION)
```

---

# Eternity Conversion

Convert an Eternity-style triple into OmegaNum:

```lua
local value = OmegaNum.eternitytoOmega({
	1,
	1,
	1000,
})
```

The input is interpreted as:

```text
{ sign, layer, payload }
```

---

# High-Performance API

OmegaNum v2.4 exposes:

```lua
OmegaNum.fast
```

This API skips normal compatibility normalization and some public validation.

Use it only when the Omega arguments were already created by the **same OmegaNum module**.

## Example

```lua
local a = OmegaNum.fromString("1e100")
local b = OmegaNum.fromString("1e50")

local result = OmegaNum.fast.mul(a, b)
```

This is intended for very hot loops where the values are already canonical.

## Core Fast Functions

```lua
OmegaNum.fast.fromNumber
OmegaNum.fast.fromLog10
OmegaNum.fast.toNumber

OmegaNum.fast.add
OmegaNum.fast.sub
OmegaNum.fast.mul
OmegaNum.fast.div
OmegaNum.fast.mod
OmegaNum.fast.pow
OmegaNum.fast.root
OmegaNum.fast.recip

OmegaNum.fast.cmp
OmegaNum.fast.eq
OmegaNum.fast.max
OmegaNum.fast.min
OmegaNum.fast.maxabs

OmegaNum.fast.abs
OmegaNum.fast.neg
OmegaNum.fast.sqrt
OmegaNum.fast.exp
OmegaNum.fast.log
OmegaNum.fast.log10
OmegaNum.fast.pow10
OmegaNum.fast.isint
OmegaNum.fast.floor
OmegaNum.fast.ceil

OmegaNum.fast.gamma
OmegaNum.fast.fact
OmegaNum.fast.slog
OmegaNum.fast.tetrate
OmegaNum.fast.pentate
```

---

# Mixed Omega + Number Fast Paths

For a canonical Omega value and a native number:

```lua
OmegaNum.fast.addNumber(value, number)
OmegaNum.fast.subNumber(value, number)
OmegaNum.fast.mulNumber(value, number)
OmegaNum.fast.divNumber(value, number)
OmegaNum.fast.powNumber(value, number)
OmegaNum.fast.rootNumber(value, number)
```

Example:

```lua
local clicks = OmegaNum.fromString("1e100")

clicks = OmegaNum.fast.mulNumber(clicks, 25)
clicks = OmegaNum.fast.addNumber(clicks, 100)
```

These are useful in simulators where one side of the operation is frequently a small native multiplier, exponent, or cost adjustment.

---

# Normal API vs Fast API

Use the normal API by default:

```lua
OmegaNum.mul(a, b)
```

It accepts compatibility inputs and performs the necessary normalization.

Use the fast API only when inputs are trusted:

```lua
OmegaNum.fast.mul(a, b)
```

### Good

```lua
local a = OmegaNum.fromString("1e100")
local b = OmegaNum.fromString("1e50")

local c = OmegaNum.fast.add(a, b)
```

### Do Not Do This

```lua
OmegaNum.fast.add("1e100", "1e50")
```

The fast API expects canonical Omega values, not arbitrary strings or legacy/raw input forms.

---

# Performance Design

OmegaNum v2.4 focuses on keeping common gameplay paths away from generic normalization.

Important optimizations include:

- Native `number + number` arithmetic lanes
- Direct native comparison lanes
- Canonical Omega-to-Omega arithmetic
- Scalar-specific comparison and arithmetic
- Layer-1 scientific arithmetic
- Mixed canonical-Omega/native-number paths
- Cached common constants
- Bounded immutable result interning
- Cached small factorials
- Direct logarithm/power paths where possible
- Compatibility normalization kept outside trusted arithmetic paths

The public representation remains compatible:

```lua
{ sign, { data... } }
```

while the implementation attempts to avoid rebuilding that representation unnecessarily.

---

# Benchmarking

For reliable Roblox Studio benchmarks:

1. Use `--!native`.
2. Use `--!optimize 2`.
3. Warm both modules before measuring.
4. Benchmark in chunks so Studio does not hit the script timeout.
5. Yield **outside** the timed region.
6. Alternate old/new execution order.
7. Use several samples and compare the median.
8. Test hot repeated values separately from cold/changing values.

Example benchmark idea:

```lua
local ITERATIONS = 500_000
local clock = os.clock

local a = OmegaNum.fromNumber(123456)
local b = OmegaNum.fromNumber(654321)

local start = clock()

for _ = 1, ITERATIONS do
	OmegaNum.fast.add(a, b)
end

local elapsed = clock() - start
local nsPerOp = elapsed / ITERATIONS * 1e9

print(string.format("%.3f ns/op", nsPerOp))
```

For serious comparisons, use the included dedicated v2.4 benchmark instead of relying on a single loop.

---

# Clicker / Simulator Example

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OmegaNum = require(ReplicatedStorage.OmegaNum)

local clicks = OmegaNum.fromNumber(0)
local clickPower = OmegaNum.fromNumber(1)
local rebirthMultiplier = OmegaNum.fromNumber(1)

local function click()
	local gain = OmegaNum.fast.mul(clickPower, rebirthMultiplier)
	clicks = OmegaNum.fast.add(clicks, gain)

	print("Clicks:", OmegaNum.toDisplay(clicks))
end

local function canAfford(cost)
	return OmegaNum.gte(clicks, cost)
end

local function purchase(cost)
	if not canAfford(cost) then
		return false
	end

	clicks = OmegaNum.sub(clicks, cost)
	return true
end

local upgradeCost = OmegaNum.fromString("1e100")

click()

if purchase(upgradeCost) then
	print("Upgrade purchased")
end
```

---

# Very Large Values

Native Lua numbers eventually overflow around the normal floating-point limit.

OmegaNum can continue representing much larger structures:

```lua
local a = OmegaNum.fromString("1e1000")
local b = OmegaNum.fromString("ee100")
local c = OmegaNum.tetrate(10, 10)

print(OmegaNum.toDisplay(a))
print(OmegaNum.toDisplay(b))
print(OmegaNum.toDisplay(c))
```

At extreme hyper-operation ranges, OmegaNum uses its layered/symbolic representation rather than attempting to expand the actual numeric value.

---

# NaN and Infinity

Constants:

```lua
OmegaNum.NAN
OmegaNum.INF
```

Examples that may produce NaN include invalid operations such as:

```lua
OmegaNum.div(1, 0)
OmegaNum.sqrt(-1)
OmegaNum.root(-16, 2)
```

Check equality using OmegaNum's comparison API rather than directly assuming every invalid value behaves like a normal number.

---

# Compatibility Aliases

Older API names remain available:

```lua
OmegaNum.onflt
OmegaNum.flton
OmegaNum.onstr
OmegaNum.stron

OmegaNum.equal
OmegaNum.moreequal
OmegaNum.lessequal
OmegaNum.more
OmegaNum.less
```

Modern equivalents:

| Compatibility | Preferred |
|---|---|
| `onflt(x)` | `toNumber(x)` |
| `flton(x)` | `toOmega(x)` |
| `onstr(x)` | `toString(x)` |
| `stron(x)` | `toOmega(x)` |
| `equal(a, b)` | `eq(a, b)` |
| `moreequal(a, b)` | `gte(a, b)` |
| `lessequal(a, b)` | `lte(a, b)` |
| `more(a, b)` | `gt(a, b)` |
| `less(a, b)` | `lt(a, b)` |

---

# API Reference

## Construction / Conversion

| Function | Purpose |
|---|---|
| `correct(value)` | Normalize/canonicalize a compatible value |
| `fromNumber(value)` | Create from a Lua number |
| `fromString(value)` | Parse a string |
| `toOmega(value)` | Normalize into OmegaNum |
| `toNumber(value)` | Convert to native number when possible |
| `toString(value)` | Serialize Omega data |
| `toBigNum(value)` | Convert to mantissa/exponent pair |
| `eternitytoOmega(value)` | Convert Eternity-style representation |

## Arithmetic

| Function | Purpose |
|---|---|
| `add(a, b)` | Addition |
| `sub(a, b)` | Subtraction |
| `mul(a, b)` | Multiplication |
| `div(a, b)` | Division |
| `mod(a, b)` | Modulo |
| `recip(x)` | Reciprocal |
| `abs(x)` | Absolute value |
| `neg(x)` | Negation |
| `min(a, b)` | Minimum |
| `max(a, b)` | Maximum |
| `maxabs(a, b)` | Largest absolute magnitude |

## Comparison

| Function | Purpose |
|---|---|
| `cmp(a, b)` | Three-way comparison |
| `eq(a, b)` | Equal |
| `lt(a, b)` / `le(a, b)` | Less than |
| `lte(a, b)` / `leeq(a, b)` | Less than or equal |
| `gt(a, b)` / `me(a, b)` | Greater than |
| `gte(a, b)` / `meeq(a, b)` | Greater than or equal |

## Powers / Logs

| Function | Purpose |
|---|---|
| `pow(a, b)` | Power |
| `root(a, b)` | Nth root |
| `sqrt(x)` | Square root |
| `pow10(x)` | `10^x` |
| `log10(x)` | Base-10 logarithm |
| `log(x, base?)` | Arbitrary/natural logarithm |
| `exp(x)` | `e^x` |
| `slog(x, base?)` | Super-logarithm |

## Advanced Math

| Function | Purpose |
|---|---|
| `isint(x)` | Integer check |
| `floor(x)` | Floor |
| `ceil(x)` | Ceiling |
| `gamma(x)` | Gamma function |
| `fact(x)` | Factorial |
| `lambertw(x)` | Lambert W |
| `rand(min, max)` | Uniform random |
| `exporand(min, max)` | Log/exponential random |

## Hyper Operations

| Function | Purpose |
|---|---|
| `tetrate(base, height)` | Tetration |
| `pentate(base, height)` | Pentation |
| `arrow(base, arrows, height)` | General arrow operation |

## Formatting

| Function | Purpose |
|---|---|
| `toScientific(x)` | Scientific formatting |
| `toShortScientific(x)` | Compact scientific formatting |
| `short(x)` | Abbreviated display |
| `abbreviate(x)` | Abbreviated display |
| `toEs(x)` | Repeated-E formatting |
| `toShortEs(x)` | Compact repeated-E |
| `toEnt(x)` | Eternity-style formatting |
| `toShortEnt(x)` | Compact Eternity-style |
| `toHyperE(x)` | Hyper-E formatting |
| `toShortHyperE(x)` | Compact Hyper-E |
| `toDisplay(x)` | General display formatter |

## Encoding

| Function | Purpose |
|---|---|
| `lbencode(x)` | Legacy LB encode |
| `lbdecode(x)` | Legacy LB decode |
| `lbencodeSafe(x)` | Safe LB encode |
| `lbdecodeSafe(x)` | Safe LB decode |

---

# Version Information

```lua
print(OmegaNum.VERSION)
print(OmegaNum.API_VERSION)
print(OmegaNum.PERF_VERSION)
print(OmegaNum.LB_VERSION)
print(OmegaNum.SAFE_LB_VERSION)
```

For v2.4:

```text
VERSION          1.0.0
API_VERSION      2
PERF_VERSION     7
LB_VERSION       1
SAFE_LB_VERSION  2
```

---

# Recommended Usage

For most code:

```lua
OmegaNum.add(a, b)
OmegaNum.mul(a, b)
OmegaNum.gte(a, b)
```

For performance-sensitive loops where inputs are already canonical Omega values:

```lua
OmegaNum.fast.add(a, b)
OmegaNum.fast.mul(a, b)
OmegaNum.fast.cmp(a, b)
```

For canonical Omega + native-number operations:

```lua
OmegaNum.fast.mulNumber(a, 10)
OmegaNum.fast.powNumber(a, 2)
```

Keep OmegaNum values immutable and format only when you actually need to display them to the player.

---

## Current Release

**OmegaNum 1.0.0 — PERF v7**
