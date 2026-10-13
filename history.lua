require('common');

local db = require('db');

local RESULT_PACKET = 0x06F;
local MAX_ENTRIES   = 20000;
local MAX_LINES     = 200000;
local MAX_MATERIALS = 8;

-- Skill-ups follow the result in the same server tick (doSynthSkillUp after the result packet) as a
-- battle message: MsgBasic SkillGain 38, Data = skill id (49 Woodworking to 56 Cooking), Data2 = tenths.
local BATTLE_MESSAGE  = 0x029;
local SKILL_GAIN      = 38;
local FIRST_CRAFT     = 49;
local LAST_CRAFT      = 56;
local SKILLUP_WINDOW  = 3;

-- SynthesisResult codes worth logging; cancels never consumed anything.
local SUCCESS      = { [0x00] = true, [0x0C] = true };
local BREAK        = 0x01;
local INTERRUPTED  = { [0x02] = true, [0x0E] = true };

local history = {
    entries = {},
    -- The newest entry stays open for skill-ups before it is written to the file.
    held    = nil,
    held_at = 0,
    -- Set by the UI: returns the recipe's HQ tier (0-3) at the player's current skill, or nil.
    tier_of = nil,
};

local function file_path()
    return ('%s\\config\\addons\\%s\\history.tsv'):fmt(AshitaCore:GetInstallPath(), addon.name);
end

local function character_name()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil) then
        return '';
    end

    return party:GetMemberName(0) or '';
end

local function u16(data, offset)
    return data:byte(offset + 1) + data:byte(offset + 2) * 256;
end

-- Phoenix leaves the packet's Grade byte empty, so the grade comes from matching the result against the recipe.
local function grade_of(recipe, item, qty)
    if (item == recipe.result and qty == recipe.qty) then
        return 'NQ';
    end

    local first = nil;
    local last  = nil;
    for tier = 1, 3 do
        local hq = recipe.hq[tier];
        if (hq.id == item and hq.qty == qty) then
            first = first or tier;
            last  = tier;
        end
    end
    if (first == nil) then
        return 'Success';
    end
    if (first == last) then
        return ('HQ%d'):fmt(first);
    end

    -- Several grades give the same item and quantity, so only the lowest one is certain.
    return ('HQ%d+'):fmt(first);
end

local function outcome_of(result, recipe, item, qty)
    if (result == BREAK) then
        return 'Break';
    end
    if (INTERRUPTED[result]) then
        return 'Interrupted';
    end
    if (recipe == nil) then
        return 'Success';
    end
    if (recipe.desynth) then
        return 'Desynth';
    end

    return grade_of(recipe, item, qty);
end

local function parse(data)
    local result = data:byte(5);
    if (not SUCCESS[result] and result ~= BREAK and not INTERRUPTED[result]) then
        return nil;
    end

    local materials = {};
    local lost      = 0;
    for index = 0, MAX_MATERIALS - 1 do
        local material = u16(data, 36 + index * 2);
        if (material ~= 0) then
            materials[#materials + 1] = material;
        end
        if (u16(data, 10 + index * 2) ~= 0) then
            lost = lost + 1;
        end
    end

    local recipe = db.find_recipe(u16(data, 34), materials);
    local item   = u16(data, 8);
    local qty    = data:byte(7);
    if (not SUCCESS[result]) then
        item = 0;
        qty  = 0;
    end

    local tier = -1;
    if (recipe ~= nil and history.tier_of ~= nil) then
        tier = history.tier_of(recipe) or -1;
    end

    local recipe_id = 0;
    if (recipe ~= nil) then
        recipe_id = recipe.id;
    end

    return {
        time    = os.time(),
        char    = character_name(),
        recipe  = recipe_id,
        item    = item,
        qty     = qty,
        outcome = outcome_of(result, recipe, item, qty),
        tier    = tier,
        lost    = lost,
        skillups = {},
    };
end

local function skillups_text(skillups)
    local parts = {};
    for craft = 1, LAST_CRAFT - FIRST_CRAFT + 1 do
        if (skillups[craft] ~= nil) then
            parts[#parts + 1] = ('%d:%d'):fmt(craft, skillups[craft]);
        end
    end

    return table.concat(parts, ',');
end

local function parse_skillups(text)
    local skillups = {};
    for craft, tenths in (text or ''):gmatch('(%d+):(%d+)') do
        skillups[tonumber(craft)] = tonumber(tenths);
    end

    return skillups;
end

local function to_line(entry)
    return ('%d\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%s\n'):fmt(entry.time, entry.char, entry.recipe, entry.item, entry.qty, entry.outcome, entry.tier, entry.lost, skillups_text(entry.skillups));
end

local function write(entry)
    local file = io.open(file_path(), 'a');
    if (file ~= nil) then
        file:write(to_line(entry));
        file:close();
    end
end

-- Writes the open entry; called when the next result lands, its skill-up window closes, or the addon unloads.
function history.flush()
    if (history.held == nil) then
        return;
    end

    write(history.held);
    history.held = nil;
end

local function add(entry)
    history.entries[#history.entries + 1] = entry;
    if (#history.entries > MAX_ENTRIES) then
        table.remove(history.entries, 1);
    end
    history.revision = (history.revision or 0) + 1;
end

function history.load()
    history.entries = {};

    local file = io.open(file_path(), 'r');
    if (file == nil) then
        return;
    end

    local count = 0;
    for line in file:lines() do
        count = count + 1;
        if (count > MAX_LINES) then
            break;
        end

        local time, char, recipe, item, qty, outcome, tier, lost, skillups = line:match('^(%d+)\t([^\t]*)\t(%d+)\t(%d+)\t(%d+)\t([^\t]+)\t(%-?%d+)\t(%d+)\t?([%d:,]*)');
        if (time ~= nil) then
            add({
                time    = tonumber(time),
                char    = char,
                recipe  = tonumber(recipe),
                item    = tonumber(item),
                qty     = tonumber(qty),
                outcome = outcome,
                tier    = tonumber(tier),
                lost    = tonumber(lost),
                skillups = parse_skillups(skillups),
            });
        end
    end

    file:close();
end

local function u32(data, offset)
    return u16(data, offset) + u16(data, offset + 2) * 65536;
end

local function on_skill_gain(data)
    local entry = history.held;
    if (entry == nil or os.clock() - history.held_at > SKILLUP_WINDOW) then
        return;
    end

    local skill = u32(data, 12);
    if (skill < FIRST_CRAFT or skill > LAST_CRAFT) then
        return;
    end

    local craft = skill - FIRST_CRAFT + 1;
    entry.skillups[craft] = (entry.skillups[craft] or 0) + u32(data, 16);
    history.revision = (history.revision or 0) + 1;
end

function history.packet_in(id, data)
    if (data == nil) then
        return;
    end
    if (id == BATTLE_MESSAGE and #data >= 26 and u16(data, 24) == SKILL_GAIN) then
        on_skill_gain(data);
        return;
    end
    if (id ~= RESULT_PACKET or #data < 52) then
        return;
    end

    local entry = parse(data);
    if (entry == nil) then
        return;
    end

    history.flush();
    add(entry);
    history.held    = entry;
    history.held_at = os.clock();
end

function history.tick()
    if (history.held ~= nil and os.clock() - history.held_at > SKILLUP_WINDOW) then
        history.flush();
    end
end

function history.character()
    return character_name();
end

return history;
