-- Forever Guide: two themes with colors you can change and save.
local _, FG = ...
local Theme = { frames = {} }
FG.Theme = Theme

Theme.KEYS = { "bg", "header", "border", "title", "text", "muted", "accent", "good", "bad" }
Theme.LABELS = {
    bg = "Background", header = "Header bar", border = "Border", title = "Title",
    text = "Text", muted = "Muted text", accent = "Accent", good = "Positive", bad = "Negative",
}

Theme.THEMES = {
    stormwind = {
        name = "Stormwind (light)",
        bg = { 0.96, 0.93, 0.85, 0.97 }, header = { 0.16, 0.29, 0.55, 1 }, border = { 0.72, 0.58, 0.30, 1 },
        title = { 1, 0.95, 0.80, 1 }, text = { 0.17, 0.13, 0.08, 1 }, muted = { 0.42, 0.36, 0.27, 1 },
        accent = { 0.16, 0.36, 0.69, 1 }, good = { 0.13, 0.50, 0.20, 1 }, bad = { 0.70, 0.16, 0.12, 1 },
    },
    orgrimmar = {
        name = "Orgrimmar (dark)",
        bg = { 0.09, 0.07, 0.06, 0.95 }, header = { 0.45, 0.10, 0.07, 1 }, border = { 0.55, 0.36, 0.18, 1 },
        title = { 1, 0.80, 0.35, 1 }, text = { 0.93, 0.90, 0.84, 1 }, muted = { 0.66, 0.60, 0.50, 1 },
        accent = { 0.91, 0.62, 0.24, 1 }, good = { 0.50, 0.82, 0.55, 1 }, bad = { 0.95, 0.45, 0.40, 1 },
    },
}

local function settings() return FG.settings end

function Theme:Current()
    local name = settings() and settings().theme or "orgrimmar"
    return self.THEMES[name] and name or "orgrimmar"
end

function Theme:Get(key)
    local name = self:Current()
    local custom = settings() and settings().colors and settings().colors[name]
    local c = custom and custom[key] or self.THEMES[name][key]
    return c[1], c[2], c[3], c[4] or 1
end

function Theme:Hex(key)
    local r, g, b = self:Get(key)
    return string.format("ff%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- Wraps text in the theme color, e.g. Theme:Color("good", "+5g").
function Theme:Color(key, text)
    return "|c" .. self:Hex(key) .. text .. "|r"
end

function Theme:Set(name)
    if not self.THEMES[name] then return end
    settings().theme = name
    self:Apply()
end

function Theme:SetColor(key, r, g, b)
    local s = settings()
    local name = self:Current()
    s.colors = s.colors or {}
    s.colors[name] = s.colors[name] or {}
    local a = select(4, self:Get(key))
    s.colors[name][key] = { r, g, b, a }
    self:Apply()
end

function Theme:Reset()
    local s = settings()
    if s.colors then s.colors[self:Current()] = nil end
    self:Apply()
end

-- Frames register a skin function that runs now and on every theme change.
function Theme:Register(frame, skin)
    table.insert(self.frames, { frame = frame, skin = skin })
    skin(frame, self)
end

function Theme:Apply()
    for _, f in ipairs(self.frames) do f.skin(f.frame, self) end
end

-- Flat window look: one-pixel border, colored header bar.
function Theme:SkinWindow(f)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(self:Get("bg"))
    f:SetBackdropBorderColor(self:Get("border"))
    if f.headerBar then f.headerBar:SetColorTexture(self:Get("header")) end
    if f.title then f.title:SetTextColor(self:Get("title")) end
end

function Theme:PickColor(key)
    local r, g, b = self:Get(key)
    local function apply()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        Theme:SetColor(key, nr, ng, nb)
    end
    local function cancel(prev)
        if prev then Theme:SetColor(key, prev.r or prev[1], prev.g or prev[2], prev.b or prev[3]) end
    end
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({ r = r, g = g, b = b, swatchFunc = apply, cancelFunc = cancel })
    else
        ColorPickerFrame.func, ColorPickerFrame.cancelFunc = apply, cancel
        ColorPickerFrame.previousValues = { r = r, g = g, b = b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Show()
    end
end
