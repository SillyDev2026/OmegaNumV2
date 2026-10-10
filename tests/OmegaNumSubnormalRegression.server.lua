--!strict
local Omega = require(script.Parent:WaitForChild("OmegaNum"))
assert(Omega.VERSION == "2.4.1")
local smallest = 5e-324
for _, value in {smallest, -smallest, 1e-320, -1e-320, 1e-300, 1e30, -1234.5} do
    local output = Omega.toBigNum(value)
    assert(type(output) == "table" and type(output[1]) == "number" and type(output[2]) == "number")
    assert(output[1] == output[1] and math.abs(output[1]) < math.huge, "Nonfinite mantissa for " .. tostring(value))
    assert(math.abs(output[1]) >= 1 and math.abs(output[1]) < 10, "Not normalized: " .. tostring(value))
    assert(output[2] == output[2] and math.abs(output[2]) < math.huge)
end
local zero = Omega.toBigNum(0)
assert(zero[1] == 0 and zero[2] == 0)
print("OmegaNum v2.4.1 scientific regression PASS")
