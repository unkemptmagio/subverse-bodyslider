-- BodySlider (UE4SS Lua side): finds heroine meshes, keeps per-character slider values (saved to BodySlider.ini),
-- writes cmd.txt for bodyslider.dll which rescales the bones live. Jiggle/Hair sliders tune the game's PhysX springs.
-- Keys: Num7/Num9 select previous/next character on screen, Num8/Num2 breasts +/-, Num6/Num4 butt +/-,
--       Num5 reset selected character, Num0 or F8 show/hide the on-screen sliders, F10 hide it for screenshots.
--       Size limits: [limits] in BodySlider.ini. Presets 1-3 (panel) are shared by all characters.

local STEP = 0.1
local FINE = { hips = 0.02, waist = 0.02, nipple = 0.05, areola = 0.05, jiggle = 0.05, hair = 0.05, bounce = 0.1,
               cleavage = 0.1, splay = 1, lift = 1 }  -- smaller slider steps
-- per-slider limits; overridden by [limits] in BodySlider.ini (clamped to 0.1-50, the dll accepts 0.2-6 per axis)
local MIN = { breast = 1.0, butt = 1.0, thighs = 0.7, hips = 0.85, waist = 0.8, nipple = 0.5, areola = 0.5, jiggle = 0.25, hair = 0.25, bounce = 0,
              cleavage = -2, splay = -15, lift = -10 }
local MAX = { breast = 3.0, butt = 5.0, thighs = 1.6, hips = 1.25, waist = 1.15, nipple = 2.0, areola = 2.0, jiggle = 10.0, hair = 10.0, bounce = 3.0,
              cleavage = 3, splay = 20, lift = 10 }
local SLIDERS = { "breast", "butt", "thighs", "hips", "waist", "nipple", "areola", "cleavage", "splay", "lift",
                  "jiggle", "bounce", "hair" }
