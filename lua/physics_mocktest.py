# Offline check of BodySlider's physics section: runs it against fake UE objects, asserts the edits and re-init.
import re, sys, lupa.lua54 as L
src = open(sys.argv[1] if len(sys.argv) > 1 else 'main.lua', encoding='utf-8').read()
sec = re.search(r'-{10,} physics \(jiggle.*?(?=-{10,} keys)', src, re.S).group(0)
r = L.LuaRuntime()
r.execute(r'''
vals = { lily = { jiggle = 2.0, hair = 4.0, breast = 2.0 } }
function get(c, s) return (vals[c] and vals[c][s]) or (s == "bounce" and 0) or 1.0 end
function charOf(m) return "lily" end
function FName(s) return { ToString = function() return s end } end
function log(s) print(s) end
local function arr(t) return { ForEach = function(_, fn) for i, v in ipairs(t) do fn(i, { get = function() return v end }) end end } end
local function lim(k, d) return { Stiffness = k, Damping = d } end
local function obj(addr) return { IsValid = function() return true end, GetAddress = function() return addr end } end
B1 = { BoneName = FName("Breast1_L"), DefaultInstance = { LinearDamping = 5, AngularDamping = 5, MassInKgOverride = 10, bOverrideMass = true } }
H1 = { BoneName = FName("Hair_Ponytail1"), DefaultInstance = { LinearDamping = 30, AngularDamping = 30, MassInKgOverride = 10, bOverrideMass = true } }
J1 = { DefaultInstance = { ConstraintBone1 = FName("Breast1_L"), ProfileInstance = { ConeLimit = lim(100, 10), TwistLimit = lim(100, 50),
     LinearLimit = { XMotion = 2, YMotion = 2, ZMotion = 2, Limit = 0, Stiffness = 0, Damping = 0, bSoftConstraint = false } } } }
BT1 = { BoneName = FName("Helper_Skin_Butt_Base_L"), DefaultInstance = { LinearDamping = 6, AngularDamping = 3, MassInKgOverride = 2, bOverrideMass = true, bEnableGravity = false } }
pa = obj(1); pa.GetFullName = function() return "PhysicsAsset /Game/X.SK_X_PHYS" end; pa.SkeletalBodySetups = arr({ B1, H1, BT1 }); pa.ConstraintSetup = arr({ J1 })
reinits = 0
comp = obj(2); comp.PhysicsAssetOverride = pa; comp.SkeletalMesh = obj(3)
comp.GetBoneIndex = function() return 1 end
comp.SetPhysicsAsset = function() reinits = reinits + 1 end
function FindAllOf() return { comp } end
''')
r.execute(sec + '\n_G.physicsPass = physicsPass')
g = r.globals()
g.physicsPass()
chk = r.eval('{B1.DefaultInstance.LinearDamping, B1.DefaultInstance.MassInKgOverride, H1.DefaultInstance.AngularDamping, J1.DefaultInstance.ProfileInstance.ConeLimit.Stiffness, reinits}')
got = [chk[i] for i in range(1, 6)]
print('after 1st pass', got)
assert got == [10, 20, 120, 200, 1], got  # jiggle 2 -> x2, hair 4 -> x4
g.physicsPass()
assert r.eval('reinits') == 1, 'no re-init when nothing changed'
r.execute('vals.lily.jiggle = 1.0')
g.physicsPass()
assert r.eval('J1.DefaultInstance.ProfileInstance.ConeLimit.Stiffness') == 100, 'back to stock, not compounding'
assert r.eval('reinits') == 2
LL = 'J1.DefaultInstance.ProfileInstance.LinearLimit'
assert r.eval(LL + '.XMotion') == 2, 'bounce 0 leaves the joint locked'
r.execute('vals.lily.bounce = 2.0'); g.physicsPass()
assert r.eval(LL + '.XMotion') == 1 and r.eval(LL + '.Stiffness') == 490 and r.eval(LL + '.bSoftConstraint') == True, 'bounce 2 cm -> k 490'
assert r.eval('reinits') == 3
assert r.eval('BT1.DefaultInstance.bEnableGravity') == True, 'bounce on -> butt gravity'
r.execute('vals.lily.bounce = 0'); g.physicsPass()
assert r.eval('BT1.DefaultInstance.bEnableGravity') == False, 'bounce off -> stock weightless butt'
assert r.eval(LL + '.XMotion') == 2 and r.eval(LL + '.Stiffness') == 0 and r.eval(LL + '.bSoftConstraint') == False, 'bounce off -> stock'
print('PHYSICS MOCK OK')
