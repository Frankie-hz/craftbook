require('common');

local imgui = require('imgui');
local skin  = require('skin');

local function rgba(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16) / 255;
    local g = tonumber(hex:sub(4, 5), 16) / 255;
    local b = tonumber(hex:sub(6, 7), 16) / 255;
    return { r, g, b, alpha or 1 };
end

-- The Phoenix theme's palette: dark red and ember, after phoenix-xi.com.
local crimson = {
    abyss        = rgba('#180E0E'),
    glass        = rgba('#291C1C'),
    surface      = rgba('#321F1F', 0.94),
    field        = rgba('#221616'),
    fieldHover   = rgba('#281B1B'),
    fieldActive  = rgba('#2E1F1F'),
    text         = rgba('#FFF8F8'),
    peach        = rgba('#D2ABAB'),
    muted        = rgba('#8A6B6B'),
    royal        = rgba('#C55151'),
    royalHover   = rgba('#D45E5E'),
    accentMuted  = rgba('#C55151', 0.15),
    accentSoft   = rgba('#C55151', 0.28),
    remove       = rgba('#E04040'),
    warn         = rgba('#E8B050'),
    border       = rgba('#D2ABAB', 0.20),
    borderSoft   = rgba('#D2ABAB', 0.12),
    clear        = { 0, 0, 0, 0 },
};

-- The Classic theme wears the game's own window art (see skin.lua). These are sampled from each Window Type's
-- background and frame so the flat parts of the UI match the art behind them.
local WINDOW_ART = {
    [0] = { background = rgba('#282452'), frame = rgba('#888988') },
    [1] = { background = rgba('#5D5C6F'), frame = rgba('#9698A6') },
    [2] = { background = rgba('#23204D'), frame = rgba('#888988') },
    [3] = { background = rgba('#2B2B2B'), frame = rgba('#9698A6') },
    [4] = { background = rgba('#626262'), frame = rgba('#888988') },
    [5] = { background = rgba('#001948'), frame = rgba('#5A4418') },
    [6] = { background = rgba('#9E8F64'), frame = rgba('#867953') },
    [7] = { background = rgba('#1C353F'), frame = rgba('#314E57') },
};

-- The middle of the top-down shading skin.lua draws the art with.
local ART_SHADE = 0.62;

local function shade(color, factor, alpha)
    return { color[1] * factor, color[2] * factor, color[3] * factor, alpha or 1 };
end

local function fade(color, alpha)
    return { color[1], color[2], color[3], alpha };
end

local function lighten(color, amount)
    return { color[1] + (1 - color[1]) * amount, color[2] + (1 - color[2]) * amount, color[3] + (1 - color[3]) * amount, 1 };
end

local function classic(window_type)
    local art    = WINDOW_ART[window_type];
    local panel  = shade(art.background, ART_SHADE);
    local accent = lighten(art.frame, 0.25);
    local light  = lighten(art.frame, 0.60);
    local text   = { 0.96, 0.96, 0.93, 1 };
    local inset  = { 0, 0, 0, 0.34 };
    local clear  = { 0, 0, 0, 0 };

    return {
        name     = 'Classic',
        skin     = window_type,
        headings = 'line',
        vars = {
            WindowRounding    = 0,
            ChildRounding     = 0,
            FrameRounding     = 2,
            PopupRounding     = 0,
            ScrollbarRounding = 2,
            GrabRounding      = 2,
            TabRounding       = 2,
            WindowPadding     = { 12, 12 },
            FramePadding      = { 8, 5 },
            ItemSpacing       = { 8, 6 },
            -- The frame comes from the art.
            WindowBorderSize  = 0,
            ScrollbarSize     = 12,
        },
        colors = {
            Text                      = text,
            TextDisabled              = { 0.72, 0.72, 0.70, 1 },
            -- What shows where the art does not reach, and everywhere when it cannot be loaded.
            WindowBg                  = panel,
            ChildBg                   = { 0, 0, 0, 0.18 },
            PopupBg                   = shade(panel, 0.85, 0.98),
            Border                    = fade(accent, 0.55),
            FrameBg                   = inset,
            FrameBgHovered            = fade(accent, 0.24),
            FrameBgActive             = fade(accent, 0.36),
            TitleBg                   = shade(panel, 0.80),
            TitleBgActive             = shade(panel, 1.05),
            TitleBgCollapsed          = shade(panel, 0.80, 0.90),
            ScrollbarBg               = { 0, 0, 0, 0.30 },
            ScrollbarGrab             = fade(accent, 0.55),
            ScrollbarGrabHovered      = fade(accent, 0.80),
            ScrollbarGrabActive       = light,
            Button                    = fade(accent, 0.30),
            ButtonHovered             = fade(accent, 0.48),
            ButtonActive              = fade(accent, 0.66),
            Header                    = fade(accent, 0.30),
            HeaderHovered             = fade(accent, 0.44),
            HeaderActive              = fade(accent, 0.58),
            CheckMark                 = light,
            SliderGrab                = fade(light, 0.70),
            SliderGrabActive          = light,
            NavCursor                 = light,
            TextSelectedBg            = fade(accent, 0.50),
            Separator                 = fade(accent, 0.50),
            SeparatorHovered          = fade(light, 0.80),
            SeparatorActive           = light,
            ResizeGrip                = fade(accent, 0.40),
            ResizeGripHovered         = fade(light, 0.70),
            ResizeGripActive          = light,
            Tab                       = inset,
            TabHovered                = fade(accent, 0.48),
            TabSelected               = fade(accent, 0.34),
            TabSelectedOverline       = light,
            TabDimmed                 = inset,
            TabDimmedSelected         = fade(accent, 0.26),
            TabDimmedSelectedOverline = fade(light, 0.60),
            TableHeaderBg             = inset,
            TableBorderStrong         = fade(accent, 0.45),
            TableBorderLight          = fade(accent, 0.25),
            TableRowBg                = clear,
            TableRowBgAlt             = { 1, 1, 1, 0.03 },
            TextLink                  = { 0.68, 0.82, 1.00, 1 },
            InputTextCursor           = text,
            DragDropTarget            = light,
        },
        semantic = {
            title   = { 1.00, 0.87, 0.48, 1.00 },
            good    = { 0.52, 0.90, 0.52, 1.00 },
            warn    = { 0.98, 0.82, 0.38, 1.00 },
            bad     = { 1.00, 0.52, 0.46, 1.00 },
            hq      = { 0.62, 0.80, 1.00, 1.00 },
            keyitem = { 0.88, 0.66, 1.00, 1.00 },
            support = { 0.20, 0.50, 0.30, 1.00 },
        },
    };
