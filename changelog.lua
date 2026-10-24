require('common');

local MAX_VERSION_PARTS = 4;

-- What changed in each version, newest first, grouped as new, changed and fixed. After an update a player sees, once,
-- every version newer than the last one shown on this install. /cb changelog shows them all. These notes ship in the
-- public build, so they never mention anything it leaves out. A version without a date is not released yet.
local ENTRIES = {
    {
        version = '1.3',
        new = {
            'Trackers: keep several saved recipe lists, like one for Leather and one for Field gear. Open each from the new Trackers button or with /cb track <name>.',
            'Track on a recipe page asks which tracker gets the recipe, or starts a new one.',
            'Drag a recipe onto another tracker to move it, or onto another row to reorder. Right-click a tracker\'s name to rename it, turn its odds column on or off, or delete it. The x closes it.',
            'Materials have a My stack box: type what a stack costs and craftbook works out the price for one.',
            'This window. It shows once after each update, and /cb changelog or Settings > Changelog opens it again.',
        },
        changed = {
            'Favorites moved to a button beside What-if. Click it again to go back.',
            'Trackers and the Have column turn yellow when some of what you need is in your satchel, sack, case or storage.',
            'The level filter now defaults to 0 to 106.',
        },
    },
    {
        version = '1.2.1',
        date    = 'October 17, 2026',
        fixed = {
            'A memory leak that crashed the game after a while, mostly on Linux.',
        },
    },
    {
        version = '1.2',
        date    = 'October 17, 2026',
        new = {
            'Settings > Full item names shows "Black Tiger Fang" instead of "Blk. Tiger Fang". Search finds items by either name.',
            'Settings > Recipe page can show the recipe as a tab next to the list.',
        },
        changed = {
            'Dragging one craftbook window onto another no longer docks them, which broke their look.',
        },
        fixed = {
            'A crash after browsing many items with icons on.',
            'Two mouse cursors over craftbook. It now only draws its own when the game\'s would be hidden.',
        },
    },
    {
        version = '1.1',
        date    = 'October 15, 2026',
        new = {
            'Profit shows the margin next to the gil.',
            'The Avg row shows the average profit per synth at your HQ tier, or at T0 to T3.',
            'Made: type how many of each result you got to total what those synths made you.',
        },
        fixed = {
            'A crash when hovering some tooltips.',
        },
    },
    {
        version = '1.0',
        date    = 'October 12, 2026',
        new = {
            'First release.',
        },
    },
};

local changelog = {};

local function folder()
    return ('%s\\config\\addons\\%s\\'):fmt(AshitaCore:GetInstallPath(), addon.name);
end

local function seen_path()
    return folder() .. 'changelog_seen.txt';
end

-- -1, 0 or 1, comparing "1.2.1" against "1.3" part by part.
local function compare(a, b)
    local left  = {};
    local right = {};
    for number in a:gmatch('%d+') do
        left[#left + 1] = tonumber(number);
    end
    for number in b:gmatch('%d+') do
        right[#right + 1] = tonumber(number);
    end

    for index = 1, MAX_VERSION_PARTS do
        local x = left[index] or 0;
        local y = right[index] or 0;
        if (x ~= y) then
            if (x < y) then
                return -1;
            end
            return 1;
        end
    end

    return 0;
end

local function read_seen()
    local file = io.open(seen_path(), 'r');
    if (file == nil) then
        return nil;
    end

    local seen = file:read('*l');
    file:close();
    if (seen == nil or seen:match('^%d+[%.%d]*$') == nil) then
        return nil;
    end

    return seen;
end

function changelog.all()
    return ENTRIES;
end

-- The notes to show after an update: versions newer than the one last shown here, up to this one. An install that
-- has never shown a changelog gets this version's notes alone.
function changelog.pending(current)
    local seen = read_seen();
    local list = {};
    for _, entry in ipairs(ENTRIES) do
        if (compare(entry.version, current) <= 0) then
            if (seen == nil) then
                list[1] = entry;
                return list;
            end
            if (compare(entry.version, seen) > 0) then
                list[#list + 1] = entry;
            end
        end
    end

    return list;
end

function changelog.mark_seen(current)
    if (read_seen() == current) then
        return;
    end
    if (not ashita.fs.exists(folder())) then
        ashita.fs.create_dir(folder());
    end

    local file = io.open(seen_path(), 'w');
    if (file ~= nil) then
        file:write(current, '\n');
        file:close();
    end
end

return changelog;
