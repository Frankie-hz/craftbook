require('common');

local MAX_FIELDS = 64;
local MAX_LINES  = 200000;

local db = {
    full_names = false,
    loaded    = false,
    error     = nil,
    meta      = {},
    recipes   = {},
    recipe_by_id = {},
    recipe_by_key = {},
    items     = {},
    item_ids  = {},
    made_by   = {},
    used_in   = {},
    breaks_into = {},
    vendors   = {},
    guilds    = {},
    drops     = {},
    helm      = {},
    mobs      = {},
    zones     = {},
    keyitems  = {},
    cheapest  = {},
    names_ready = false,
};

-- synth_recipes uses 255 for subcraft levels nobody has verified.
db.UNKNOWN_SKILL = 200;

db.crafts = {
    { key = 'wood',    name = 'Woodworking',  short = 'WW' },
    { key = 'smith',   name = 'Smithing',     short = 'SM' },
    { key = 'gold',    name = 'Goldsmithing', short = 'GS' },
    { key = 'cloth',   name = 'Clothcraft',   short = 'CL' },
    { key = 'leather', name = 'Leathercraft', short = 'LC' },
    { key = 'bone',    name = 'Bonecraft',    short = 'BN' },
    { key = 'alchemy', name = 'Alchemy',      short = 'AL' },
    { key = 'cook',    name = 'Cooking',      short = 'CK' },
};

local function to_int(value)
    local number = tonumber(value);
    if (number == nil) then
        return 0;
    end

    return number;
end

local function data_path(name)
    local base = addon.path;
    local last = base:sub(-1);
    if (last ~= '\\' and last ~= '/') then
        base = base .. '\\';
    end

    return base .. 'data\\' .. name;
end