end

local classic_variants = {};
for window_type, _ in pairs(WINDOW_ART) do
    classic_variants[window_type] = classic(window_type);
end

-- Each theme: a display name, ImGui colors and style sizes pushed around every craftbook window (keyed by the
-- ImGuiCol_/ImGuiStyleVar_ suffix), the meaning colors craftbook draws with, and how section headings look.
-- A theme with `variants` is one of several looks, and `pick` says which one is showing.
local list = {
    classic = {
        name     = 'Classic',
        variants = classic_variants,
        pick     = skin.window_type,
    },
    default = {
        name     = 'Default',
        colors   = {},
        vars     = {},
        headings = 'line',
        semantic = {
            title   = { 1.00, 0.85, 0.40, 1.00 },
            good    = { 0.45, 0.85, 0.45, 1.00 },
            warn    = { 0.95, 0.80, 0.35, 1.00 },
            bad     = { 0.95, 0.45, 0.40, 1.00 },
            hq      = { 0.55, 0.75, 1.00, 1.00 },
            keyitem = { 0.85, 0.60, 1.00, 1.00 },
            support = { 0.20, 0.50, 0.30, 1.00 },
        },
    },
    phoenix = {
        name     = 'Phoenix',
        headings = 'caps',
        vars = {
            WindowRounding    = 0,
            ChildRounding     = 0,
            FrameRounding     = 0,
            PopupRounding     = 0,
            ScrollbarRounding = 0,
            GrabRounding      = 0,
            TabRounding       = 0,
            WindowPadding     = { 16, 14 },
            FramePadding      = { 10, 6 },
            ItemSpacing       = { 8, 8 },
            ItemInnerSpacing  = { 6, 4 },
            WindowBorderSize  = 1,
            FrameBorderSize   = 1,
            ScrollbarSize     = 10,
        },
        colors = {
            Text                      = crimson.text,
            TextDisabled              = crimson.muted,
            WindowBg                  = crimson.abyss,
            ChildBg                   = crimson.glass,
            PopupBg                   = crimson.glass,
            ModalWindowDimBg          = { 0.02, 0.01, 0.01, 0.55 },
            Border                    = crimson.border,
            FrameBg                   = crimson.field,
            FrameBgHovered            = crimson.fieldHover,
            FrameBgActive             = crimson.fieldActive,
            TitleBg                   = crimson.glass,
            TitleBgActive             = crimson.glass,
            TitleBgCollapsed          = crimson.glass,
            ScrollbarBg               = rgba('#180E0E', 0.35),
            ScrollbarGrab             = rgba('#D2ABAB', 0.35),
            ScrollbarGrabHovered      = rgba('#D2ABAB', 0.55),
            ScrollbarGrabActive       = crimson.royal,
            Button                    = crimson.surface,
            ButtonHovered             = crimson.accentMuted,
            ButtonActive              = crimson.accentSoft,
            Header                    = crimson.accentMuted,
            HeaderHovered             = crimson.accentSoft,
            HeaderActive              = rgba('#C55151', 0.42),
            CheckMark                 = crimson.royal,
            SliderGrab                = rgba('#D2ABAB', 0.55),
            SliderGrabActive          = crimson.royal,
            NavCursor                 = crimson.royal,
            TextSelectedBg            = crimson.accentSoft,
            Separator                 = crimson.borderSoft,
            SeparatorHovered          = crimson.royalHover,
            SeparatorActive           = crimson.royal,
            ResizeGrip                = rgba('#D2ABAB', 0.25),
            ResizeGripHovered         = crimson.royal,
            ResizeGripActive          = crimson.royalHover,
            -- Tab bars, tables and links, picked to sit in the same palette.
            Tab                       = crimson.glass,
            TabHovered                = crimson.accentSoft,
            TabSelected               = crimson.accentMuted,
            TabSelectedOverline       = crimson.royal,
            TabDimmed                 = crimson.glass,
            TabDimmedSelected         = crimson.accentMuted,
            TabDimmedSelectedOverline = crimson.royal,
            TableHeaderBg             = crimson.glass,
            TableBorderStrong         = crimson.border,
            TableBorderLight          = crimson.borderSoft,
            TableRowBg                = crimson.clear,
            TableRowBgAlt             = rgba('#D2ABAB', 0.03),
            TextLink                  = rgba('#E39A9A'),
            InputTextCursor           = crimson.text,
            DragDropTarget            = crimson.royal,
        },
        semantic = {
            title   = crimson.peach,
            good    = rgba('#8CCB82'),
            warn    = crimson.warn,
            bad     = crimson.remove,
            hq      = rgba('#94B4EA'),
            keyitem = rgba('#D3A2EC'),
            support = crimson.royal,
        },
    },
};

