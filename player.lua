require('common');

local REFRESH_SECONDS = 2;
local MAX_SLOTS       = 81;

-- Inventory, Safe, Storage, Locker, Satchel, Sack, Case, Safe 2. Wardrobes hold only equipment.
local CONTAINERS = { 0, 1, 2, 4, 5, 6, 7, 9 };

-- Crafting image support shows as one imagery status (236 Woodworking through 243 Cooking, craft order).
-- Standard support lasts 120 s at +1, advanced support and craft belts 480 s at +3 (image_support.lua).
local IMAGERY_FIRST     = 236;
local IMAGERY_LAST      = 243;
local STANDARD_SECONDS  = 150;
local STATUS_SLOTS      = 32;
local INFINITE_DURATION = 0x7FFFFFFF;
local VANA_BASE_STAMP   = 0x3C307D70;

-- Same signature the statustimers and focustarget addons use to turn status timers into seconds.
local utcstamp_pointer = ashita.memory.find('FFXiMain.dll', 0, '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);

local player = {
    bag     = {},
    total   = {},
    skills  = {},
    capped  = {},
    imagery = nil,
    updated = -REFRESH_SECONDS,
};

local function read_skill(memory_player, craft_index)
    local ok, value = pcall(function ()
        return memory_player:GetCraftSkill(craft_index):GetSkill();
    end);
    if (not ok or type(value) ~= 'number') then
        return nil;
    end

    return value;
end

local function read_capped(memory_player, craft_index)
    local ok, value = pcall(function ()
        return memory_player:GetCraftSkill(craft_index):IsCapped();
    end);

    return ok and value == true;
end

local function utcstamp()
    if (utcstamp_pointer == 0) then
        return nil;
    end

    local pointer = ashita.memory.read_uint32(utcstamp_pointer);
    pointer = ashita.memory.read_uint32(pointer);
    return ashita.memory.read_uint32(pointer + 0x0C);
end

local function seconds_left(raw_timer)
    local stamp = utcstamp();
    if (raw_timer == nil or raw_timer == INFINITE_DURATION or stamp == nil) then
        return nil;
    end

    local remaining = raw_timer - (stamp - VANA_BASE_STAMP) * 60;
    while (remaining < -2147483648) do
        remaining = remaining + 0xFFFFFFFF;
    end

    return math.max(0, math.ceil(remaining / 60));
end

local function find_imagery(memory_player)
    local icons  = memory_player:GetStatusIcons();
    local timers = memory_player:GetStatusTimers();
    for slot = 1, STATUS_SLOTS do
        local id = icons[slot];
        if (id ~= nil and id >= IMAGERY_FIRST and id <= IMAGERY_LAST) then
            return { craft = id - IMAGERY_FIRST + 1, seconds = seconds_left(timers[slot]) };
        end
    end

    return nil;
end

-- The strength is read once, from how long the buff had left when it appeared or was renewed.
local function refresh_imagery(memory_player)
    local found = find_imagery(memory_player);
    if (found == nil) then
        player.imagery = nil;
        return;
    end

    local known   = player.imagery;
    local renewed = known ~= nil and found.seconds ~= nil and known.seconds ~= nil and found.seconds > known.seconds + 5;
    if (known == nil or known.craft ~= found.craft or renewed) then
        local power = nil;
        if (found.seconds ~= nil and found.seconds > STANDARD_SECONDS) then
            power = 3;
        elseif (found.seconds ~= nil) then
            power = 1;
        end
        player.imagery = { craft = found.craft, power = power, seconds = found.seconds };
        return;
    end

    known.seconds = found.seconds;
end

local function refresh_skills(craft_count)
    player.skills = {};
    player.capped = {};

    local memory_player = AshitaCore:GetMemoryManager():GetPlayer();
    if (memory_player == nil or memory_player:GetMainJobLevel() == 0) then
        return;
    end

    for index = 1, craft_count do
        player.skills[index] = read_skill(memory_player, index);
        player.capped[index] = read_capped(memory_player, index);
    end

    local ok = pcall(refresh_imagery, memory_player);
    if (not ok) then
        player.imagery = nil;
    end
end

local function refresh_items()
    local bag   = {};
    local total = {};

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if (inventory == nil) then
        player.bag   = bag;
        player.total = total;
        return;
    end

    for _, container in ipairs(CONTAINERS) do
        local slots = math.min(inventory:GetContainerCountMax(container), MAX_SLOTS - 1);
        for index = 0, slots do
            local item = inventory:GetContainerItem(container, index);
            if (item ~= nil and item.Id ~= 0 and item.Id ~= 65535) then
                total[item.Id] = (total[item.Id] or 0) + item.Count;
                if (container == 0) then
                    bag[item.Id] = (bag[item.Id] or 0) + item.Count;
                end
            end
        end
    end

    player.bag   = bag;
    player.total = total;
end

function player.refresh(craft_count)
    local now = os.clock();
    if (now - player.updated < REFRESH_SECONDS) then
        return;
    end

    player.updated = now;
    refresh_skills(craft_count);
    refresh_items();
end

function player.invalidate()
    player.updated = -REFRESH_SECONDS;
end

function player.skill(craft_index)
    return player.skills[craft_index];
end

-- The client flags a craft once it reaches its rank cap; the server stops skill-ups there.
function player.is_capped(craft_index)
    return player.capped[craft_index] == true;
end

function player.count(item_id)
    return player.bag[item_id] or 0, player.total[item_id] or 0;
end

return player;
