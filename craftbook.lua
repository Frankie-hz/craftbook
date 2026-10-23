addon.name    = 'craftbook';
addon.author  = 'Frankie';
addon.version = '1.2.1';
addon.desc    = 'Searchable crafting recipes with where to buy, farm or gather every material.';
addon.link    = 'https://github.com/Frankie-hz/craftbook';

require('common');

local chat     = require('chat');
local settings = require('settings');
local db       = require('db');
local icons    = require('icons');
local player   = require('player');
local prices   = require('prices');
local history  = require('history');
local themes   = require('themes');
local trackers = require('trackers');
local window   = require('window');
local ui       = require('ui');

-- Classic theme: -1 follows the game's Window Type, 0 to 7 pins one.
local FOLLOW_GAME      = -1;
local LAST_WINDOW_TYPE = 7;

-- Ashita keeps a 10 KB copy of each packet until its event is collected, but Lua counts it as a few bytes, so with the
-- recipe data's big heap the collector waited minutes and held thousands. Each packet now steps it by its copy, or by a
-- share of a big heap.
local PACKET_COPY_KB = 10;
local HEAP_SHARE     = 256;

local default_settings = T{
    icons       = true,
    mode        = 1,
    craft       = 0,
    level_min   = 0,
    level_max   = 110,
    include_sub = false,
    desynth     = false,
    support     = 0,
    skillup     = false,
    favorites   = T{},
    tracked     = T{},
    trackers    = T{},
    tracker_next = 1,
    tracker     = true,
    theme       = themes.starting,
    window_type = FOLLOW_GAME,
    detached    = false,
    tabbed      = false,
    scale       = 1,
    tracker_alpha = 0.35,
    tracker_odds  = true,
    show_skillups = true,
    esc_closes    = true,
    full_names    = false,
    cursor_mode   = 1,
    hq1         = false,
    hq2         = false,
    hq3         = false,
};

local MIN_SCALE = 0.75;
local MAX_SCALE = 2;

local config = settings.load(default_settings);

local state = {
    visible       = { false },
    search        = { '' },
    mode          = 1,
    craft         = 0,
    level_min     = { 0 },
    level_max     = { 110 },
    include_sub   = { false },
    desynth       = { false },
    support       = 0,
    skillup       = { false },
    favorites     = {},
    favorites_rev = 0,
    tracker       = { true },
    theme         = themes.starting,
    window_type   = FOLLOW_GAME,
    hq_filter     = { { false }, { false }, { false } },
    log_visible   = { false },
    log_all       = { false },
    icons         = { true },
    results       = {},
    filter_key    = nil,
    view          = nil,
    history       = {},
    scroll_detail = false,
    detached      = false,
    tabbed        = false,
    detail_open   = { true },
    scale         = 1,
    tracker_alpha = 0.35,
    tracker_odds  = { true },
    show_skillups = { true },
    esc_closes    = { true },
    full_names    = { false },
    cursor_mode   = 1,
    settings_visible = { false },
};

local function apply_config()
    state.mode           = config.mode;
    state.craft          = config.craft;
    state.level_min[1]   = config.level_min;
    state.level_max[1]   = config.level_max;
    state.include_sub[1] = config.include_sub;
    state.desynth[1]     = config.desynth;
    state.support        = config.support;
    state.skillup[1]     = config.skillup;
    state.favorites      = config.favorites;
    trackers.load(config.trackers, config.tracker_next, config.tracked);
    state.tracker[1]     = config.tracker;
    state.theme          = config.theme;
    state.window_type    = math.max(FOLLOW_GAME, math.min(config.window_type, LAST_WINDOW_TYPE));
    state.detached       = config.detached;
    state.tabbed         = config.tabbed;
    state.scale          = math.max(MIN_SCALE, math.min(config.scale, MAX_SCALE));
    state.tracker_alpha  = config.tracker_alpha;
    state.tracker_odds[1]  = config.tracker_odds;
    state.show_skillups[1] = config.show_skillups;
    state.esc_closes[1]    = config.esc_closes;
    state.full_names[1]    = config.full_names;
    state.cursor_mode      = math.max(1, math.min(config.cursor_mode, 3));
    state.hq_filter[1][1] = config.hq1;
    state.hq_filter[2][1] = config.hq2;
    state.hq_filter[3][1] = config.hq3;
    state.icons[1]       = config.icons;
    state.filter_key     = nil;
end

-- A quick look from /cb lvl is never saved. What it replaced is.
local function lasting_filters()
    if (state.quick ~= nil) then
        return state.quick;
    end

    return { mode = state.mode, craft = state.craft, level_min = state.level_min[1], level_max = state.level_max[1], skillup = state.skillup[1] };
end

-- The old single tracker list is emptied once its recipes have moved into the first tracker.
local function store_trackers()
    local saved, next_key = trackers.export();
    config.trackers     = saved;
    config.tracker_next = next_key;
    config.tracked      = T{};
end

local function store_config()
    local filters = lasting_filters();
    config.mode        = filters.mode;
    config.craft       = filters.craft;
    config.level_min   = filters.level_min;
    config.level_max   = filters.level_max;
    config.include_sub = state.include_sub[1];
    config.desynth     = state.desynth[1];
    config.support     = state.support;
    config.skillup     = filters.skillup;
    config.tracker     = state.tracker[1];
    store_trackers();
    config.theme       = state.theme;
    config.window_type = state.window_type;
    config.detached    = state.detached;
    config.tabbed      = state.tabbed;
    config.scale       = state.scale;
    config.tracker_alpha = state.tracker_alpha;
    config.tracker_odds  = state.tracker_odds[1];
    config.show_skillups = state.show_skillups[1];
    config.esc_closes    = state.esc_closes[1];
    config.full_names    = state.full_names[1];
    config.cursor_mode   = state.cursor_mode;
    config.hq1         = state.hq_filter[1][1];
    config.hq2         = state.hq_filter[2][1];
    config.hq3         = state.hq_filter[3][1];
    config.icons       = state.icons[1];
