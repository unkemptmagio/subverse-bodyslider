-- BodySlider (UE4SS Lua side): finds heroine meshes, keeps per-character slider values (saved to BodySlider.ini),
-- writes cmd.txt for bodyslider.dll which rescales the bones live.
-- Keys: Num7/Num9 select previous/next character on screen, Num8/Num2 breasts +/-, Num6/Num4 butt +/-,
--       Num5 reset selected character, Num0 or F8 show/hide the on-screen sliders. Size limits: [limits] in BodySlider.ini.

local STEP = 0.1
-- per-slider limits in volume; overridden by [limits] in BodySlider.ini (clamped to 0.1-50 so the dll stays sane)
local MIN = { breast = 1.0, butt = 1.0 }
local MAX = { breast = 3.0, butt = 5.0 }
local SLIDERS = { "breast", "butt" }
local GROUPS = {
    breast = { "Breast1_L", "Breast1_R", "Cloth_Breast1_L", "Cloth_Breast1_R" },
    butt   = { "Helper_Skin_Butt_Base_L", "Helper_Skin_Butt_Base_R" },
}

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
local function get(char, slider) return clamp(slider, (vals[char] and vals[char][slider]) or 1.0) end

local function load()
    local f = io.open(iniPath, "r"); if not f then return end
    local cur
    for line in f:lines() do
        local sec = line:match("^%s*%[(.-)%]%s*$")
        if sec then cur = sec:lower(); if cur ~= "limits" then vals[cur] = vals[cur] or {} end
        elseif cur then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
            v = tonumber(v)
            if k and v and cur == "limits" then
                local sl, which = k:lower():match("^(%a+)_(%a+)$")
                local t = (which == "min" and MIN) or (which == "max" and MAX)
                if t and t[sl] then t[sl] = math.max(0.1, math.min(50, v)) end
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
    local out = { "; BodySlider. Sizes are volume (1.0 = default, 2.0 = twice as big).",
                  "; [limits] sets each slider's range (0.1 - 50); edit with the game closed.", "[limits]" }
    for _, sl in ipairs(SLIDERS) do
        out[#out + 1] = string.format("%s_min=%g", sl, MIN[sl]); out[#out + 1] = string.format("%s_max=%g", sl, MAX[sl])
    end
    out[#out + 1] = ""
    out[#out + 1] = "; per-character sizes (written by the game)"
    for _, c in ipairs(chars) do
        local lines = {}
        for _, s in ipairs(SLIDERS) do
            if math.abs(get(c, s) - 1.0) > 1e-3 then lines[#lines + 1] = string.format("%s=%.2f", s, get(c, s)) end
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
    local L = { n = n, slider = {} }
    for slider, pivots in pairs(GROUPS) do
        L.slider[slider] = {}
        for _, pv in ipairs(pivots) do
            local pi = index[pv]
            if pi then L.slider[slider][pi] = descendantsOf(pi) end
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
    local lines, seen, menu = {}, {}, nil
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
                for pi, bones in pairs(pivots) do
                    -- slider = volume: bones scale in 3 axes, so length scale is the cube root (2.0x = twice the volume)
                    lines[#lines + 1] = string.format("%x %d %d %.4f %s", addr, L.n, pi, s ^ (1 / 3), table.concat(bones, " "))
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
    table.sort(lines)
    local cmd = table.concat(lines, "\n")
    if cmd ~= lastCmd then
        local f = io.open(cmdPath, "w")
        if f then f:write(cmd); f:close(); lastCmd = cmd end
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
local LABELS = { breast = "Breasts", butt = "Butt" }
local panel = {}          -- slider name -> { slider, value label, raw = last raw value we set/read }
local panelOn = false  -- Num0 opens it
local dirty = false

local function toRaw(v, s) return (v - MIN[s]) / (MAX[s] - MIN[s]) end
local function fromRaw(r, s) return math.floor((MIN[s] + r * (MAX[s] - MIN[s])) / STEP + 0.5) * STEP end  -- snap to STEP

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
local BW, BH, PAD = 560, 244, 24
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
    place(canvas, img, x, y, w, h)
end

local function label(tree, canvas, font, size, col, x, y, w, h)
    local tb = construct("/Script/UMG.TextBlock", tree)
    try("font", function() tb.Font = font; tb.Font.Size = size end)
    try("label", function()
        tb:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
        tb:SetShadowColorAndOpacity(SHADOW); tb:SetShadowOffset({ X = 2, Y = 2 })
    end)
    place(canvas, tb, x, y, w, h)
    return tb
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
    place(canvas, cb, x, y, w, h)
    return cb
end

local function clicked(cb)
    if cb:IsChecked() then cb:SetIsChecked(false); return true end
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
    local x0, y0 = math.floor(W * 0.04), math.floor(H * 0.32)

    local host = lib:Create(pc, cls, pc)
    if not valid(host) then return false end
    local tree = host.WidgetTree
    local canvas = construct("/Script/UMG.CanvasPanel", tree)
    tree.RootWidget = canvas
    local white = texture(TEX_WHITE)

    rect(tree, canvas, white, FRAME,  x0 - 2, y0 - 2, BW + 4, BH + 4)     -- 2px frame
    rect(tree, canvas, white, BOX,    x0, y0, BW, BH)                     -- opaque body
    rect(tree, canvas, white, ACCENT, x0, y0, BW, 4)                      -- pink top bar
    rect(tree, canvas, white, FRAME,  x0 + PAD, y0 + 66, BW - 2 * PAD, 1) -- divider

    -- rows: the SliderOption's own layout is ~800 wide, so take just its Slider and lay the row out ourselves
    panel = {}
    local font
    for i, s in ipairs(SLIDERS) do
        local w = lib:Create(pc, cls, pc)
        if not valid(w) then return false end
        styleSlider(w)
        font = font or w.TextBlock_Description.Font
        local sl, y = w.Slider, y0 + 84 + (i - 1) * 52
        sl:RemoveFromParent()
        place(canvas, sl, x0 + PAD + 120, y + 4, BW - 2 * PAD - 200, 28)
        try("colors", function() sl:SetSliderBarColor(WHITE); sl:SetSliderHandleColor(WHITE) end)
        local name = label(tree, canvas, font, 16, ACCENT, x0 + PAD, y + 8, 120, 24)
        setText(name, LABELS[s]:upper())
        panel[s] = { slider = sl, raw = -1,
                     value = label(tree, canvas, font, 16, LILAC, x0 + BW - PAD - 64, y + 8, 64, 24) }
    end
    ui.title = label(tree, canvas, font, 24, ACCENT, x0 + PAD, y0 + 16, BW - 2 * PAD, 34)
    -- character switch buttons, so the panel works without a numpad
    ui.prev = button(tree, canvas, white, font, "<", x0 + PAD, y0 + BH - 46, 44, 34)
    ui.next = button(tree, canvas, white, font, ">", x0 + PAD + 52, y0 + BH - 46, 44, 34)
    ui.hint  = label(tree, canvas, font, 12, LILAC,  x0 + PAD + 108, y0 + BH - 38, 120, 20)
    setText(ui.hint, "CHARACTER")
    -- buttons are toggle CheckBoxes: pollPanel sees them checked, acts, and unchecks (no Lua click delegates here)
    ui.reset = button(tree, canvas, white, font, "RESET", x0 + BW - PAD - 216, y0 + BH - 46, 100, 34)
    ui.close = button(tree, canvas, white, font, "CLOSE", x0 + BW - PAD - 100, y0 + BH - 46, 100, 34)

    host:AddToViewport(50)
    ui.host = host
    return true
end

local function uiAlive() return valid(ui.host) and ui.host:IsInViewport() and panel.breast and valid(panel.breast.slider) end

local function pollPanel()
    local show = panelOn and selected ~= nil
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
    setText(ui.title, "BODY  |  " .. selected:upper())
    for _, s in ipairs(SLIDERS) do
        local p, slider = panel[s], panel[s].slider
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
        setText(p.value, string.format("%.1fx", get(selected, s)))
    end
end

RegisterKeyBind(Key.NUM_ZERO, function() panelOn = not panelOn end)
RegisterKeyBind(Key.F8, function() panelOn = not panelOn end)  -- for keyboards without a numpad

-- Game-thread timers. (LoopAsync + ExecuteInGameThread every 100ms corrupted UE4SS's callback registry.)
local lastPanelErr
LoopInGameThreadWithDelay(150, function()
    local ok, err = pcall(pollPanel)
    if not ok and tostring(err) ~= lastPanelErr then lastPanelErr = tostring(err); log("panel error: " .. lastPanelErr) end
end)

-- apply saved sizes to meshes as scenes load them (and flush slider drags to disk)
LoopInGameThreadWithDelay(1000, function()
    pcall(rescan)
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
