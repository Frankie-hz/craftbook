require('common');

local MAX_TRACKERS = 20;
local MAX_RECIPES  = 8;
local MAX_NAME     = 32;

-- Saved recipe lists, each shown as its own note while open. Every tracker has a key that never changes, so its
-- window keeps its place on screen when others are deleted or renamed.
local trackers = {
    max_recipes = MAX_RECIPES,
    list        = {},
    next_key    = 1,
};

local function copy(list)
    local result = {};
    for index, value in ipairs(list) do
        result[index] = value;
    end

    return result;
end

local function make(key, name, recipes, open)
    return { key = key, name = name, recipes = copy(recipes), open = { open } };
end

local function name_taken(name)
    for _, tracker in ipairs(trackers.list) do
        if (tracker.name:lower() == name:lower()) then
            return true;
        end
    end

    return false;
end

-- Fills the list from settings. A character from before multiple trackers gets its one list as "Tracker".
function trackers.load(saved, next_key, legacy_recipes)
    trackers.list     = {};
    trackers.next_key = math.max(1, next_key or 1);

    for _, entry in ipairs(saved or {}) do
        if (#trackers.list < MAX_TRACKERS and entry.key ~= nil and entry.name ~= nil) then
            trackers.list[#trackers.list + 1] = make(entry.key, entry.name, entry.recipes or {}, entry.open == true);
            trackers.next_key = math.max(trackers.next_key, entry.key + 1);
        end
    end

    if (#trackers.list == 0) then
        trackers.list[1] = make(trackers.next_key, 'Tracker', legacy_recipes or {}, true);
        trackers.next_key = trackers.next_key + 1;
    end
end

-- The list as settings store it.
function trackers.export()
    local saved = {};
    for index, tracker in ipairs(trackers.list) do
        saved[index] = { key = tracker.key, name = tracker.name, recipes = copy(tracker.recipes), open = tracker.open[1] };
    end

    return saved, trackers.next_key;
end

function trackers.create()
    if (#trackers.list >= MAX_TRACKERS) then
        return nil;
    end

    local number = #trackers.list + 1;
    local name   = ('Tracker %d'):fmt(number);
    for _ = 1, MAX_TRACKERS do
        if (not name_taken(name)) then
            break;
        end
        number = number + 1;
        name   = ('Tracker %d'):fmt(number);
    end

    local tracker = make(trackers.next_key, name, {}, true);
    trackers.next_key = trackers.next_key + 1;
    trackers.list[#trackers.list + 1] = tracker;
    return tracker;
end

function trackers.delete(key)
    for index, tracker in ipairs(trackers.list) do
        if (tracker.key == key) then
            table.remove(trackers.list, index);
            return;
        end
    end
end

function trackers.rename(tracker, name)
    local trimmed = name:gsub('^%s+', ''):gsub('%s+$', '');
    if (trimmed == '') then
        return;
    end

    tracker.name = trimmed:sub(1, MAX_NAME);
end

function trackers.find_key(key)
    for _, tracker in ipairs(trackers.list) do
        if (tracker.key == key) then
            return tracker;
        end
    end

    return nil;
end

-- By name, ignoring case: an exact match first, otherwise the first name that starts with the text.
function trackers.find_name(text)
    local wanted = text:lower();
    for _, tracker in ipairs(trackers.list) do
        if (tracker.name:lower() == wanted) then
            return tracker;
        end
    end
    for _, tracker in ipairs(trackers.list) do
        if (tracker.name:lower():sub(1, #wanted) == wanted) then
            return tracker;
        end
    end

    return nil;
end

function trackers.names()
    local names = {};
    for index, tracker in ipairs(trackers.list) do
        names[index] = tracker.name;
    end

    return names;
end

function trackers.index_of(tracker, recipe_id)
    for index, id in ipairs(tracker.recipes) do
        if (id == recipe_id) then
            return index;
        end
    end

    return nil;
end

-- How many trackers hold the recipe.
function trackers.holding(recipe_id)
    local count = 0;
    for _, tracker in ipairs(trackers.list) do
        if (trackers.index_of(tracker, recipe_id) ~= nil) then
            count = count + 1;
        end
    end

    return count;
end

function trackers.is_full(tracker)
    return #tracker.recipes >= MAX_RECIPES;
end

-- Adds the recipe, or removes it when it is already there. Returns false when the tracker is full.
function trackers.toggle(tracker, recipe_id)
    local index = trackers.index_of(tracker, recipe_id);
    if (index ~= nil) then
        table.remove(tracker.recipes, index);
        return true;
    end
    if (trackers.is_full(tracker)) then
        return false;
    end

    tracker.recipes[#tracker.recipes + 1] = recipe_id;
    return true;
end

function trackers.remove_at(tracker, index)
    table.remove(tracker.recipes, index);
end

-- Moves a recipe from one tracker to another, or to a new place in the same one. `before` is the row it lands on,
-- nil for the end. A tracker that already holds it or is full keeps it where it was.
function trackers.move(recipe_id, from_key, to_key, before)
    local source = trackers.find_key(from_key);
    local target = trackers.find_key(to_key);
    if (source == nil or target == nil) then
        return false;
    end

    local from = trackers.index_of(source, recipe_id);
    if (from == nil) then
        return false;
    end
    if (source ~= target and (trackers.index_of(target, recipe_id) ~= nil or trackers.is_full(target))) then
        return false;
    end

    local place = before;
    table.remove(source.recipes, from);
    if (source == target and place ~= nil and place > from) then
        place = place - 1;
    end
    if (place == nil or place > #target.recipes + 1) then
        place = #target.recipes + 1;
    end
    table.insert(target.recipes, place, recipe_id);
    return true;
end

function trackers.any_open()
    for _, tracker in ipairs(trackers.list) do
        if (tracker.open[1]) then
            return true;
        end
    end

    return false;
end

function trackers.recipe_count()
    local count = 0;
    for _, tracker in ipairs(trackers.list) do
        count = count + #tracker.recipes;
    end

    return count;
end

return trackers;