end

settings.register('settings', 'settings_update', function (updated)
    if (updated ~= nil) then
        config = updated;
    end
    apply_config();
end);

local function message(text)
    print(chat.header(addon.name) .. chat.message(text));
end

local function reload()
    state.view       = nil;
    state.history    = {};
    state.filter_key = nil;
    icons.release();
    player.invalidate();

    if (db.load()) then
        message(('Loaded %d recipes (%s).'):fmt(#db.recipes, db.meta.source or 'unknown source'));
        return;
    end

    print(chat.header(addon.name) .. chat.error(db.error));
end

-- Favorites are the config table itself, so saving right away keeps them through a crash.
function state.save_favorites()
    state.favorites_rev = state.favorites_rev + 1;
    settings.save();
end

function state.save_settings()
    store_config();
    settings.save();
end

function state.save_layout()
    config.detached = state.detached;
    settings.save();
end

function state.save_theme()
    config.theme = state.theme;
    settings.save();
end

function state.save_tracked()
    store_trackers();
    settings.save();
end

ashita.events.register('load', 'load_cb', function ()
    apply_config();
    prices.load();
    history.load();
    history.tier_of = ui.synth_tier;
    ui.set_state(state);
    reload();
end);

ashita.events.register('unload', 'unload_cb', function ()
    ui.release();
    history.flush();
    store_config();
    settings.save();
    icons.release();
end);

local MAX_LEVEL = 120;

-- "59-67", "59 67" or just "59", then an optional craft.
local function parse_quick_look(text)
    local first, second, craft = text:match('^(%d+)%s*%-?%s*(%d*)%s*(.-)%s*$');
    if (first == nil) then
        return nil, nil, nil;
    end

    local low  = math.min(tonumber(first), MAX_LEVEL);
    local high = low;
    if (second ~= '') then
        high = math.min(tonumber(second), MAX_LEVEL);
    end

    return math.min(low, high), math.max(low, high), craft;
end

-- A craft by its two letter code or the start of its name: "bn", "bone", "leather".
local function find_craft(text)
    local wanted = text:lower();
    for index, craft in ipairs(db.crafts) do
        if (craft.short:lower() == wanted or craft.name:lower():sub(1, #wanted) == wanted) then
            return index;
        end
    end

    return nil;
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    local command = args[1]:lower();
    if (command ~= '/craftbook' and command ~= '/cbook' and command ~= '/cb') then
        return;
    end

    e.blocked = true;

    if (#args == 1) then
        state.visible[1] = not state.visible[1];
        return;
    end

    local sub = args[2]:lower();
    if (sub == 'reload') then
        reload();
        return;
    end

    if (sub == 'settings') then
        state.settings_visible[1] = not state.settings_visible[1];
        return;
    end

    if (sub == 'theme') then
        local key = themes.find(table.concat(args, ' ', 3));
        if (key == nil) then
            message(('Themes: %s. Current: %s.'):fmt(table.concat(themes.names(), ', '), themes.get(state.theme).name));
            return;
        end

        state.theme = key;
        state.save_theme();
        message(('Theme set to %s.'):fmt(themes.get(key).name));
        return;
    end

    if (sub == 'fit') then
        window.fit();
        return;
    end

    if (sub == 'history') then
        state.log_visible[1] = not state.log_visible[1];
        return;
    end

    if (sub == 'track') then
        local name = table.concat(args, ' ', 3);
        if (name == '') then
            state.tracker[1] = not state.tracker[1];
            if (trackers.recipe_count() == 0) then
                message('Nothing tracked yet. Open a recipe and click Track.');
            end
            return;
        end

        local tracker = trackers.find_name(name);
        if (tracker == nil) then
            message(('No tracker called "%s". Trackers: %s.'):fmt(name, table.concat(trackers.names(), ', ')));
            return;
        end
        tracker.open[1]  = not tracker.open[1];
        state.tracker[1] = true;
        state.save_tracked();
        return;
    end

    if (sub == 'lvl' or sub == 'level') then
        local low, high, craft_name = parse_quick_look(table.concat(args, ' ', 3));
        if (low == nil) then
            message('Usage: /craftbook lvl 59-67 or /craftbook lvl 59-67 bone');
            return;
        end

        local craft = nil;
        if (craft_name ~= '') then
            craft = find_craft(craft_name);
            if (craft == nil) then
                message(('No craft matches "%s".'):fmt(craft_name));
                return;
            end
        end

        ui.quick_look(low, high, craft);
        return;
    end

    if (sub == 'help') then
        message('/craftbook or /cb - toggle the window');
        message('/craftbook <name> - open and search, jumping straight to an exact recipe or item match');
        message('/craftbook lvl 59-67 [craft] - open on a level range for this opening only');
        message('/craftbook track - show or hide your trackers');
        message('/craftbook track <name> - open or close one tracker');
        message('/craftbook history - show or hide your synth history');
        message('/craftbook settings - theme, UI scale, icons, layout and tracker options');
        message('/craftbook theme <name> - switch theme (no name lists them)');
        message('/craftbook fit - size the game window to exactly the size the game renders at');
        message('/craftbook reload - reload the data files');
        return;
    end

    ui.search(table.concat(args, ' ', 2));
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    collectgarbage('step', math.max(PACKET_COPY_KB, collectgarbage('count') / HEAP_SHARE));
    history.packet_in(e.id, e.data);
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    history.tick();
    ui.render();
end);