-- panel accordion: one section open at a time
local SECTIONS = {
    { "BODY",    { "breast", "butt", "thighs", "hips", "waist" } },
    { "BREASTS", { "nipple", "areola", "cleavage", "splay", "lift" } },
    { "PHYSICS", { "jiggle", "bounce", "hair" } },
}
local DEFAULT = { bounce = 0, cleavage = 0, splay = 0, lift = 0 }   -- every other slider defaults to 1.0
local UNIT = { bounce = "cm", cleavage = "cm", splay = " deg", lift = " deg" }  -- shown instead of "x"
-- bounce = cm of springy up/down travel for breasts + butt (0 = the game's locked joints)
-- jiggle/hair are physics, not bone scale: they multiply the game's own spring stiffness + damping on those PhysX bodies
local GROUPS = {  -- pivot bones; each scales together with its descendants unless ALONE
    breast = { "Breast1_L", "Breast1_R", "Cloth_Breast1_L", "Cloth_Breast1_R" },
    butt   = { "Helper_Skin_Butt_Base_L", "Helper_Skin_Butt_Base_R" },
    thighs = { "Helper_Skin_Thigh_L", "Helper_Skin_Thigh_R", "Helper_Skin_Quad_L", "Helper_Skin_Quad_R",
               "Helper_Cloth_Thigh_L", "Helper_Cloth_Thigh_R", "Helper_Cloth_Quad_L", "Helper_Cloth_Quad_R" },
    hips   = { "Helper_Skin_Hips", "Helper_Cloth_Hips" },
    waist  = { "Helper_Skin_Spine", "Helper_Skin_Spine1", "Helper_Cloth_Spine", "Helper_Cloth_Spine1" },
    nipple = { "Breast6_L", "Breast6_R", "Cloth_Breast6_L", "Cloth_Breast6_R" },   -- 6+7: last ~1 cm of the breast
    areola = { "Breast5_L", "Breast5_R", "Cloth_Breast5_L", "Cloth_Breast5_R" },   -- 5-7: ~2.5 cm around the tip
}
GROUPS.cleavage, GROUPS.splay, GROUPS.lift = GROUPS.breast, GROUPS.breast, GROUPS.breast
-- rotate/move sliders, in model space about each breast's base bone (+X = her left, +Y = front, +Z = up).
-- side = +1 for _L bones, -1 for _R. Returns rx, ry, rz (deg), tx, ty, tz (cm).
local XFORM = {
    cleavage = function(v, side) return 0, 0, 0, side * v / 2, 0, 0 end,  -- gap grows by v cm
    splay    = function(v, side) return 0, 0, -side * v, 0, 0, 0 end,     -- + = nipples point outward
}
-- per-axis sliders (in the pivot bone's own frame; others are volume, scaled in 3 axes): "v" = the slider value.
-- Biped helpers: X across the body, Y down the leg/spine, Z front-back. Breast chain: Y points out through the nipple.
local AXES = {
    thighs = { "v", 1, "v" }, hips = { "v", 1, 1 }, waist = { "v", 1, "v" },
    nipple = { 1, "v", 1 }, areola = { "v", 1, "v" },
}
local ALONE = { hips = true }  -- Helper_Skin_Hips parents the genital bones: don't widen those with the hips

local function log(s) print("[BodySlider] " .. tostring(s) .. "\n") end

local modDir = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", "")
local cmdPath, iniPath = modDir .. "\\cmd.txt", modDir .. "\\BodySlider.ini"

if package and package.loadlib then
    local ok, err = package.loadlib(modDir .. "\\bodyslider.dll", "*")
    if not ok then log("native dll FAILED: " .. tostring(err)) end
else
    log("package.loadlib not available - dll not loaded")
end

---------------------------------------------------------------- per-character values + ini
local vals = {}  -- vals[char][slider] = number

local function clamp(slider, v) return math.max(MIN[slider], math.min(MAX[slider], v)) end
local function get(char, slider) return clamp(slider, (vals[char] and vals[char][slider]) or DEFAULT[slider] or 1.0) end

local function load()
    local f = io.open(iniPath, "r"); if not f then return end
    local cur
    for line in f:lines() do
        local sec = line:match("^%s*%[(.-)%]%s*$")
        if sec then cur = sec:lower(); if cur ~= "limits" then vals[cur] = vals[cur] or {} end
        elseif cur then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(%-?[%d%.]+)")
            v = tonumber(v)
            if k and v and cur == "limits" then
                local sl, which = k:lower():match("^(%a+)_(%a+)$")
                local t = (which == "min" and MIN) or (which == "max" and MAX)
                if t and t[sl] then t[sl] = math.max(DEFAULT[sl] == 0 and -50 or 0.1, math.min(50, v)) end
            elseif k and v then vals[cur][k] = v end
        end
    end
    f:close()
    for _, sl in ipairs(SLIDERS) do if MIN[sl] >= MAX[sl] then MIN[sl], MAX[sl] = 1.0, 3.0; log(sl .. " limits invalid, using 1.0-3.0") end end
end

local function save()
    local chars = {}
    for c in pairs(vals) do chars[#chars + 1] = c end
    table.sort(chars)
    local out = { "; BodySlider. 1.0 = default. breast/butt are volume (2.0 = twice as big); the others scale width or length.",
                  "; [preset1]-[preset3] are the panel presets, shared by all characters.",
                  "; [limits] sets each slider's range (0.1 - 50); edit with the game closed.", "[limits]" }
    for _, sl in ipairs(SLIDERS) do
        out[#out + 1] = string.format("%s_min=%g", sl, MIN[sl]); out[#out + 1] = string.format("%s_max=%g", sl, MAX[sl])
    end
    out[#out + 1] = ""
    out[#out + 1] = "; per-character sizes (written by the game)"
    for _, c in ipairs(chars) do
        local lines = {}
        for _, s in ipairs(SLIDERS) do
            if math.abs(get(c, s) - (DEFAULT[s] or 1.0)) > 1e-3 then lines[#lines + 1] = string.format("%s=%.2f", s, get(c, s)) end
        end
        if #lines > 0 then out[#out + 1] = "[" .. c .. "]"; for _, l in ipairs(lines) do out[#out + 1] = l end end
    end
    local f = io.open(iniPath, "w"); if f then f:write(table.concat(out, "\n") .. "\n"); f:close() end
end

-- "/Game/StudioFow/Characters/Lily/Meshes/SK_Lily_Nude" -> "lily" (Dialogue/Gallery paths use the same folder names)
local function charOf(mesh)
    local name = mesh:GetFullName()
    return (name:match("/Characters/([^/]+)/") or "other"):lower()
end

---------------------------------------------------------------- mesh layout (bone groups), cached per mesh
local layout = {}
local lastCmd = nil
local present = {}     -- sorted list of characters currently visible
local selected = nil   -- character the numpad edits
local menuChar = nil   -- character shown by the Pandora menu preview (sliders edit her there)

local function buildLayout(comp)
    local n = comp:GetNumBones()
    local names, parent, index = {}, {}, {}
    for i = 0, n - 1 do names[i] = comp:GetBoneName(i):ToString(); index[names[i]] = i end
    for i = 0, n - 1 do parent[i] = index[comp:GetParentBone(FName(names[i])):ToString()] or -1 end
    local function descendantsOf(root)
        local out = {}
        for i = 0, n - 1 do
            local p = i
            while p ~= -1 do
                if p == root then out[#out + 1] = i; break end
                p = parent[p]
            end
        end
        return out
    end
    local L = { n = n, slider = {}, names = names, index = index }
    for slider, pivots in pairs(GROUPS) do
        L.slider[slider] = {}
        for _, pv in ipairs(pivots) do
            local pi = index[pv]
            if pi then L.slider[slider][pi] = ALONE[slider] and { pi } or descendantsOf(pi) end
        end
    end
    return L
end

-- Pandora keeps every heroine's preview model loaded and "visible" off-screen, so IsVisible() is useless here.
-- Ask the engine whether the actor was actually drawn recently; fall back to hidden flags if that UFunction is missing.
local HAS_RENDERED = StaticFindObject("/Script/Engine.Actor:WasRecentlyRendered")
HAS_RENDERED = HAS_RENDERED and HAS_RENDERED:IsValid()
local function onScreen(c)
    local actor = c:GetOwner()
    if not (actor and actor:IsValid()) then actor = c:GetOuter() end
    if not (actor and actor:IsValid()) then return false end
    if HAS_RENDERED then return actor:WasRecentlyRendered(0.25) end
    return c:IsVisible() and not actor.bHidden and not c.bHiddenInGame
end

local function rescan()
    -- the dll applies a bone's lines last-to-first: sizes (listed last) reshape the rest pose first, then the
    -- breast moves (gap/splay/lift, listed first) carry the finished shape, so a moved nipple keeps its own size/axis
    local lines, xlines, seen, menu = {}, {}, {}, nil
    for _, c in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
        pcall(function()
            if not c:IsValid() or c:GetBoneIndex(FName("Breast1_L")) < 0 then return end
            local mesh = c.SkeletalMesh
            if not mesh or not mesh:IsValid() then return end
            local addr, char = mesh:GetAddress(), charOf(mesh)
            if onScreen(c) then
                seen[char] = true
                -- the Pandora menu preview model lives in an actor named A_<X>_PandoraMenuIdle...
                if c:GetFullName():find("PandoraMenu", 1, true) then menu = char end
            end
            if not layout[addr] then layout[addr] = buildLayout(c) end
            local L = layout[addr]
            if L.done then return end  -- several components can share one mesh asset
            L.done = true
            for slider, pivots in pairs(L.slider) do
                local s = get(char, slider)
                -- every live mesh is listed, 1.0 too: the dll only touches meshes in this list (resets to 1.0 included)
                local scale
                if slider == "lift" then
                    -- lift = move each breast bone straight up by its forward distance (capped at Breast5) * tan(angle):
                    -- the chain bends, areola + nipple move rigidly, so the nipple keeps pointing where it did
                    if math.abs(s) > 1e-3 then
                        for pi, bones in pairs(pivots) do
                            local cap = L.index[(L.names[pi]:gsub("Breast1", "Breast5"))]
                            if cap then
                                xlines[#xlines + 1] = string.format("%x %d %d y%.3f,%d %s", addr, L.n, pi, s, cap, table.concat(bones, " "))
                            end
                        end
                    end
                elseif XFORM[slider] then
                    if math.abs(s) > 1e-3 then
                        for pi, bones in pairs(pivots) do
                            local side = L.names[pi]:find("_R$") and -1 or 1
                            local a = { XFORM[slider](s, side) }
                            for i = 1, 6 do a[i] = string.format("%.3f", a[i]) end
                            xlines[#xlines + 1] = string.format("%x %d %d c%s %s", addr, L.n, pi, table.concat(a, ","), table.concat(bones, " "))
                        end
                    end
                elseif AXES[slider] then
                    local a = {}
                    for i, v in ipairs(AXES[slider]) do a[i] = string.format("%.4f", v == "v" and s or v) end
                    scale = table.concat(a, ",")
                else
                    -- slider = volume: bones scale in 3 axes, so length scale is the cube root (2.0x = twice the volume)
                    scale = string.format("%.4f", s ^ (1 / 3))
                end
                for pi, bones in pairs(scale and pivots or {}) do
                    lines[#lines + 1] = string.format("%x %d %d %s %s", addr, L.n, pi, scale, table.concat(bones, " "))
                end
            end
        end)
    end
    for _, L in pairs(layout) do L.done = nil end
    present = {}
    for ch in pairs(seen) do present[#present + 1] = ch end
    table.sort(present)
    menuChar = menu
    if menu then selected = menu  -- in the Pandora menu the sliders edit whoever the menu shows
    elseif not selected or not seen[selected] then selected = present[1] end
    table.sort(lines); table.sort(xlines)
    for _, l in ipairs(lines) do xlines[#xlines + 1] = l end
    lines = xlines
    local cmd = table.concat(lines, "\n")
    if cmd ~= lastCmd then
        local f = io.open(cmdPath, "w")
        if f then f:write(cmd); f:close(); lastCmd = cmd end
    end
end


---------------------------------------------------------------- physics (jiggle / hair sliders)
-- The game simulates breast, butt and hair bones with PhysX bodies from a PhysicsAsset (gallery poses swap assets).
-- We edit that asset's springs in place, relative to stock values cached the first time we see it, then re-init
-- the component's physics. Bigger breast/butt sliders also make those bodies heavier (slower, laggier wobble).
local BOUNCE_K = 980     -- ponytail: guessed from UE's mass-scaled soft limits; tune if Bounce sags too much/little
local BOUNCE_DAMP = 0.3  -- 0 = rings forever, 1 = no overshoot
local PHYS = {}  -- [asset address] = { bodies, joints, sig, applied = { [component address] = sig } }
local function num(x) if type(x) == "number" then return x end end
local function physGroup(bone)
    if bone:find("^Hair") or bone:find("^Braid") then return "hair" end
    if bone:find("^Breast") or bone:find("^Cloth_Breast") then return "breast" end
    if bone:find("^Helper_Skin_Butt") then return "butt" end
end

local function stock(pa)
    local P = { bodies = {}, joints = {}, applied = {} }
    pa.SkeletalBodySetups:ForEach(function(_, e)
        local b = e:get()
        local g = physGroup(b.BoneName:ToString())
        if g then
            local bi = b.DefaultInstance
            P.bodies[#P.bodies + 1] = { o = b, g = g, lin = num(bi.LinearDamping), ang = num(bi.AngularDamping),
                                        mass = bi.bOverrideMass == true and num(bi.MassInKgOverride) or nil,
                                        grav = bi.bEnableGravity }  -- boolean, or not-a-boolean if unreadable
        end
    end)
    pa.ConstraintSetup:ForEach(function(_, e)
        local t = e:get()
        local ci = t.DefaultInstance
        local g = physGroup(ci.ConstraintBone1:ToString())
        if g then
            local pr = ci.ProfileInstance
            local jt = { o = t, g = g, ck = num(pr.ConeLimit.Stiffness), cd = num(pr.ConeLimit.Damping),
                         tk = num(pr.TwistLimit.Stiffness), td = num(pr.TwistLimit.Damping) }
            local b1 = ci.ConstraintBone1:ToString()
            if g ~= "hair" and (b1:find("^Breast1_") or b1:find("^Cloth_Breast1_") or b1:find("^Helper_Skin_Butt_Base")) then
                local ll = pr.LinearLimit  -- chain roots only: sliding every link of the chain looks like jelly
                local st = { x = num(ll.XMotion), y = num(ll.YMotion), z = num(ll.ZMotion), lim = num(ll.Limit),
                             k = num(ll.Stiffness), d = num(ll.Damping), soft = ll.bSoftConstraint }
                if st.x and st.y and st.z and st.lim and st.k and st.d and type(st.soft) == "boolean" then jt.lin = st
                else log("bounce: can't read linear limit of " .. b1 .. ", skipped") end
            end
            P.joints[#P.joints + 1] = jt
        end
    end)
    return P
end

local function physics(c, char)
    local pa = c.PhysicsAssetOverride
    if not (pa and pa:IsValid()) then
        local m = c.SkeletalMesh
        pa = m and m:IsValid() and m.PhysicsAsset
    end
    if not (pa and pa:IsValid()) then return end
    local key, ckey = pa:GetAddress(), c:GetAddress()
    local P = PHYS[key]
    if not P then P = stock(pa); PHYS[key] = P end
    local j, h, bs, bt, bo = get(char, "jiggle"), get(char, "hair"), get(char, "breast"), get(char, "butt"), get(char, "bounce")
    local sig = string.format("%.3f %.3f %.3f %.3f %.2f", j, h, bs, bt, bo)
    if P.applied[ckey] == sig then return end
    if not P.sig and sig == "1.000 1.000 1.000 1.000 0.00" then P.applied[ckey] = sig; return end  -- untouched stock asset
    if P.sig ~= sig then
        -- slider v multiplies spring stiffness AND damping (springs + body damping). Tested in-game: this reads as more
        -- jiggle; the "physically bouncier" curve (stiffness up, damping down) looked worse.
        local function v(g) return g == "hair" and h or j end
        local function size(g) return (g == "breast" and bs) or (g == "butt" and bt) or 1 end
        for _, b in ipairs(P.bodies) do
            local bi, k = b.o.DefaultInstance, v(b.g)
            if b.lin then bi.LinearDamping = b.lin * k end
            if b.ang then bi.AngularDamping = b.ang * k end
            if b.mass then bi.MassInKgOverride = b.mass * size(b.g) end
            -- the game ships butt bodies weightless; with Bounce on they get gravity so they settle and rebound like breasts
            if b.g == "butt" and type(b.grav) == "boolean" then bi.bEnableGravity = (bo > 0) or b.grav end
        end
        for _, jt in ipairs(P.joints) do
            local pr, k = jt.o.DefaultInstance.ProfileInstance, v(jt.g)
            if jt.ck then pr.ConeLimit.Stiffness = jt.ck * k end
            if jt.cd then pr.ConeLimit.Damping = jt.cd * k end
            if jt.tk then pr.TwistLimit.Stiffness = jt.tk * k end
            if jt.td then pr.TwistLimit.Damping = jt.td * k end
            local ll, st = pr.LinearLimit, jt.lin
            if st and bo > 0 then
                -- soft spring around the rest position. UE scales soft-limit springs by the bodies' mass, so stiffness
                -- acts like an acceleration: resting sag under gravity = 980 / k cm. k = BOUNCE_K / bo -> sag ~ bo cm.
                local kk = BOUNCE_K / bo
                ll.XMotion, ll.YMotion, ll.ZMotion = 1, 1, 1      -- LCM_Limited
                ll.Limit, ll.bSoftConstraint = 0.1, true          -- spring engages past 1 mm
                ll.Stiffness, ll.Damping = kk, BOUNCE_DAMP * 2 * math.sqrt(kk)  -- fraction of critical damping
            elseif st then
                ll.XMotion, ll.YMotion, ll.ZMotion, ll.Limit = st.x, st.y, st.z, st.lim
                ll.Stiffness, ll.Damping, ll.bSoftConstraint = st.k, st.d, st.soft
            end
        end
        P.sig = sig
        local n = { breast = 0, butt = 0, hair = 0 }
        for _, b in ipairs(P.bodies) do n[b.g] = n[b.g] + 1 end
        local roots = 0
        for _, jt in ipairs(P.joints) do if jt.lin then roots = roots + 1 end end
        log(string.format("physics %s: %s | bodies breast=%d butt=%d hair=%d, bounce joints=%d | jiggle %.2f bounce %.1f hair %.2f",
            char, pa:GetFullName():match("[^%.]+$") or "?", n.breast, n.butt, n.hair, roots, j, bo, h))
    end
    c:SetPhysicsAsset(pa, true)  -- re-init this component's bodies from the edited asset
    P.applied[ckey] = sig
end

-- once a second (not on every slider drag: each re-init briefly resets the bodies)
local function physicsPass()
    for _, c in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
        pcall(function()
            if c:IsValid() and c:GetBoneIndex(FName("Breast1_L")) >= 0 and c.SkeletalMesh and c.SkeletalMesh:IsValid() then
                physics(c, charOf(c.SkeletalMesh))
            end
        end)
    end
end

---------------------------------------------------------------- keys
local function onGame(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(function() rescan(); fn(); rescan() end)
        if not ok then log("error: " .. tostring(err)) end
    end)
end

local function bump(slider, d)
    onGame(function()
        if not selected then return end
        vals[selected] = vals[selected] or {}
        vals[selected][slider] = clamp(slider, get(selected, slider) + d)
        save()
    end)
end

local function cycle(d)
    onGame(function()
        if #present == 0 then return end
        local i = 1
        for k, ch in ipairs(present) do if ch == selected then i = k end end
        selected = present[(i - 1 + d) % #present + 1]
    end)
end

RegisterKeyBind(Key.NUM_EIGHT, function() bump("breast", STEP) end)
RegisterKeyBind(Key.NUM_TWO,   function() bump("breast", -STEP) end)
RegisterKeyBind(Key.NUM_SIX,   function() bump("butt", STEP) end)
RegisterKeyBind(Key.NUM_FOUR,  function() bump("butt", -STEP) end)
RegisterKeyBind(Key.NUM_SEVEN, function() cycle(-1) end)
RegisterKeyBind(Key.NUM_NINE,  function() cycle(1) end)
RegisterKeyBind(Key.NUM_FIVE,  function()
    onGame(function()
        if selected then vals[selected] = nil; save() end
    end)
end)

---------------------------------------------------------------- on-screen panel (reuses the game's Options slider widget)
local SLIDER_CLASS = "/Game/Core/UI/Settings/SliderOption.SliderOption_C"
local LABELS = { breast = "Breasts", butt = "Butt", thighs = "Thighs", hips = "Hips", waist = "Waist",
                 nipple = "Nipples", areola = "Areolas", jiggle = "Jiggle", hair = "Hair", bounce = "Bounce",
                 cleavage = "Gap", splay = "Splay", lift = "Lift" }
local panel = {}          -- slider name -> { slider, value label, raw = last raw value we set/read }
local panelOn = false  -- Num0 opens it
local hidden = false   -- F10: hide for screenshots
local dirty = false

local function toRaw(v, s) return (v - MIN[s]) / (MAX[s] - MIN[s]) end
local function fromRaw(r, s) local st = FINE[s] or STEP; return math.floor((MIN[s] + r * (MAX[s] - MIN[s])) / st + 0.5) * st end  -- snap to STEP

local function valid(o) return o and o:IsValid() end

local function setText(tb, s) if valid(tb) then tb:SetText(FText(s)) end end

-- Pandora look: the game's own Pandora slider bar/handle textures, magenta labels, purple drop shadow.
local PINK   = { R = 1.0,  G = 0.22, B = 0.80, A = 1.0 }
local LILAC  = { R = 0.86, G = 0.78, B = 1.0,  A = 1.0 }
local SHADOW = { R = 0.10, G = 0.0,  B = 0.20, A = 0.9 }
local WHITE  = { R = 1.0,  G = 1.0,  B = 1.0,  A = 1.0 }
local TEX_BAR    = "/Game/ArtAssets/PANDORA/Interface/Textures/UI_PANDORA_Slider_BC"
local TEX_HANDLE = "/Game/ArtAssets/PANDORA/Interface/Textures/UI_PANDORA_Slider_Handle_BC"

local styleErrs = {}
local function try(tag, fn)
    local ok, err = pcall(fn)
    if not ok and not styleErrs[tag] then styleErrs[tag] = true; log("style '" .. tag .. "' skipped: " .. tostring(err)) end
end

local function texture(path)
    local name = path:match("([^/]+)$")
    local t = StaticFindObject(path .. "." .. name)
    if not valid(t) then LoadAsset(path); t = StaticFindObject(path .. "." .. name) end
    return valid(t) and t or nil
end

-- before AddToViewport: swap the slider's brushes so Slate builds it with the Pandora art
local function styleSlider(w)
    local bar, handle = texture(TEX_BAR), texture(TEX_HANDLE)
    local st = w.Slider.WidgetStyle
    if bar then try("bar", function()
        for _, k in ipairs({ "NormalBarImage", "DisabledBarImage" }) do
            st[k].ResourceObject = bar; st[k].DrawAs = 3; st[k].ImageSize = { X = 512, Y = 12 }
        end
        st.BarThickness = 6
    end) end
    if handle then try("handle", function()
        for _, k in ipairs({ "NormalThumbImage", "HoveredThumbImage", "DisabledThumbImage" }) do
            st[k].ResourceObject = handle; st[k].DrawAs = 3; st[k].ImageSize = { X = 30, Y = 30 }
        end
    end) end
end

---------------------------------------------------------------- overlay (Num0 opens/closes it anywhere a heroine is on screen)
-- The box: a throwaway SliderOption_C instance whose WidgetTree root is swapped for our own CanvasPanel before it
-- is added to the viewport, so it renders our backdrop + title + the two real slider widgets as one panel.
local TEX_WHITE = "/Game/ArtAssets/Shared/Interface/Textures/UI_BlankWhite_BC"
local BOX    = { R = 0.06, G = 0.02, B = 0.13, A = 0.96 }
local FRAME  = { R = 0.55, G = 0.20, B = 0.85, A = 1.0 }
local ACCENT = { R = 1.0,  G = 0.22, B = 0.80, A = 1.0 }
local ROWH, SECH = 46, 40
local BW, PAD = 560, 24
local openSection = 1
local function panelHeight(sec)  -- header, section bars, that section's rows, preset row, footer
    return 80 + #SECTIONS * SECH + #SECTIONS[sec][2] * ROWH + 8 + 46 + 50
end
local ui = {}

local function construct(clsPath, outer) return StaticConstructObject(StaticFindObject(clsPath), outer) end

local function place(canvas, child, x, y, w, h)
    local slot = canvas:AddChild(child)
    slot:SetOffsets({ Left = x, Top = y, Right = w, Bottom = h })  -- point anchor (0,0): Right/Bottom = size
    return slot
end

local function rect(tree, canvas, tex, col, x, y, w, h)
    local img = construct("/Script/UMG.Image", tree)
    if tex then img:SetBrushFromTexture(tex, false) end
    img:SetColorAndOpacity(col)
    return img, place(canvas, img, x, y, w, h)
end

local function label(tree, canvas, font, size, col, x, y, w, h)
    local tb = construct("/Script/UMG.TextBlock", tree)
    try("font", function() tb.Font = font; tb.Font.Size = size end)
    try("label", function()
        tb:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
        tb:SetShadowColorAndOpacity(SHADOW); tb:SetShadowOffset({ X = 2, Y = 2 })
    end)
    return tb, place(canvas, tb, x, y, w, h)
end

local BTN   = { R = 0.30, G = 0.14, B = 0.52, A = 1.0 }
local BTN_H = { R = 0.45, G = 0.22, B = 0.75, A = 1.0 }

local function button(tree, canvas, white, font, text, x, y, w, h)
    local cb = construct("/Script/UMG.CheckBox", tree)
    local st = cb.WidgetStyle
    st.CheckBoxType = 1  -- ToggleButton
    local function br(b, col) b.ResourceObject = white; b.DrawAs = 3; b.TintColor = { SpecifiedColor = col, ColorUseRule = 0 } end
    br(st.UncheckedImage, BTN); br(st.UncheckedHoveredImage, BTN_H); br(st.UncheckedPressedImage, ACCENT)
    br(st.CheckedImage, ACCENT); br(st.CheckedHoveredImage, ACCENT); br(st.CheckedPressedImage, ACCENT)
    st.Padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
    local tb = construct("/Script/UMG.TextBlock", tree)
    try("font", function() tb.Font = font; tb.Font.Size = 14 end)
    try("btntext", function() tb:SetColorAndOpacity({ SpecifiedColor = WHITE, ColorUseRule = 0 }); tb:SetJustification(1) end)
    setText(tb, text)
    local slot = cb:AddChild(tb)
    try("btnslot", function() slot:SetHorizontalAlignment(2); slot:SetVerticalAlignment(2) end)  -- centered
    return cb, place(canvas, cb, x, y, w, h), tb
end

local function clicked(cb)
    if cb:IsChecked() then cb:SetIsChecked(false); return true end
end

-- Every section's rows are built once; switching sections only hides/shows rows and moves widgets (relayout),
-- so the box never closes and reopens. Items: { slot, x, w, h, ytag, dy } where ytag picks the anchor below.
local items = {}
local function track(slot, x, w, h, ytag, dy) items[#items + 1] = { slot = slot, x = x, w = w, h = h, ytag = ytag, dy = dy } end

local function relayout()
    local y0, open = ui.y0, SECTIONS[openSection][2]
    local BH = panelHeight(openSection)
    local anchor = { top = y0, presets = y0 + 80 + #SECTIONS * SECH + #open * ROWH + 8, footer = y0 + BH - 46 }
    local y = y0 + 80
    for i, sec in ipairs(SECTIONS) do
        anchor["bar" .. i] = y
        y = y + SECH
        local shown = i == openSection
        for k, sname in ipairs(sec[2]) do
            anchor["row_" .. sname] = y + (k - 1) * ROWH
            for _, w in ipairs(panel[sname].widgets) do w:SetVisibility(shown and 0 or 1) end  -- 0 visible, 1 collapsed
        end
        if shown then y = y + #sec[2] * ROWH end
        setText(ui.barText[i], (shown and "-  " or "+  ") .. sec[1])
    end
    for _, it in ipairs(items) do
        local h = it.h == "box" and BH or it.h == "frame" and BH + 4 or it.h
        it.slot:SetOffsets({ Left = it.x, Top = anchor[it.ytag] + it.dy, Right = it.w, Bottom = h })
    end
end

local function buildUI()
    local cls = StaticFindObject(SLIDER_CLASS)
    if not valid(cls) then LoadAsset("/Game/Core/UI/Settings/SliderOption"); cls = StaticFindObject(SLIDER_CLASS) end
    local pc = FindFirstOf("PlayerController")
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local layoutLib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (valid(cls) and valid(pc) and valid(lib) and valid(layoutLib)) then return false end
    local vp, scale = layoutLib:GetViewportSize(pc), layoutLib:GetViewportScale(pc)
    local W, H = vp.X / scale, vp.Y / scale   -- slate units
    local tallest = 0
    for i in ipairs(SECTIONS) do tallest = math.max(tallest, panelHeight(i)) end
    -- top stays put for every section (centred for the tallest one), only the bottom edge moves
    local x0, y0 = math.floor(W * 0.04), math.max(8, math.floor((H - tallest) / 2))
    ui.y0 = y0

    local host = lib:Create(pc, cls, pc)
    if not valid(host) then return false end
    local tree = host.WidgetTree
    local canvas = construct("/Script/UMG.CanvasPanel", tree)
    tree.RootWidget = canvas
    local white = texture(TEX_WHITE)
    items = {}

    local _, sl1 = rect(tree, canvas, white, FRAME, x0 - 2, y0 - 2, BW + 4, 10); track(sl1, x0 - 2, BW + 4, "frame", "top", -2)
    local _, sl2 = rect(tree, canvas, white, BOX, x0, y0, BW, 10);              track(sl2, x0, BW, "box", "top", 0)
    rect(tree, canvas, white, ACCENT, x0, y0, BW, 4)                      -- pink top bar
    rect(tree, canvas, white, FRAME,  x0 + PAD, y0 + 66, BW - 2 * PAD, 1) -- divider

    -- rows (all sections): the SliderOption's own layout is ~800 wide, so take just its Slider and lay the row out ourselves
    panel = {}
    local font
    for _, sname in ipairs(SLIDERS) do
        local w = lib:Create(pc, cls, pc)
        if not valid(w) then return false end
        styleSlider(w)
        font = font or w.TextBlock_Description.Font
        local sl = w.Slider
        sl:RemoveFromParent()
        local tag = "row_" .. sname
        track(place(canvas, sl, x0 + PAD + 120, y0, BW - 2 * PAD - 200, 28), x0 + PAD + 120, BW - 2 * PAD - 200, 28, tag, 4)
        try("colors", function() sl:SetSliderBarColor(WHITE); sl:SetSliderHandleColor(WHITE) end)
        local name, ns = label(tree, canvas, font, 16, ACCENT, x0 + PAD, y0, 120, 24)
        track(ns, x0 + PAD, 120, 24, tag, 8)
        setText(name, LABELS[sname]:upper())
        local value, vs = label(tree, canvas, font, 16, LILAC, x0 + BW - PAD - 64, y0, 64, 24)
        track(vs, x0 + BW - PAD - 64, 64, 24, tag, 8)
        panel[sname] = { slider = sl, raw = -1, value = value, widgets = { sl, name, value } }
    end
    ui.title = label(tree, canvas, font, 24, ACCENT, x0 + PAD, y0 + 16, BW - 2 * PAD, 34)
    -- section bars: click one to open it
    ui.sections, ui.barText = {}, {}
    for i, sec in ipairs(SECTIONS) do
        local b, bs, bt = button(tree, canvas, white, font, sec[1], x0 + PAD, y0, BW - 2 * PAD, SECH - 8)
        ui.sections[i], ui.barText[i] = b, bt
        track(bs, x0 + PAD, BW - 2 * PAD, SECH - 8, "bar" .. i, 0)
    end
    -- presets: click a number to load it into this character; SAVE then a number stores her current shape there
    local _, ds = rect(tree, canvas, white, FRAME, x0 + PAD, y0, BW - 2 * PAD, 1); track(ds, x0 + PAD, BW - 2 * PAD, 1, "presets", -6)
    local pl, ps = label(tree, canvas, font, 14, LILAC, x0 + PAD, y0, 100, 22);   track(ps, x0 + PAD, 100, 22, "presets", 8)
    setText(pl, "PRESET")
    ui.presets = {}
    for i = 1, 3 do
        local x = x0 + PAD + 108 + (i - 1) * 54
        local b, bs = button(tree, canvas, white, font, tostring(i), x, y0, 46, 34)
        ui.presets[i] = b; track(bs, x, 46, 34, "presets", 0)
    end
    local sb, ss = button(tree, canvas, white, font, "SAVE", x0 + PAD + 108 + 3 * 54 + 8, y0, 90, 34)
    ui.save = sb; track(ss, x0 + PAD + 108 + 3 * 54 + 8, 90, 34, "presets", 0)
    -- footer: character switch (works without a numpad), reset, close
    -- buttons are toggle CheckBoxes: pollPanel sees them checked, acts, and unchecks (no Lua click delegates here)
    local function footBtn(text, x, w) local b, bs = button(tree, canvas, white, font, text, x, y0, w, 34); track(bs, x, w, 34, "footer", 0); return b end
    ui.prev = footBtn("<", x0 + PAD, 44)
    ui.next = footBtn(">", x0 + PAD + 52, 44)
    local hint, hs = label(tree, canvas, font, 12, LILAC, x0 + PAD + 108, y0, 120, 20); track(hs, x0 + PAD + 108, 120, 20, "footer", 8)
    ui.hint = hint; setText(hint, "CHARACTER")
    ui.reset = footBtn("RESET", x0 + BW - PAD - 216, 100)
    ui.close = footBtn("CLOSE", x0 + BW - PAD - 100, 100)

    relayout()
    host:AddToViewport(50)
    ui.host = host
    return true
end

local function uiAlive()
    local _, row = next(panel)
    return valid(ui.host) and ui.host:IsInViewport() and row and valid(row.slider)
end

local function pollPanel()
    local show = panelOn and not hidden and selected ~= nil
    if not uiAlive() then
        if not show then return end
        if not buildUI() then return end
    end
    ui.host:SetVisibility(show and 0 or 1)
    if not show then return end
    if clicked(ui.close) then panelOn = false; ui.host:SetVisibility(1); return end
    if clicked(ui.reset) then vals[selected] = nil; dirty = true; rescan() end
    if clicked(ui.prev) then cycle(-1) end
    if clicked(ui.next) then cycle(1) end
    for i, b in ipairs(ui.sections) do
        if clicked(b) and i ~= openSection then openSection = i; relayout() end
    end
    -- SAVE stays lit until a number is clicked (or SAVE again); a number alone loads
    for i, b in ipairs(ui.presets) do
        if clicked(b) then
            local key = "preset" .. i
            if ui.save:IsChecked() then
                vals[key] = {}
                for _, s in ipairs(SLIDERS) do vals[key][s] = get(selected, s) end
                ui.save:SetIsChecked(false)
            else
                vals[selected] = {}
                for _, s in ipairs(SLIDERS) do vals[selected][s] = (vals[key] or {})[s] end
            end
            dirty = true; rescan()
        end
    end
    setText(ui.title, "BODY  |  " .. selected:upper())
    for s, p in pairs(panel) do
        local slider = p.slider
        local r = slider:GetValue()
        if p.raw >= 0 and math.abs(r - p.raw) > 1e-4 then  -- user dragged it
            vals[selected] = vals[selected] or {}
            vals[selected][s] = fromRaw(r, s)
            dirty = true
            rescan()  -- push to the dll now, not on the next 1s tick
        end
        local want = toRaw(get(selected, s), s)
        if math.abs(slider:GetValue() - want) > 1e-3 then slider:SetValue(want) end
        p.raw = slider:GetValue()
        local fmt = (UNIT[s] == " deg" and "%.0f") or (FINE[s] and "%.2f") or "%.1f"
        setText(p.value, string.format(fmt, get(selected, s)) .. (UNIT[s] or "x"))
    end
end

RegisterKeyBind(Key.NUM_ZERO, function() panelOn = not panelOn end)
RegisterKeyBind(Key.F8, function() panelOn = not panelOn end)  -- for keyboards without a numpad
RegisterKeyBind(Key.F10, function() hidden = not hidden end)    -- same key as FreeCam's hide-UI

-- Game-thread timers. (LoopAsync + ExecuteInGameThread every 100ms corrupted UE4SS's callback registry.)
local lastPanelErr
LoopInGameThreadWithDelay(150, function()
    local ok, err = pcall(pollPanel)
    if not ok and tostring(err) ~= lastPanelErr then lastPanelErr = tostring(err); log("panel error: " .. lastPanelErr) end
end)

-- apply saved sizes to meshes as scenes load them (and flush slider drags to disk)
LoopInGameThreadWithDelay(1000, function()
    pcall(rescan)
    local ok, err = pcall(physicsPass)
    if not ok then log("physics error: " .. tostring(err)) end
    if dirty then dirty = false; save() end
end)

load()
save()  -- writes the [limits] section so users can find it
local f = io.open(cmdPath, "w"); if f then f:close() end

-- Ctrl+R hot reload: drop panel widgets left in the viewport by the previous script instance.
-- (The game's own Options sliders are nested inside menus, never top-level viewport widgets.)
ExecuteInGameThread(function()
    pcall(function()
        for _, w in ipairs(FindAllOf("SliderOption_C") or {}) do
            if w:IsValid() and w:IsInViewport() then w:RemoveFromParent() end
        end
    end)
end)