local function split_tabs(line)
    local fields = {};
    local start  = 1;
    for _ = 1, MAX_FIELDS do
        local stop = line:find('\t', start, true);
        if (stop == nil) then
            fields[#fields + 1] = line:sub(start);
            return fields;
        end

        fields[#fields + 1] = line:sub(start, stop - 1);
        start = stop + 1;
    end

    return fields;
end

local function read_tsv(name, on_row)
    local file = io.open(data_path(name), 'r');
    if (file == nil) then
        return false;
    end

    local header = nil;
    local count  = 0;
    for line in file:lines() do
        count = count + 1;
        if (count > MAX_LINES) then
            break;
        end

        local fields = split_tabs((line:gsub('\r$', '')));
        if (header == nil) then
            header = {};
            for index, column in ipairs(fields) do
                header[column] = index;
            end
        else
            local row = {};
            for column, index in pairs(header) do
                row[column] = fields[index];
            end
            on_row(row);
        end
    end

    file:close();
    return true;
end

local function append(map, key, value)
    local list = map[key];
    if (list == nil) then
        list = {};
        map[key] = list;
    end

    list[#list + 1] = value;
end

-- Words a name keeps lowercase unless they start it.
local SMALL_WORDS = { ['a'] = true, ['an'] = true, ['and'] = true, ['for'] = true, ['in'] = true, ['of'] = true, ['on'] = true, ['the'] = true, ['to'] = true, ['with'] = true };

local function title_case(snake)
    local words = {};
    for word in snake:gmatch('[^_]+') do
        if (#words > 0 and SMALL_WORDS[word]) then
            words[#words + 1] = word;
        else
            words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2);
        end
    end

    return table.concat(words, ' ');
end

-- The server's name for an item the game abbreviates: "Blk. Tiger Fang" is black_tiger_fang there. Server names like
-- square_of_silk_cloth drop the container the game leaves out, unless the game's name has it too.
local function full_name(item, short)
    if (item.dbname == '' or short:find('.', 1, true) == nil) then
        return short;
    end

    local base = item.dbname;
    if (short:lower():find(' of ', 1, true) == nil) then
        base = (base:gsub('^%a+_of_', '', 1));
    end

    return title_case(base);
end

local function item_entry(id)
    local item = db.items[id];
    if (item == nil) then
        item = { id = id, basesell = 0, dbname = '' };
        db.items[id] = item;
    end

    return item;
end

local function load_recipes()
    return read_tsv('recipes.tsv', function (row)
        local recipe = {
            id          = to_int(row.id),
            desynth     = row.desynth == '1',
            keyitem     = to_int(row.keyitem),
            skills      = {},
            crystal     = to_int(row.crystal),
            hqcrystal   = to_int(row.hqcrystal),
            result      = to_int(row.result),
            qty         = to_int(row.qty),
            hq          = {},
            ingredients = {},
            ingredient_order = {},
            tag         = row.tag,
            level       = 0,
            main        = 1,
        };

        for index, craft in ipairs(db.crafts) do
            local value = to_int(row[craft.key]);
            recipe.skills[index] = value;
            if (value < db.UNKNOWN_SKILL and value > recipe.level) then
                recipe.level = value;
                recipe.main  = index;
            end
        end

        local by_id = {};
        for token in (row.ingredients or ''):gmatch('%d+') do
            local item_id = tonumber(token);
            local entry   = by_id[item_id];
            recipe.ingredient_order[#recipe.ingredient_order + 1] = item_id;
            if (entry == nil) then
                entry = { id = item_id, count = 0 };
                by_id[item_id] = entry;
                recipe.ingredients[#recipe.ingredients + 1] = entry;
            end
            entry.count = entry.count + 1;
        end

        for tier = 1, 3 do
            recipe.hq[tier] = { id = to_int(row['hq' .. tier]), qty = to_int(row[('hq%dqty'):fmt(tier)]) };
        end

        db.recipes[#db.recipes + 1] = recipe;
    end);
end

-- The server keys recipes by crystal and the ingredients in stored order, the same order a synth result lists them.
local function recipe_key(crystal, ingredients)
    return ('%d:%s'):fmt(crystal, table.concat(ingredients, ','));
end

local function index_recipes()
    for _, recipe in ipairs(db.recipes) do
        db.recipe_by_id[recipe.id] = recipe;
        db.recipe_by_key[recipe_key(recipe.crystal, recipe.ingredient_order)] = recipe;
        if (recipe.hqcrystal ~= 0) then
            db.recipe_by_key[recipe_key(recipe.hqcrystal, recipe.ingredient_order)] = recipe;
        end
        append(db.made_by, recipe.result, { recipe = recipe, tier = 0 });
        for tier = 1, 3 do
            local hq = recipe.hq[tier];
            if (hq.id ~= 0 and hq.id ~= recipe.result) then
                append(db.made_by, hq.id, { recipe = recipe, tier = tier });
            end
        end

        append(db.used_in, recipe.crystal, recipe);
        for _, ingredient in ipairs(recipe.ingredients) do
            -- Breaking an item down is not "using" it as a material, so it gets its own list.
            if (recipe.desynth) then
                append(db.breaks_into, ingredient.id, recipe);
            else
                append(db.used_in, ingredient.id, recipe);
            end
        end
    end
end

local function load_sources()
    read_tsv('items.tsv', function (row)
        local item = item_entry(to_int(row.id));
        item.basesell = to_int(row.basesell);
        item.dbname   = row.dbname or '';
    end);

    read_tsv('vendors.tsv', function (row)
        append(db.vendors, to_int(row.item), {
            price = to_int(row.price),
            kind  = row.kind,
            npc   = row.npc,
            zone  = to_int(row.zone),
            x     = tonumber(row.x),
            y     = tonumber(row.y),
            z     = tonumber(row.z),
            note  = row.note or '',
        });
    end);

    read_tsv('guilds.tsv', function (row)
        append(db.guilds, to_int(row.item), {
            npc      = row.npc,
            zone     = to_int(row.zone),
            x        = tonumber(row.x),
            y        = tonumber(row.y),
            z        = tonumber(row.z),
            price    = to_int(row.price),
            pricemax = to_int(row.pricemax),
            open     = to_int(row.open),
            close    = to_int(row.close),
            holiday  = row.holiday or '',
            stocked  = row.stocked == '1',
            shop     = row.shop or '',
        });
    end);

    read_tsv('mobs.tsv', function (row)
        db.mobs[to_int(row.idx)] = {
            name   = row.name,
            zone   = to_int(row.zone),
            lvmin  = to_int(row.lvmin),
            lvmax  = to_int(row.lvmax),
            nm     = row.nm == '1',
            spawns = to_int(row.spawns),
        };
    end);

    local by_item = {};
    read_tsv('drops.tsv', function (row)
        local item_id = to_int(row.item);
        local mob_idx = to_int(row.mob);
        local mob     = db.mobs[mob_idx];
        if (mob == nil or row.kind == 'despoil') then
            return;
        end

        local per_mob = by_item[item_id];
        if (per_mob == nil) then
            per_mob = {};
            by_item[item_id] = per_mob;
        end

        local entry = per_mob[mob_idx];
        if (entry == nil) then
            entry = { mob = mob, rolls = {}, steal = false, chance = 0 };
            per_mob[mob_idx] = entry;
            append(db.drops, item_id, entry);
        end

        if (row.kind == 'drop') then
            entry.rolls[#entry.rolls + 1] = (tonumber(row.rate) or 0) / 1000;
        elseif (row.kind == 'steal') then
            entry.steal = true;
        end
    end);

    for _, entries in pairs(db.drops) do
        for _, entry in ipairs(entries) do
            local miss = 1;
            for _, roll in ipairs(entry.rolls) do
                miss = miss * (1 - roll);
            end
            entry.chance = 1 - miss;
        end
        table.sort(entries, function (a, b)
            if (a.chance ~= b.chance) then
                return a.chance > b.chance;
            end
            return a.mob.lvmin < b.mob.lvmin;
        end);
    end

    read_tsv('helm.tsv', function (row)
        append(db.helm, to_int(row.item), {
            zone = to_int(row.zone),
            kind = row.type,
            rate = (tonumber(row.rate) or 0) / 1000,
        });
    end);

    read_tsv('zones.tsv', function (row)
        db.zones[to_int(row.id)] = row.name;
    end);

    read_tsv('keyitems.tsv', function (row)
        db.keyitems[to_int(row.id)] = row.name;
    end);

    read_tsv('meta.tsv', function (row)
        db.meta[row.key] = row.value;
    end);
end

local function sort_vendors()
    for _, rows in pairs(db.vendors) do
        table.sort(rows, function (a, b)
            if (a.price ~= b.price) then
                return a.price < b.price;
            end
            return a.npc < b.npc;
        end);
    end
end

local function index_cheapest()
    for item_id, rows in pairs(db.vendors) do
        for _, row in ipairs(rows) do
            local best = db.cheapest[item_id];
            if (best == nil or row.price < best.price) then
                db.cheapest[item_id] = { price = row.price, npc = row.npc, zone = row.zone };
            end
        end
    end

    for item_id, rows in pairs(db.guilds) do
        for _, row in ipairs(rows) do
            local best = db.cheapest[item_id];
            if (row.stocked and (best == nil or row.price < best.price)) then
                db.cheapest[item_id] = { price = row.price, npc = row.npc, zone = row.zone, guild = true };
            end
        end
    end
end

function db.load()
    db.loaded      = false;
    db.error       = nil;
    db.names_ready = false;
    db.meta        = {};
    db.recipes     = {};
    db.recipe_by_id = {};
    db.recipe_by_key = {};
    db.items       = {};
    db.item_ids    = {};
    db.made_by     = {};
    db.used_in     = {};
    db.breaks_into = {};
    db.vendors     = {};
    db.guilds      = {};
    db.drops       = {};
    db.helm        = {};
    db.mobs        = {};
    db.zones       = {};
    db.keyitems    = {};
    db.cheapest    = {};

    if (not load_recipes()) then
        db.error = 'Missing data\\recipes.tsv. Run tools\\build_data.py to generate the data files.';
        return false;
    end

    load_sources();
    index_recipes();
    sort_vendors();
    index_cheapest();

    for _, recipe in ipairs(db.recipes) do
        item_entry(recipe.result);
        item_entry(recipe.crystal);
        for _, ingredient in ipairs(recipe.ingredients) do
            item_entry(ingredient.id);
        end
    end

    db.loaded = true;
    return true;
end

function db.find_recipe(crystal, ingredients)
    return db.recipe_by_key[recipe_key(crystal, ingredients)];
end

function db.item_name(id)
    local item = item_entry(id);
    if (item.name ~= nil) then
        return item.name;
    end

    local short    = nil;
    local resource = AshitaCore:GetResourceManager():GetItemById(id);
    if (resource ~= nil and resource.Name ~= nil and resource.Name[1] ~= nil and resource.Name[1] ~= '') then
        short = resource.Name[1];
    elseif (item.dbname ~= '') then
        short = title_case(item.dbname);
    else
        short = ('Item #%d'):fmt(id);
    end

    local full = full_name(item, short);
    item.name = short;
    if (db.full_names) then
        item.name = full;
    end
    item.lname  = item.name:lower();
    item.search = ('%s|%s'):fmt(short:lower(), full:lower());
    return item.name;
end

-- How many of an item make a stack, from the game's item data. 1 when it does not stack or is unknown.
function db.stack_size(id)
    local item = item_entry(id);
    if (item.stack == nil) then
        item.stack = 1;
        local resource = AshitaCore:GetResourceManager():GetItemById(id);
        if (resource ~= nil and resource.StackSize ~= nil and resource.StackSize > 1) then
            item.stack = resource.StackSize;
        end
    end

    return item.stack;
end

-- Both of an item's names in lowercase, so a search finds "Blk. Tiger Fang" by "black tiger" too.
function db.item_search(id)
    local item = item_entry(id);
    if (item.search == nil) then
        db.item_name(id);
    end

    return item.search;
end

-- Returns true when the setting changed. Names, their order and the search lists rebuild on the next prepare_names.
function db.set_full_names(on)
    if (db.full_names == on) then
        return false;
    end

    db.full_names = on;
    for _, item in pairs(db.items) do
        item.name = nil;
    end
    db.names_ready = false;
    return true;
end

function db.item_lname(id)
    local item = item_entry(id);
    if (item.lname == nil) then
        db.item_name(id);
    end

    return item.lname;
end

function db.item_description(id)
    local resource = AshitaCore:GetResourceManager():GetItemById(id);
    if (resource == nil or resource.Description == nil or resource.Description[1] == nil) then
        return '';
    end

    return resource.Description[1];
end

function db.zone_name(id)
    local name = AshitaCore:GetResourceManager():GetString('zones.names', id);
    if (name ~= nil and name ~= '') then
        return name;
    end

    local fallback = db.zones[id];
    if (fallback ~= nil) then
        return fallback;
    end

    return ('Zone %d'):fmt(id);
end

function db.keyitem_name(id)
    local name = AshitaCore:GetResourceManager():GetString('keyitems.names', id);
    if (name ~= nil and name ~= '') then
        return name;
    end

    local fallback = db.keyitems[id];
    if (fallback ~= nil) then
        return fallback;
    end

    return ('Key Item #%d'):fmt(id);
end

-- Resolving every name once up front keeps searching allocation-free per frame.
function db.prepare_names()
    if (db.names_ready or not db.loaded) then
        return;
    end

    db.item_ids = {};
    for id, _ in pairs(db.items) do
        db.item_name(id);
        db.item_ids[#db.item_ids + 1] = id;
    end

    table.sort(db.item_ids, function (a, b)
        return db.items[a].lname < db.items[b].lname;
    end);

    for _, recipe in ipairs(db.recipes) do
        recipe.search_result = db.item_lname(recipe.result);
        recipe.match_result  = db.item_search(recipe.result);

        local parts = {};
        for _, ingredient in ipairs(recipe.ingredients) do
            parts[#parts + 1] = db.item_search(ingredient.id);
        end
        -- The materials alone, which for a desynthesis is the item being broken down.
        recipe.match_source = table.concat(parts, '|');
        parts[#parts + 1] = db.item_search(recipe.crystal);
        recipe.match_ingredients = table.concat(parts, '|');
    end

    db.names_ready = true;
end

return db;