-- The theme a new install starts on, and the fallback when a saved theme no longer exists.
local STARTING = 'phoenix';

-- The dropdown order: the starting theme first, then every other theme by name. Adding a block to `list` is all a
-- new theme needs.
local order = {};
for key, _ in pairs(list) do
    if (key ~= STARTING) then
        order[#order + 1] = key;
    end
end
table.sort(order, function (a, b)
    return list[a].name:lower() < list[b].name:lower();
end);
table.insert(order, 1, STARTING);

local themes = {
    starting = STARTING,
};

function themes.get(key)
    local theme = list[key] or list[STARTING];
    if (theme.variants ~= nil) then
        return theme.variants[theme.pick()];
    end

    return theme;
end

function themes.keys()
    return order;
end

function themes.names()
    local names = {};
    for index, key in ipairs(order) do
        names[index] = list[key].name;
    end

    return names;
end

function themes.index_of(key)
    for index, candidate in ipairs(order) do
        if (candidate == key) then
            return index;
        end
    end

    return 1;
end

function themes.key_at(index)
    return order[index] or order[1];
end

-- Matches a theme by key or display name, ignoring case.
function themes.find(text)
    local wanted = text:lower();
    for _, key in ipairs(order) do
        if (key == wanted or list[key].name:lower() == wanted) then
            return key;
        end
    end

    return nil;
end

-- Border thickness stays a crisp pixel at any UI scale.
local UNSCALED = { WindowBorderSize = true, FrameBorderSize = true };

local function scaled(name, value, scale)
    if (UNSCALED[name] or scale == 1) then
        return value;
    end
    if (type(value) == 'table') then
        return { math.floor(value[1] * scale + 0.5), math.floor(value[2] * scale + 0.5) };
    end

    return math.floor(value * scale + 0.5);
end

-- Pushes the theme and returns the counts themes.pop needs. Enums this ImGui build lacks are skipped.
function themes.push(theme, scale)
    local colors = 0;
    for name, value in pairs(theme.colors) do
        local enum = _G['ImGuiCol_' .. name];
        if (enum ~= nil) then
            imgui.PushStyleColor(enum, value);
            colors = colors + 1;
        end
    end

    local vars = 0;
    for name, value in pairs(theme.vars) do
        local enum = _G['ImGuiStyleVar_' .. name];
        if (enum ~= nil) then
            imgui.PushStyleVar(enum, scaled(name, value, scale or 1));
            vars = vars + 1;
        end
    end

    return colors, vars;
end

function themes.pop(colors, vars)
    if (colors > 0) then
        imgui.PopStyleColor(colors);
    end
    if (vars > 0) then
        imgui.PopStyleVar(vars);
    end
end

return themes;
