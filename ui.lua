require('common');

local bit    = require('bit');
local imgui  = require('imgui');
local db     = require('db');
local icons  = require('icons');
local player = require('player');
local prices = require('prices');
local history = require('history');
local themes  = require('themes');
local skin    = require('skin');

-- Ashita's SetTooltip reads its text as a printf format, so a % in it shows garbage or crashes the client.
-- Text is drawn as written.
local function set_tooltip(text)
    imgui.BeginTooltip();
    imgui.Text(text);
    imgui.EndTooltip();
end

local MAX_RESULTS = 500;
local MAX_ROWS    = 300;
local MAX_HISTORY = 64;
local MAX_WORDS   = 8;
local LIST_ICONS  = 150;

local MODES = { 'Results', 'Ingredients', 'Items', 'Favorites', 'My prices' };

local MODE_RESULTS     = 1;
local MODE_INGREDIENTS = 2;
local MODE_ITEMS       = 3;
local MODE_FAVORITES   = 4;
local MODE_PRICES      = 5;

local SUPPORT_BONUS = { [0] = 0, [1] = 1, [2] = 3 };

-- Base HQ chance by the lowest tier across every craft the recipe uses (synthutils calculateSynthResult).
local HQ_CHANCE = { [0] = 0.015625, [1] = 0.0625, [2] = 0.25, [3] = 0.50 };
local HQ_CAP    = 0.80;

local DESYNTH_HQ_CHANCE = 0.60;
local SKILLUP_GAP       = 5;

-- Must match the server's map.CRAFT_MODERN_SYSTEM (synthutils doSynthSkillUp).
local MODERN_SKILLUPS = false;

local DESYNTH_SKILLUP_CHANCE = 0.05;
local SKILLUP_BREAK_WINDOW   = 5;
local BIG_GAINS_BELOW_SKILL  = 60;

-- Percent chance of +0.1 through +0.5 once a skill-up happens, by recipe level minus skill (0 through 14+).
local SKILLUP_WEIGHTS = {
    { 85, 15, 0, 0, 0 },
    { 85, 15, 0, 0, 0 },
    { 85, 15, 0, 0, 0 },
    { 80, 20, 0, 0, 0 },
    { 80, 20, 0, 0, 0 },
    { 70, 30, 0, 0, 0 },
    { 70, 30, 0, 0, 0 },
    { 60, 40, 0, 0, 0 },
    { 60, 40, 0, 0, 0 },
    { 50, 40, 10, 0, 0 },
    { 40, 40, 20, 0, 0 },
    { 40, 40, 20, 0, 0 },
    { 15, 45, 30, 10, 0 },
    { 10, 40, 25, 25, 0 },
    { 0, 40, 30, 20, 10 },
};
local SINGLE_POINT = { 100, 0, 0, 0, 0 };

local CRYSTAL_IDS ={ [4096] = true, [4097] = true, [4098] = true, [4099] = true, [4100] = true, [4101] = true, [4102] = true, [4103] = true };

-- Meaning colors (title, good, warn, bad, hq, keyitem, support), refilled from the active theme.
local COLORS = {};

local active_theme = nil;

local function use_theme(theme)
    active_theme = theme;
    for key, color in pairs(theme.semantic) do
        COLORS[key] = color;
    end
end

use_theme(themes.get('default'));

-- Classic only: paints the game's window art behind the window that was just begun.
local function draw_skin(titled, alpha)
    if (active_theme.skin ~= nil) then
        skin.draw(active_theme.skin, titled, alpha);
    end
end

-- ---------------------------------------------------------------------------
-- Sizes that follow the active theme's padding instead of fixed pixels
-- ---------------------------------------------------------------------------

local PRICE_DIGITS = 7;

local function zeros_width(count)
    return imgui.CalcTextSize(string.rep('0', count));
end

-- An InputInt showing `digits` digits beside its - and + buttons.
local function int_input_width(digits)
    local style   = imgui.GetStyle();
    local buttons = (imgui.GetFrameHeight() + style.ItemInnerSpacing.x) * 2;
    return zeros_width(digits) + style.FramePadding.x * 2 + buttons;
end

local function price_input_width()
    return zeros_width(PRICE_DIGITS) + imgui.GetStyle().FramePadding.x * 2;
end

local function button_width(label)
    local style = imgui.GetStyle();
    return imgui.CalcTextSize(label) + (style.FramePadding.x + style.FrameBorderSize) * 2;
end

-- The addon's shared state table, handed over by ui.set_state.
local state = nil;

-- The font size before any craftbook scaling, read once.
local font_base = nil;

local function ui_scale()
    if (state == nil) then
        return 1;
    end

    return state.scale or 1;
end

-- A pixel size at the player's UI scale.
local function px(value)
    return math.floor(value * ui_scale() + 0.5);
end

-- True while the table being set up fits its fixed columns to their contents (see begin_fit_table).
local fitting = false;

-- Fixed columns grow to fit their header and sort arrow, so a roomier theme never truncates them.
local function setup_column(label, flags, width)
    if (fitting and bit.band(flags, ImGuiTableColumnFlags_WidthFixed) ~= 0) then
        imgui.TableSetupColumn(label, flags);
        return;
    end
    if (width ~= nil and bit.band(flags, ImGuiTableColumnFlags_WidthFixed) ~= 0) then
        local header = imgui.CalcTextSize((label:gsub('##.*', ''))) + imgui.GetFontSize() + imgui.GetStyle().CellPadding.x * 2;
        width = math.max(px(width), header);
    end

    imgui.TableSetupColumn(label, flags, width);
end

local FIT_FLAGS   = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_SizingFixedFit);
local LIST_FLAGS  = bit.bor(FIT_FLAGS, ImGuiTableFlags_Resizable, ImGuiTableFlags_ScrollY);

-- A table with draggable columns that start at the widths setup_column is given.
local function begin_table(id, columns, flags, size)
    fitting = false;
    return imgui.BeginTable(id, columns, flags, size);
end

-- The recipe or item on screen, as a suffix that makes each page's tables their own.
local function page_key()
    local view = state.view;
    if (view == nil) then
        return 'none';
    end
    if (view.kind == 'recipe') then
        return ('r%d'):fmt(view.recipe.id);
    end

    return ('i%d'):fmt(view.id);
end

-- A detail table: draggable columns that start fitted to their contents. ImGui fits a resizable column only when
-- its table first appears, so each page gets its own table and its widths are not written to the settings file.
local function begin_fit_table(id, columns, extra_flags)
    local flags = bit.bor(FIT_FLAGS, ImGuiTableFlags_Resizable, ImGuiTableFlags_NoSavedSettings, extra_flags or 0);
    fitting = imgui.BeginTable(('%s@%s'):fmt(id, page_key()), columns, flags);
    return fitting;
end
local SORT_FLAGS  = bit.bor(ImGuiTableFlags_Sortable, ImGuiTableFlags_SortTristate);

local TRACKER_FLAGS = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav);
local MAX_TRACKED   = 8;
local TRACKER_TABLE_FLAGS = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_BordersInnerV);
local COMBO_PADDING  = 8;

local AH_INPUT_CHARS = 10;

local ui = {};

local link_id = 0;

-- Sorted copies per table, rebuilt only when the rows or the clicked header change.
local sort_cache = {};

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function commas(value)
    local text   = tostring(math.floor(value));
    local result = text:reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (result:gsub('^,', ''));
end

local function signed_commas(value)
    if (value < 0) then
        return '-' .. commas(-value);
    end

    return '+' .. commas(value);
end

local function percent(fraction)
    local value = fraction * 100;
    if (value == 0) then
        return '0%';
    end
    if (value >= 10) then
        return ('%d%%'):fmt(math.floor(value + 0.5));
    end
    if (value >= 1) then
        return ('%.1f%%'):fmt(value);
    end

    return ('%.2f%%'):fmt(value);
end

local function level_range(low, high)
    if (low == 0 and high == 0) then
        return '?';
    end
    if (low == high) then
        return tostring(low);
    end

    return ('%d-%d'):fmt(low, high);
end

local function level_color(level, skill)
    if (skill == nil) then
        return nil;
    end
    if (level <= skill) then
        return COLORS.good;
    end
    if (level <= skill + 10) then
        return COLORS.warn;
    end

    return COLORS.bad;
end

-- ---------------------------------------------------------------------------
-- Synthesis outlook (mirrors synthutils: support is a skill mod, skill-ups use raw skill)
-- ---------------------------------------------------------------------------

local function support_craft(recipe)
    if (state.craft > 0) then
        return state.craft;
    end

    return recipe.main;
end

-- What-if craft levels typed into the top-right panel. Session only; History always uses real skill.
local what_if = {
    active = false,
    skills = {},
};
local use_real_skills = false;

local function what_if_on()
    return what_if.active and not use_real_skills;
end

local function skill_of(craft_index)
    if (what_if_on() and what_if.skills[craft_index] ~= nil) then
        return what_if.skills[craft_index];
    end

    return player.skill(craft_index);
end

local function is_capped(craft_index)
    if (what_if_on()) then
        return false;
    end

    return player.is_capped(craft_index);
end

-- An image support buff the player really has, once its strength is known.
local function active_imagery()
    local buff = player.imagery;
    if (buff == nil or buff.power == nil) then
        return nil;
    end

    return buff;
end

-- A real imagery buff wins over the buttons; History (use_real_skills) ignores the buttons.
local function support_for(craft_index, recipe)
    local buff = active_imagery();
    if (buff ~= nil) then
        if (craft_index == buff.craft) then
            return buff.power;
        end
        return 0;
    end
    if (use_real_skills) then
        return 0;
    end

    local supported = state.craft;
    if (supported == 0 and recipe ~= nil) then
        supported = recipe.main;
    end
    if (craft_index == supported) then
        return SUPPORT_BONUS[state.support] or 0;
    end

    return 0;
end

local function effective_skill(craft_index, recipe)
    local skill = skill_of(craft_index);
    if (skill == nil) then
        return nil;
    end

    return skill + support_for(craft_index, recipe);
end

local function synth_success(difficulty)
    if (difficulty >= 4) then
        return math.max(0, 80 - 10 * (difficulty - 3)) / 100;
    end
    if (difficulty >= 1) then
        return (95 - 5 * difficulty) / 100;
    end

    return 0.95;
end

local function desynth_success(difficulty)
    if (difficulty >= 8) then
        return math.max(0, 10 - 10 * (difficulty - 7) / 3) / 100;
    end
    if (difficulty >= 1) then
        return (40 - 5 * (difficulty - 1)) / 100;
    end

    return 0.40;
end

local function hq_tier(difficulty)
    if (difficulty >= -10) then
        return 0;
    end
    if (difficulty >= -30) then
        return 1;
    end
    if (difficulty >= -50) then
        return 2;
    end

    return 3;
end

-- Returns nil when a skill is unknown (not logged in, or a placeholder subcraft level).
local function synth_outlook(recipe)
    local outlook = { success = 1, can_hq = true, tier = 3 };

    for index = 1, #db.crafts do
        local level = recipe.skills[index];
        if (level > 0) then
            local skill = effective_skill(index, recipe);
            if (skill == nil or level >= db.UNKNOWN_SKILL) then
                return nil;
            end

            local difficulty = level - skill;
            if (recipe.desynth) then
                outlook.success = outlook.success * desynth_success(difficulty);
            else
                outlook.success = outlook.success * synth_success(difficulty);
                outlook.can_hq  = outlook.can_hq and difficulty < 1;
                outlook.tier    = math.min(outlook.tier, hq_tier(difficulty));
            end
        end
    end

    if (recipe.desynth) then
        outlook.tier = nil;
        outlook.hq   = DESYNTH_HQ_CHANCE;
        return outlook;
    end

    outlook.hq = math.min(HQ_CHANCE[outlook.tier], HQ_CAP);
    return outlook;
end

local function hq_text(outlook)
    if (outlook.tier == nil) then
        return ('(HQ %s)'):fmt(percent(outlook.hq));
    end

    return ('(T%d %s)'):fmt(outlook.tier, percent(outlook.hq));
end

local function result_name(result)
    if (result.qty > 1) then
        return ('%s x%d'):fmt(db.item_name(result.id), result.qty);
    end

    return db.item_name(result.id);
end

-- The HQ outcomes that differ from the normal result, e.g. "Turtle Shell" for a Shell Shield desynthesis.
local function hq_results_text(recipe)
    local names = {};
    local seen  = {};
    for tier = 1, 3 do
        local hq   = recipe.hq[tier];
        local same = hq.id == recipe.result and hq.qty == recipe.qty;
        local key  = ('%d:%d'):fmt(hq.id, hq.qty);
        if (hq.id ~= 0 and not same and not seen[key]) then
            seen[key] = true;
            names[#names + 1] = result_name(hq);
        end
    end

    return table.concat(names, ', ');
end

-- A desynthesis row names what an HQ gives, since that is usually the reason to break the item down.
local function desynth_hq_text(recipe, outlook)
    local items = hq_results_text(recipe);
    if (outlook == nil) then
        if (items == '') then
            return nil;
        end
        return ('(HQ: %s)'):fmt(items);
    end
    if (items == '') then
        return ('(HQ %s)'):fmt(percent(outlook.hq));
    end

    return ('(HQ %s: %s)'):fmt(percent(outlook.hq), items);
end

local function success_color(success)
    if (success >= 0.90) then
        return COLORS.good;
    end
    if (success >= 0.75) then
        return COLORS.warn;
    end

    return COLORS.bad;
end

local function success_key(recipe)
    local outlook = synth_outlook(recipe);
    if (outlook == nil) then
        return -1;
    end

    return outlook.success;
end

local function outlook_color(outlook)
    if (outlook.tier ~= nil and outlook.can_hq) then
        return COLORS.hq;
    end
    if (outlook.success >= 0.75) then
        return COLORS.warn;
    end

    return COLORS.bad;
end

-- Skill-ups roll per craft on raw skill; the client only knows whole levels, so tenths are treated as .0.
local function skillup_base_chance(skill, difference)
    if (MODERN_SKILLUPS) then
        local curve = 3 - math.log(1.2 + skill / 10);
        if (difference > 1) then
            return math.min(1, difference * curve / 5);
        end
        return math.min(1, curve / (6 - difference));
    end
    if (skill < 50) then
        return 0.60;
    end

    return 0.25;
end

local function skillup_outlook(recipe, craft_index)
    local level = recipe.skills[craft_index];
    local skill = skill_of(craft_index);
    if (skill == nil or level >= db.UNKNOWN_SKILL) then
        return nil;
    end
    if (is_capped(craft_index)) then
        return { capped = true };
    end

    local difference = level - skill;
    local lowest     = 0;
    if (MODERN_SKILLUPS) then
        lowest = -11;
    end
    if (difference <= lowest) then
        return { too_low = true };
    end

    local chance = DESYNTH_SKILLUP_CHANCE;
    if (not recipe.desynth) then
        chance = skillup_base_chance(skill, difference);
    end

    local on_break = 0;
    if (difference > 0 and difference <= SKILLUP_BREAK_WINDOW) then
        on_break = chance;
        if (not recipe.desynth) then
            on_break = chance / 2;
        end
    end

    local weights = SINGLE_POINT;
    if (skill < BIG_GAINS_BELOW_SKILL) then
        weights = SKILLUP_WEIGHTS[math.max(0, math.min(difference, #SKILLUP_WEIGHTS - 1)) + 1];
    end

    return { on_success = chance, on_break = on_break, weights = weights };
end

local function gain_text(weights)
    local parts = {};
    for index, weight in ipairs(weights) do
        if (weight > 0) then
            parts[#parts + 1] = ('+0.%d %d%%'):fmt(index, weight);
        end
    end

    return table.concat(parts, ', ');
end

local function recipe_color(recipe, craft_index, level)
    return level_color(level, effective_skill(craft_index, recipe));
end

-- Finishes the Result cell with the HQ tier, then fills the Succ. cell.
local function draw_outlook(recipe)
    local outlook = synth_outlook(recipe);
    local text    = nil;
    if (recipe.desynth) then
        text = desynth_hq_text(recipe, outlook);
    elseif (outlook ~= nil and outlook.can_hq) then
        text = hq_text(outlook);
    end
    if (text ~= nil) then
        imgui.SameLine();
        imgui.TextColored(COLORS.hq, text);
    end

    imgui.TableNextColumn();
    if (outlook == nil) then
        imgui.TextDisabled('-');
        return;
    end

    imgui.TextColored(success_color(outlook.success), percent(outlook.success));
end

local function colored_text(color, text)
    if (color == nil) then
        imgui.Text(text);
        return;
    end

    imgui.TextColored(color, text);
end

local function crystal_short(id)
    return (db.item_name(id):gsub(' Crystal$', ''));
end

local function vendor_note(row)
    if (row.kind == 'nation') then
        if (row.note == '1') then
            return 'Citizens only, nation ranked 1st';
        end
        if (row.note == '2') then
            return 'Nation ranked 1st or 2nd';
        end
        return '';
    end

    if (row.kind == 'regional') then
        local region, nation = row.note:match('^(.-)|(.*)$');
        if (region ~= nil) then
            return ('While %s is under %s control'):fmt(region, nation);
        end
        return row.note;
    end

    if (row.kind == 'valeriano') then
        return 'Valeriano troupe, visits the 1st-place nation';
    end

    if (row.kind == 'guild24') then
        return ('Guild rank %s'):fmt(row.note);
    end

    return '';
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

local function navigate(view)
    if (state.view ~= nil) then
        if (#state.history >= MAX_HISTORY) then
            table.remove(state.history, 1);
        end
        state.history[#state.history + 1] = state.view;
    end

    state.view = view;
    state.scroll_detail  = true;
    state.detail_open[1] = true;
end

-- "Result xN", or "Source > Result xN" for a desynthesis so it is clear which item goes in.
local function recipe_label(recipe)
    local label = db.item_name(recipe.result);
    if (recipe.qty > 1) then
        label = ('%s x%d'):fmt(label, recipe.qty);
    end

    local source = recipe.ingredients[1];
    if (recipe.desynth and source ~= nil) then
        label = ('%s > %s'):fmt(db.item_name(source.id), label);
    end

    return label;
end

local function go_back()
    local count = #state.history;
    if (count == 0) then
        return;
    end

    state.view = state.history[count];
    state.history[count] = nil;
    state.scroll_detail = true;
end

local function open_item(id)
    navigate({ kind = 'item', id = id });
end

local function open_recipe(recipe)
    navigate({ kind = 'recipe', recipe = recipe });
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local function next_id()
    link_id = link_id + 1;
    return link_id;
end

local function item_icon(id, size)
    if (not state.icons[1]) then
        return;
    end

    local texture = icons.get(id);
    if (texture == nil) then
        return;
    end

    imgui.Image(texture, { px(size), px(size) });
    imgui.SameLine();
end

local function item_tooltip(id)
    imgui.BeginTooltip();
    imgui.TextColored(COLORS.title, db.item_name(id));

    local description = db.item_description(id);
    if (description ~= '') then
        imgui.PushTextWrapPos(340);
        imgui.TextUnformatted(description);
        imgui.PopTextWrapPos();
    end

    local bag, total = player.count(id);
    imgui.TextDisabled(('Have %d in bag, %d in all storage'):fmt(bag, total));

    local cheapest = db.cheapest[id];
    if (cheapest ~= nil) then
        imgui.TextDisabled(('Cheapest NPC: %s gil at %s (%s)'):fmt(commas(cheapest.price), cheapest.npc, db.zone_name(cheapest.zone)));
    end

    local sell = db.items[id];
    if (sell ~= nil and sell.basesell > 0) then
        imgui.TextDisabled(('Sells to NPCs for about %s gil'):fmt(commas(sell.basesell)));
    end

    imgui.EndTooltip();
end

local function item_link(id, label)
    item_icon(id, 16);

    local text = label;
    if (text == nil) then
        text = db.item_name(id);
    end

    if (imgui.TextLink(('%s##item%d'):fmt(text, next_id()))) then
        open_item(id);
    end
    if (imgui.IsItemHovered()) then
        item_tooltip(id);
    end
end

local function have_text(id, needed)
    local bag, total = player.count(id);
    local text = ('%d / %d'):fmt(bag, total);
    if (bag >= needed) then
        imgui.TextColored(COLORS.good, text);
    elseif (total >= needed) then
        imgui.TextColored(COLORS.warn, text);
    else
        imgui.TextDisabled(text);
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('In bag / in bag and all storage');
    end
end

local function section(title)
    imgui.Spacing();
    if (active_theme.headings == 'caps') then
        imgui.TextColored(COLORS.title, title:upper());
        imgui.Separator();
        return;
    end

    imgui.SeparatorText(title);
end

local function sort_spec()
    local specs = imgui.TableGetSortSpecs();
    if (specs == nil or specs.SpecsCount == 0 or specs.Specs == nil) then
        return nil, ImGuiSortDirection_None;
    end

    return specs.Specs.ColumnIndex + 1, specs.Specs.SortDirection;
end

-- Call after TableSetupColumn. keys[column] maps a row to a number or lowercase string; nil keys leave a column unsorted.
local function sorted_rows(id, rows, keys)
    local column, direction = sort_spec();
    if (column == nil or keys[column] == nil or direction == ImGuiSortDirection_None) then
        return rows;
    end

    local cache = sort_cache[id];
    if (cache ~= nil and cache.rows == rows and cache.count == #rows and cache.column == column and cache.direction == direction) then
        return cache.sorted;
    end

    local key_of    = keys[column];
    local decorated = {};
    for index, row in ipairs(rows) do
        decorated[index] = { row = row, key = key_of(row), index = index };
    end

    local descending = direction == ImGuiSortDirection_Descending;
    table.sort(decorated, function (a, b)
        if (a.key == b.key) then
            return a.index < b.index;
        end
        if (descending) then
            return a.key > b.key;
        end
        return a.key < b.key;
    end);

    local sorted = {};
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.row;
    end

    sort_cache[id] = { rows = rows, count = #rows, column = column, direction = direction, sorted = sorted };
    return sorted;
end

local function zone_key(zone)
    return db.zone_name(zone):lower();
end

local function recipe_keys(get_recipe)
    return {
        function (entry) return get_recipe(entry).level; end,
        function (entry) return db.crafts[get_recipe(entry).main].short; end,
        function (entry) return get_recipe(entry).search_result; end,
        function (entry) return success_key(get_recipe(entry)); end,
        function (entry) return db.item_lname(get_recipe(entry).crystal); end,
    };
end

local function recipe_table(id, entries, get_recipe, get_tier)
    if (not begin_fit_table(id, 5, SORT_FLAGS)) then
        return;
    end

    setup_column('Lv', ImGuiTableColumnFlags_WidthFixed, 34);
    setup_column('Craft', ImGuiTableColumnFlags_WidthFixed, 40);
    setup_column('Result', ImGuiTableColumnFlags_WidthStretch);
    setup_column('Succ.', ImGuiTableColumnFlags_WidthFixed, 40);
    setup_column('Crystal', ImGuiTableColumnFlags_WidthFixed, 70);
    imgui.TableHeadersRow();

    for index, entry in ipairs(sorted_rows(id, entries, recipe_keys(get_recipe))) do
        if (index > MAX_ROWS) then
            break;
        end

        local recipe = get_recipe(entry);
        local craft  = db.crafts[recipe.main];

        imgui.TableNextRow();
        imgui.TableNextColumn();
        local color = recipe_color(recipe, recipe.main, recipe.level);
        if (color ~= nil) then
            imgui.PushStyleColor(ImGuiCol_Text, color);
        end
        local clicked = imgui.Selectable(('%d##%s%d'):fmt(recipe.level, id, index), false, ImGuiSelectableFlags_SpanAllColumns);
        if (color ~= nil) then
            imgui.PopStyleColor(1);
        end
        if (clicked) then
            open_recipe(recipe);
        end

        imgui.TableNextColumn();
        imgui.Text(craft.short);

        imgui.TableNextColumn();
        local label = recipe_label(recipe);
        local tier  = get_tier(entry);
        if (tier > 0) then
            imgui.TextColored(COLORS.hq, ('%s (HQ%d)'):fmt(label, tier));
        else
            imgui.Text(label);
        end
        draw_outlook(recipe);

        imgui.TableNextColumn();
        imgui.TextDisabled(crystal_short(recipe.crystal));
    end

    imgui.EndTable();

    if (#entries > MAX_ROWS) then
        imgui.TextDisabled(('Showing %d of %d.'):fmt(MAX_ROWS, #entries));
    end
end

-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

local function words_of(text)
    local words = {};
    for word in text:lower():gmatch('%S+') do
        if (#words >= MAX_WORDS) then
            break;
        end
        words[#words + 1] = word;
    end

    return words;
end

local function contains_all(haystack, words)
    for _, word in ipairs(words) do
        if (haystack:find(word, 1, true) == nil) then
            return false;
        end
    end

    return true;
end

local function recipe_level_for(recipe)
    if (state.craft == 0) then
        return recipe.level;
    end

    local level = recipe.skills[state.craft];
    if (level == 0 or level >= db.UNKNOWN_SKILL) then
        return nil;
    end
    if (not state.include_sub[1] and level < recipe.level) then
        return nil;
    end

    return level;
end

-- Skill-ups roll on raw skill and need the recipe above it; support only widens how far above stays safe to attempt.
local function subcrafts_reachable(recipe, supported)
    for index = 1, #db.crafts do
        local level = recipe.skills[index];
        if (index ~= supported and level > 0 and level < db.UNKNOWN_SKILL) then
            local skill = skill_of(index);
            if (skill == nil or level > skill + SKILLUP_GAP) then
                return false;
            end
        end
    end

    return true;
end

local function in_skillup_range(recipe, level)
    local supported = support_craft(recipe);
    local skill     = skill_of(supported);
    if (skill == nil) then
        return false;
    end

    return level > skill and level <= skill + SKILLUP_GAP + support_for(supported, recipe) and subcrafts_reachable(recipe, supported);
end

local function in_level_range(recipe, level)
    if (state.skillup[1]) then
        return in_skillup_range(recipe, level);
    end

    return level >= state.level_min[1] and level <= state.level_max[1];
end

local function hq_filter_active()
    return state.hq_filter[1][1] or state.hq_filter[2][1] or state.hq_filter[3][1];
end

-- The filter boxes are T1 through T3, the tier the recipe lands at for you right now.
local function matches_hq_filter(recipe)
    local outlook = synth_outlook(recipe);
    if (outlook == nil or outlook.tier == nil or not outlook.can_hq or outlook.tier == 0) then
        return false;
    end

    return state.hq_filter[outlook.tier][1];
end

local function filter_recipes(words)
    local matches = {};
    for _, recipe in ipairs(db.recipes) do
        local level = recipe_level_for(recipe);
        local keep  = level ~= nil and recipe.desynth == state.desynth[1] and in_level_range(recipe, level);
        if (keep and hq_filter_active()) then
            keep = matches_hq_filter(recipe);
        end
        if (state.mode == MODE_FAVORITES) then
            keep = level ~= nil and state.favorites[recipe.id] == true;
        end
        if (keep and #words > 0) then
            if (state.mode == MODE_INGREDIENTS) then
                keep = contains_all(recipe.search_ingredients, words);
            else
                keep = contains_all(recipe.search_result, words) or (recipe.desynth and contains_all(recipe.search_source, words));
            end
        end
        if (keep) then
            matches[#matches + 1] = { recipe = recipe, level = level };
        end
    end

    table.sort(matches, function (a, b)
        if (a.level ~= b.level) then
            return a.level < b.level;
        end
        return a.recipe.search_result < b.recipe.search_result;
    end);

    return matches;
end

local function item_sources(id)
    local parts = {};
    if (db.vendors[id] ~= nil) then
        parts[#parts + 1] = 'Shop';
    end
    if (db.guilds[id] ~= nil) then
        parts[#parts + 1] = 'Guild';
    end
    if (db.drops[id] ~= nil) then
        parts[#parts + 1] = 'Drop';
    end
    if (db.helm[id] ~= nil) then
        parts[#parts + 1] = 'Gather';
    end
    if (db.made_by[id] ~= nil) then
        parts[#parts + 1] = 'Craft';
    end

    return table.concat(parts, ' ');
end

local function filter_items(words)
    local matches = {};
    for _, id in ipairs(db.item_ids) do
        if (contains_all(db.items[id].lname, words)) then
            matches[#matches + 1] = id;
        end
    end

    return matches;
end

local function filter_priced(words)
    local matches = {};
    for _, id in ipairs(db.item_ids) do
        if (prices.get(id) ~= nil and contains_all(db.items[id].lname, words)) then
            matches[#matches + 1] = id;
        end
    end

    return matches;
end

local function refresh_results()
    local skills = {};
    for index = 1, #db.crafts do
        skills[index] = tostring(skill_of(index));
    end

    local key = ('%s|%d|%d|%d|%d|%s|%s|%d|%s|%s|%d'):fmt(state.search[1], state.mode, state.craft, state.level_min[1], state.level_max[1], tostring(state.include_sub[1]), tostring(state.desynth[1]),
        state.support, tostring(state.skillup[1]), table.concat(skills, ','), state.favorites_rev)
        .. ('|%s%s%s|%d'):fmt(tostring(state.hq_filter[1][1]), tostring(state.hq_filter[2][1]), tostring(state.hq_filter[3][1]), prices.revision);
    if (key == state.filter_key) then
        return;
    end

    state.filter_key = key;
    local words = words_of(state.search[1]);
    if (state.mode == MODE_ITEMS) then
        state.results = filter_items(words);
    elseif (state.mode == MODE_PRICES) then
        state.results = filter_priced(words);
    else
        state.results = filter_recipes(words);
    end
end

-- ---------------------------------------------------------------------------
-- Filter bar and result list
-- ---------------------------------------------------------------------------

-- Wide enough for the longest option plus the arrow button.
local function combo_width(options, first_label)
    local widest = 0;
    if (first_label ~= nil) then
        widest = imgui.CalcTextSize(first_label);
    end
    for _, option in ipairs(options) do
        widest = math.max(widest, imgui.CalcTextSize(option));
    end

    return widest + imgui.GetFrameHeight() + imgui.GetStyle().FramePadding.x * 2 + COMBO_PADDING;
end

-- order lists option indices in display order; the returned value is always the option's own index.
local function draw_combo(label, options, current, first_label, order)
    local preview = first_label;
    if (current > 0) then
        preview = options[current];
    end

    local selected = current;
    imgui.SetNextItemWidth(combo_width(options, first_label));
    if (imgui.BeginCombo(label, preview)) then
        if (first_label ~= nil and imgui.Selectable(first_label, current == 0)) then
            selected = 0;
        end
        for _, index in ipairs(order) do
            if (imgui.Selectable(options[index], current == index)) then
                selected = index;
            end
        end
        imgui.EndCombo();
    end

    return selected;
end

local function in_order(options)
    local order = {};
    for index = 1, #options do
        order[index] = index;
    end

    return order;
end

local function alphabetical(options)
    local order = in_order(options);
    table.sort(order, function (a, b)
        return options[a] < options[b];
    end);

    return order;
end

local function reset_filters()
    state.quick          = nil;
    state.search[1]      = '';
    state.craft          = 0;
    state.level_min[1]   = 0;
    state.level_max[1]   = 110;
    state.include_sub[1] = false;
    state.desynth[1]     = false;
    state.skillup[1]     = false;
    for grade = 1, 3 do
        state.hq_filter[grade][1] = false;
    end
end

local function toggle_button(label, active)
    if (active) then
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.support);
    end
    local clicked = imgui.Button(label);
    if (active) then
        imgui.PopStyleColor(1);
    end

    return clicked;
end

local function draw_support_button(label, level, tooltip)
    if (toggle_button(label, state.support == level)) then
        if (state.support == level) then
            state.support = 0;
        else
            state.support = level;
        end
    end
    if (imgui.IsItemHovered()) then
        set_tooltip(tooltip);
    end
end

local MAX_SKILL     = 110;

local function draw_what_if_panel()
    imgui.TextDisabled('Try other craft levels. Everything recalculates; nothing is saved.');
    for index, craft in ipairs(db.crafts) do
        local buffer = { skill_of(index) or 0 };
        imgui.SetNextItemWidth(int_input_width(3));
        if (imgui.InputInt(('%s##whatif%d'):fmt(craft.name, index), buffer, 1, 10)) then
            what_if.active        = true;
            what_if.skills[index] = math.max(0, math.min(buffer[1], MAX_SKILL));
        end
    end

    if (imgui.Button('Use my skills')) then
        what_if.active = false;
        what_if.skills = {};
    end
end

-- Sits at the right end of the top row.
local function draw_what_if()
    local label = 'What-if';
    if (what_if.active) then
        label = 'What-if on';
    end

    imgui.SameLine();
    local width = button_width(label);
    local avail = imgui.GetContentRegionAvail();
    imgui.SetCursorPosX(imgui.GetCursorPosX() + math.max(0, avail - width));
    if (toggle_button(label, what_if.active)) then
        imgui.OpenPopup('##whatifpanel');
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('Change your main or sub craft levels to see the tier, HQ and success chances.');
    end

    if (imgui.BeginPopup('##whatifpanel')) then
        draw_what_if_panel();
        imgui.EndPopup();
    end
end

local function draw_buff_label(buff)
    imgui.SameLine();
    local name = db.crafts[buff.craft].name;
    if (buff.power == nil) then
        imgui.TextColored(COLORS.warn, ('%s support (strength unknown)'):fmt(name));
        if (imgui.IsItemHovered()) then
            set_tooltip('Could not read the buff timer, so the Standard and Advanced buttons stay in charge.');
        end
        return;
    end

    imgui.TextColored(COLORS.good, ('%s support +%d'):fmt(name, buff.power));
    if (imgui.IsItemHovered()) then
        set_tooltip('Read from your status. Used everywhere instead of the Standard and Advanced buttons.');
    end
end

local function draw_skills()
    local skill = skill_of(state.craft);
    if (state.craft > 0 and skill ~= nil) then
        local text  = ('%s %d'):fmt(db.crafts[state.craft].name, skill);
        local bonus = support_for(state.craft, nil);
        if (bonus > 0) then
            text = ('%s (+%d)'):fmt(text, bonus);
        end

        local color = COLORS.title;
        if (what_if_on()) then
            text  = ('%s (what-if)'):fmt(text);
            color = COLORS.warn;
        end

        imgui.AlignTextToFramePadding();
        imgui.TextColored(color, text);
        imgui.SameLine();
    end

    local buff = player.imagery;
    imgui.BeginDisabled(active_imagery() ~= nil);
    draw_support_button('Standard +1', 1, 'Standard image support: +1 to the picked craft (each recipe\'s main craft with All crafts).\nRaises HQ tier and success rate. Skill-ups still roll on your raw skill.');
    imgui.SameLine();
    draw_support_button('Advanced +3', 2, 'Advanced image support: +3 to the picked craft (each recipe\'s main craft with All crafts).\nRaises HQ tier and success rate. Skill-ups still roll on your raw skill.');
    imgui.EndDisabled();
    if (buff ~= nil) then
        draw_buff_label(buff);
    end
    draw_what_if();
end

local function draw_filters()
    draw_skills();

    imgui.SetNextItemWidth(px(260));
    imgui.InputTextWithHint('##search', 'Search names...', state.search, 64);

    imgui.SameLine();
    state.mode = draw_combo('##mode', MODES, state.mode, nil, in_order(MODES));

    imgui.SameLine();
    local craft_names = {};
    for index, craft in ipairs(db.crafts) do
        craft_names[index] = craft.name;
    end
    imgui.BeginDisabled(state.mode == MODE_ITEMS or state.mode == MODE_PRICES);
    state.craft = draw_combo('##craft', craft_names, state.craft, 'All crafts', alphabetical(craft_names));
    imgui.EndDisabled();

    imgui.SameLine();
    if (imgui.Button('Reset')) then
        reset_filters();
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('Clear the search, craft, level range, sub-crafts, desynthesis, skill-ups and tier filters.');
    end
    imgui.SameLine();
    if (imgui.Button('History')) then
        state.log_visible[1] = not state.log_visible[1];
    end

    imgui.SameLine();
    if (imgui.Button('Settings')) then
        state.settings_visible[1] = not state.settings_visible[1];
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('Theme, UI scale, icons, layout and tracker options. /cb settings opens it too.');
    end

    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if (imgui.IsItemHovered()) then
        imgui.BeginTooltip();
        imgui.Text('Click a recipe to see its materials; click any item for where to get it.');
        imgui.Text('Level colors compare against your craft skill plus image support: green at or under, yellow within 10, red above.');
        imgui.Text('(T0 1.6%) is the HQ tier and HQ chance on success. Succ. is the chance the synth does not break.');
        imgui.TextDisabled(('Data: %s, expansions %s'):fmt(db.meta.source or 'unknown', db.meta.expansions or '?'));
        imgui.EndTooltip();
    end

    local favorites = state.mode == MODE_FAVORITES;
    imgui.BeginDisabled(state.mode == MODE_ITEMS or state.mode == MODE_PRICES);
    imgui.BeginDisabled(state.skillup[1] or favorites);
    imgui.AlignTextToFramePadding();
    if (state.quick ~= nil) then
        imgui.TextColored(COLORS.warn, 'Level');
        if (imgui.IsItemHovered()) then
            set_tooltip(('Quick look from /cb lvl.\nYour usual filters (level %d to %d) come back when the book closes.'):fmt(state.quick.level_min, state.quick.level_max));
        end
    else
        imgui.Text('Level');
    end
    imgui.SameLine();
    imgui.SetNextItemWidth(int_input_width(3));
    imgui.InputInt('##lvmin', state.level_min, 1, 10);
    imgui.SameLine();
    imgui.Text('to');
    imgui.SameLine();
    imgui.SetNextItemWidth(int_input_width(3));
    imgui.InputInt('##lvmax', state.level_max, 1, 10);
    state.level_min[1] = math.max(0, math.min(state.level_min[1], 120));
    state.level_max[1] = math.max(state.level_min[1], math.min(state.level_max[1], 120));
    imgui.EndDisabled();

    imgui.SameLine();
    imgui.BeginDisabled(favorites);
    imgui.Checkbox('Skill-ups', state.skillup);
    imgui.EndDisabled();
    if (imgui.IsItemHovered()) then
        set_tooltip(('Only recipes 1 to %d levels above your raw skill, plus the image support bonus.\nUses the picked craft, or each recipe\'s main craft with All crafts. Replaces the level range.'):fmt(SKILLUP_GAP));
    end

    imgui.SameLine();
    imgui.Checkbox('Sub-crafts', state.include_sub);
    if (imgui.IsItemHovered()) then
        set_tooltip('With a craft picked, also list recipes where it is only a secondary requirement.');
    end
    imgui.SameLine();
    imgui.BeginDisabled(favorites);
    imgui.Checkbox('Desynthesis', state.desynth);
    for tier = 1, 3 do
        imgui.SameLine();
        imgui.Checkbox(('T%d'):fmt(tier), state.hq_filter[tier]);
        if (imgui.IsItemHovered()) then
            set_tooltip(('Recipes you are at T%d for right now, counting image support.'):fmt(tier));
        end
    end
    imgui.EndDisabled();
    imgui.EndDisabled();
end

local function draw_recipe_list()
    if (not begin_table('##recipes', 5, bit.bor(LIST_FLAGS, SORT_FLAGS), { 0, 0 })) then
        return;
    end

    imgui.TableSetupScrollFreeze(0, 1);
    setup_column('Lv', ImGuiTableColumnFlags_WidthFixed, 30);
    setup_column('Craft', ImGuiTableColumnFlags_WidthFixed, 38);
    setup_column('Result', ImGuiTableColumnFlags_WidthStretch);
    setup_column('Succ.', ImGuiTableColumnFlags_WidthFixed, 40);
    setup_column('Crystal', ImGuiTableColumnFlags_WidthFixed, 60);
    imgui.TableHeadersRow();

    local rows = sorted_rows('##recipes', state.results, {
        function (entry) return entry.level; end,
        function (entry) return db.crafts[support_craft(entry.recipe)].short; end,
        function (entry) return entry.recipe.search_result; end,
        function (entry) return success_key(entry.recipe); end,
        function (entry) return db.item_lname(entry.recipe.crystal); end,
    });
    for index, entry in ipairs(rows) do
        if (index > MAX_RESULTS) then
            break;
        end

        local recipe = entry.recipe;
        local shown  = recipe.main;
        if (state.craft > 0) then
            shown = state.craft;
        end

        imgui.TableNextRow();
        imgui.TableNextColumn();
        local color = recipe_color(recipe, shown, entry.level);
        if (color ~= nil) then
            imgui.PushStyleColor(ImGuiCol_Text, color);
        end
        local selected = state.view ~= nil and state.view.recipe == recipe;
        local clicked  = imgui.Selectable(('%d##list%d'):fmt(entry.level, index), selected, ImGuiSelectableFlags_SpanAllColumns);
        if (color ~= nil) then
            imgui.PopStyleColor(1);
        end
        if (clicked) then
            open_recipe(recipe);
        end

        imgui.TableNextColumn();
        imgui.Text(db.crafts[shown].short);

        imgui.TableNextColumn();
        if (#state.results <= LIST_ICONS) then
            item_icon(recipe.result, 14);
        end
        imgui.Text(recipe_label(recipe));
        draw_outlook(recipe);

        imgui.TableNextColumn();
        imgui.TextDisabled(crystal_short(recipe.crystal));
    end

    imgui.EndTable();
end

-- ---------------------------------------------------------------------------
-- Custom prices
-- ---------------------------------------------------------------------------

-- A price the player set always wins; otherwise the cheapest NPC. Returns nil when neither exists.
local function material_price(id)
    local custom = prices.get(id);
    if (custom ~= nil) then
        return custom, true;
    end

    local cheapest = db.cheapest[id];
    if (cheapest ~= nil) then
        return cheapest.price, false;
    end

    return nil, false;
end

local function draw_price_input(id)
    local buffer = { '' };
    local price  = prices.get(id);
    if (price ~= nil) then
        buffer[1] = tostring(price);
    end

    imgui.SetNextItemWidth(price_input_width());
    if (imgui.InputTextWithHint(('##price%d'):fmt(next_id()), '-', buffer, AH_INPUT_CHARS, ImGuiInputTextFlags_CharsDecimal)) then
        prices.set(id, tonumber(buffer[1]) or 0);
    end
    if (imgui.IsItemDeactivatedAfterEdit()) then
        prices.save();
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('Your price for one: what you pay for it as a material and what you sell it for.\nOverrides NPC prices. Clear it to go back to the NPC price. Saved for every character.');
    end
end

local function draw_price_list()
    if (not begin_table('##prices', 4, bit.bor(LIST_FLAGS, SORT_FLAGS), { 0, 0 })) then
        return;
    end

    imgui.TableSetupScrollFreeze(0, 1);
    setup_column('Item', ImGuiTableColumnFlags_WidthStretch);
    setup_column('My price', ImGuiTableColumnFlags_WidthFixed, price_input_width());
    setup_column('NPC', ImGuiTableColumnFlags_WidthFixed, 60);
    setup_column('', bit.bor(ImGuiTableColumnFlags_WidthFixed, ImGuiTableColumnFlags_NoSort), 20);
    imgui.TableHeadersRow();

    local rows = sorted_rows('##prices', state.results, {
        function (id) return db.item_lname(id); end,
        function (id) return prices.get(id) or 0; end,
        function (id) return (db.cheapest[id] or { price = -1 }).price; end,
    });
    local clear = nil;
    for index, id in ipairs(rows) do
        imgui.TableNextRow();
        imgui.TableNextColumn();
        if (imgui.TextLink(('%s##pricelist%d'):fmt(db.item_name(id), index))) then
            open_item(id);
        end

        imgui.TableNextColumn();
        draw_price_input(id);

        imgui.TableNextColumn();
        local cheapest = db.cheapest[id];
        if (cheapest ~= nil) then
            imgui.TextDisabled(commas(cheapest.price));
            if (imgui.IsItemHovered()) then
                set_tooltip(('%s at %s (%s)'):fmt(commas(cheapest.price), cheapest.npc, db.zone_name(cheapest.zone)));
            end
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        if (imgui.SmallButton(('x##clearprice%d'):fmt(index))) then
            clear = id;
        end
        if (imgui.IsItemHovered()) then
            set_tooltip('Clear your price and use the NPC price again.');
        end
    end

    imgui.EndTable();

    if (clear ~= nil) then
        prices.set(clear, 0);
        prices.save();
    end
end

local function draw_item_list()
    if (not begin_table('##items', 2, bit.bor(LIST_FLAGS, SORT_FLAGS), { 0, 0 })) then
        return;
    end

    imgui.TableSetupScrollFreeze(0, 1);
    setup_column('Item', ImGuiTableColumnFlags_WidthStretch);
    setup_column('Sources', ImGuiTableColumnFlags_WidthFixed, 150);
    imgui.TableHeadersRow();

    local rows = sorted_rows('##items', state.results, {
        function (id) return db.item_lname(id); end,
        function (id) return item_sources(id); end,
    });
    for index, id in ipairs(rows) do
        if (index > MAX_RESULTS) then
            break;
        end

        imgui.TableNextRow();
        imgui.TableNextColumn();
        if (#state.results <= LIST_ICONS) then
            item_icon(id, 14);
        end
        local selected = state.view ~= nil and state.view.id == id;
        if (imgui.Selectable(('%s##itemlist%d'):fmt(db.item_name(id), index), selected, ImGuiSelectableFlags_SpanAllColumns)) then
            open_item(id);
        end

        imgui.TableNextColumn();
        imgui.TextDisabled(item_sources(id));
    end

    imgui.EndTable();
end

local function draw_list()
    local count = #state.results;
    if (count > MAX_RESULTS) then
        imgui.TextDisabled(('%d matches, showing the first %d. Narrow the search.'):fmt(count, MAX_RESULTS));
    else
        imgui.TextDisabled(('%d matches'):fmt(count));
    end

    if (state.mode == MODE_FAVORITES and count == 0) then
        imgui.TextDisabled('No favorites yet. Open a recipe and click Favorite.');
        return;
    end
    if (state.mode == MODE_PRICES and count == 0) then
        imgui.TextDisabled('No custom prices yet. Type one into any My price box.');
        return;
    end

    if (state.mode == MODE_ITEMS) then
        draw_item_list();
    elseif (state.mode == MODE_PRICES) then
        draw_price_list();
    else
        draw_recipe_list();
    end
end

-- ---------------------------------------------------------------------------
-- Recipe detail
-- ---------------------------------------------------------------------------

-- This section keeps its helpers to itself. Lua allows only 200 top-level locals in one file.
local material_rows;
local skillup_per_synth;
local draw_recipe;
-- Defined with the item pages below. The recipe page uses it to jump from a desynthesis back to the synth.
local best_recipe;
do
    local function draw_craft_requirements(recipe)
        local order = { recipe.main };
        for index = 1, #db.crafts do
            if (index ~= recipe.main and recipe.skills[index] > 0) then
                order[#order + 1] = index;
            end
        end

        for position, index in ipairs(order) do
            if (position > 1) then
                imgui.SameLine();
                imgui.TextDisabled('+');
                imgui.SameLine();
            end

            local level = recipe.skills[index];
            if (level >= db.UNKNOWN_SKILL) then
                imgui.TextColored(COLORS.bad, ('%s ?'):fmt(db.crafts[index].name));
                if (imgui.IsItemHovered()) then
                    set_tooltip(('The server data lists this subcraft as %d, a placeholder for an unverified level.'):fmt(level));
                end
            else
                colored_text(recipe_color(recipe, index, level), ('%s %d'):fmt(db.crafts[index].name, level));
            end
        end

        local outlook = synth_outlook(recipe);
        if (outlook == nil) then
            return;
        end

        if (outlook.tier == nil) then
            imgui.TextColored(outlook_color(outlook), ('Desynthesis: %s success, %s HQ on success'):fmt(percent(outlook.success), percent(outlook.hq)));
        elseif (outlook.can_hq) then
            imgui.TextColored(outlook_color(outlook), ('HQ tier T%d: %s success, %s HQ on success'):fmt(outlook.tier, percent(outlook.success), percent(outlook.hq)));
        else
            imgui.TextColored(outlook_color(outlook), ('Above your skill, no HQ: %s success'):fmt(percent(outlook.success)));
        end
    end

    function material_rows(recipe)
        local rows = { { id = recipe.crystal, count = 1 } };
        for _, ingredient in ipairs(recipe.ingredients) do
            rows[#rows + 1] = ingredient;
        end

        return rows;
    end

    local function recipe_crafts(recipe)
        local order = { recipe.main };
        for index = 1, #db.crafts do
            if (index ~= recipe.main and recipe.skills[index] > 0) then
                order[#order + 1] = index;
            end
        end

        return order;
    end

    function skillup_per_synth(skillup, success)
        if (skillup.capped or skillup.too_low) then
            return 0;
        end
        if (success == nil) then
            return skillup.on_success;
        end

        return success * skillup.on_success + (1 - success) * skillup.on_break;
    end

    local function draw_skillup_row(recipe, craft_index, success)
        local skillup = skillup_outlook(recipe, craft_index);
        if (skillup == nil) then
            return;
        end

        imgui.TableNextRow();
        imgui.TableNextColumn();
        imgui.Text(('%s %d'):fmt(db.crafts[craft_index].short, recipe.skills[craft_index]));

        imgui.TableNextColumn();
        if (skillup.capped or skillup.too_low) then
            imgui.TextDisabled('0%');
            return;
        end

        imgui.Text(percent(skillup_per_synth(skillup, success)));
        if (imgui.IsItemHovered()) then
            set_tooltip(('%s on success, %s on break.\nBreaks only give skill-ups within %d levels above your skill.'):fmt(percent(skillup.on_success), percent(skillup.on_break), SKILLUP_BREAK_WINDOW));
        end

        imgui.TableNextColumn();
        imgui.TextDisabled(gain_text(skillup.weights));
    end

    local function draw_skillups(recipe)
        if (skill_of(recipe.main) == nil) then
            return;
        end

        local outlook = synth_outlook(recipe);
        local success = nil;
        if (outlook ~= nil) then
            success = outlook.success;
        end

        section('Skill-ups');
        if (not begin_fit_table('##skillups', 3)) then
            return;
        end

        setup_column('Craft', ImGuiTableColumnFlags_WidthFixed, 60);
        setup_column('Chance', ImGuiTableColumnFlags_WidthFixed, 60);
        setup_column('Gain when it happens', ImGuiTableColumnFlags_WidthStretch);
        imgui.TableHeadersRow();

        for _, craft_index in ipairs(recipe_crafts(recipe)) do
            draw_skillup_row(recipe, craft_index, success);
        end

        imgui.EndTable();
    end

    local function draw_material_cost(row)
        local each, custom = material_price(row.id);
        if (each == nil) then
            imgui.TextDisabled('-');
            return nil;
        end

        imgui.Text(commas(each * row.count));
        if (imgui.IsItemHovered()) then
            local cheapest = db.cheapest[row.id];
            if (custom) then
                set_tooltip(('%s each at your price'):fmt(commas(each)));
            else
                set_tooltip(('%s each at %s (%s)'):fmt(commas(each), cheapest.npc, db.zone_name(cheapest.zone)));
            end
        end

        return each * row.count;
    end

    local function draw_materials(recipe)
        section('Materials');

        local rows = material_rows(recipe);

        local cost    = 0;
        local missing = {};

        if (begin_fit_table('##materials', 5)) then
            setup_column('Qty', ImGuiTableColumnFlags_WidthFixed, 30);
            setup_column('Item', ImGuiTableColumnFlags_WidthStretch);
            setup_column('Have', ImGuiTableColumnFlags_WidthFixed, 64);
            setup_column('Cost', ImGuiTableColumnFlags_WidthFixed, 70);
            setup_column('My price', ImGuiTableColumnFlags_WidthFixed, price_input_width());
            imgui.TableHeadersRow();

            for _, row in ipairs(rows) do
                imgui.TableNextRow();
                imgui.TableNextColumn();
                imgui.Text(('%dx'):fmt(row.count));

                imgui.TableNextColumn();
                item_link(row.id);

                imgui.TableNextColumn();
                have_text(row.id, row.count);

                imgui.TableNextColumn();
                local price = draw_material_cost(row);
                if (price ~= nil) then
                    cost = cost + price;
                elseif (not CRYSTAL_IDS[row.id]) then
                    missing[#missing + 1] = db.item_name(row.id);
                end

                imgui.TableNextColumn();
                draw_price_input(row.id);
            end

            imgui.EndTable();
        end

        if (#missing == 0) then
            imgui.TextDisabled(('Materials cost about %s gil per synth.'):fmt(commas(cost)));
        else
            imgui.PushTextWrapPos(0);
            imgui.TextDisabled(('Priced materials cost about %s gil. No NPC or custom price: %s.'):fmt(commas(cost), table.concat(missing, ', ')));
            imgui.PopTextWrapPos();
        end

        return cost, #missing;
    end

    local function draw_profit(value, cost, missing)
        if (value == 0) then
            imgui.TextDisabled('-');
            return;
        end
        if (missing > 0) then
            imgui.TextDisabled('?');
            if (imgui.IsItemHovered()) then
                set_tooltip('Some materials have no NPC or custom price. Enter one under Materials.');
            end
            return;
        end

        local profit = value - cost;
        local color  = COLORS.good;
        if (profit < 0) then
            color = COLORS.bad;
        end
        local margin = math.floor(profit / value * 100 + 0.5);
        imgui.TextColored(color, ('%s (%d%%)'):fmt(signed_commas(profit), margin));
        if (imgui.IsItemHovered()) then
            set_tooltip(('Profit per synth, and the profit margin.\nMargin = (sale price - cost) / sale price = (%s - %s) / %s.'):fmt(commas(value), commas(cost), commas(value)));
        end
    end

    local function draw_results(recipe, cost, missing)
        section('Results');

        if (not begin_fit_table('##results', 6)) then
            return;
        end

        setup_column('Tier', ImGuiTableColumnFlags_WidthFixed, 36);
        setup_column('Item', ImGuiTableColumnFlags_WidthStretch);
        setup_column('NPC sell', ImGuiTableColumnFlags_WidthFixed, 80);
        setup_column('Profit', ImGuiTableColumnFlags_WidthFixed, 80);
        setup_column('My price', ImGuiTableColumnFlags_WidthFixed, price_input_width());
        setup_column('My profit', ImGuiTableColumnFlags_WidthFixed, 80);
        imgui.TableHeadersRow();

        local tiers = { { label = 'NQ', id = recipe.result, qty = recipe.qty } };
        for tier = 1, 3 do
            local hq = recipe.hq[tier];
            if (hq.id ~= 0) then
                tiers[#tiers + 1] = { label = 'HQ' .. tier, id = hq.id, qty = hq.qty, hq = true };
            end
        end

        for _, tier in ipairs(tiers) do
            imgui.TableNextRow();
            imgui.TableNextColumn();
            if (tier.hq) then
                imgui.TextColored(COLORS.hq, tier.label);
            else
                imgui.Text(tier.label);
            end

            imgui.TableNextColumn();
            local label = db.item_name(tier.id);
            if (tier.qty > 1) then
                label = ('%s x%d'):fmt(label, tier.qty);
            end
            item_link(tier.id, label);

            imgui.TableNextColumn();
            local item  = db.items[tier.id];
            local value = 0;
            if (item ~= nil) then
                value = item.basesell * tier.qty;
            end
            if (value > 0) then
                imgui.Text(commas(value));
            else
                imgui.TextDisabled('-');
            end

            imgui.TableNextColumn();
            draw_profit(value, cost, missing);

            imgui.TableNextColumn();
            draw_price_input(tier.id);

            imgui.TableNextColumn();
            local my_value = (prices.get(tier.id) or 0) * tier.qty;
            draw_profit(my_value, cost, missing);
        end

        imgui.EndTable();
        imgui.TextDisabled('Materials use your price when you set one, otherwise the cheapest NPC. Crystals without a price count as free.');
    end

    local function draw_favorite_button(recipe)
        local favorite = state.favorites[recipe.id] == true;
        local label    = 'Favorite###favorite';
        if (favorite) then
            label = 'Favorited###favorite';
        end

        imgui.SameLine();
        if (toggle_button(label, favorite)) then
            if (favorite) then
                state.favorites[recipe.id] = nil;
            else
                state.favorites[recipe.id] = true;
            end
            state.save_favorites();
        end
    end

    local function tracked_index(recipe)
        for index, id in ipairs(state.tracked) do
            if (id == recipe.id) then
                return index;
            end
        end

        return nil;
    end

    local function draw_track_button(recipe)
        local index = tracked_index(recipe);
        local label = 'Track###track';
        if (index ~= nil) then
            label = 'Tracking###track';
        end

        imgui.SameLine();
        if (toggle_button(label, index ~= nil)) then
            if (index ~= nil) then
                table.remove(state.tracked, index);
            elseif (#state.tracked < MAX_TRACKED) then
                state.tracked[#state.tracked + 1] = recipe.id;
                state.tracker[1] = true;
            end
            state.save_tracked();
        end
        if (imgui.IsItemHovered()) then
            set_tooltip(('Pin the materials to a small note that stays up while you craft (up to %d recipes).\n/cb track hides or shows it.'):fmt(MAX_TRACKED));
        end
    end

    local function easiest(recipes)
        local pick = nil;
        for _, recipe in ipairs(recipes) do
            if (pick == nil or recipe.level < pick.level) then
                pick = recipe;
            end
        end

        return pick;
    end

    -- On a synth: jump to breaking its result down. On a desynthesis: jump back to making the item.
    local function draw_desynth_button(recipe)
        if (recipe.desynth) then
            local source = recipe.ingredients[1];
            if (source == nil) then
                return;
            end

            local best = best_recipe(db.made_by[source.id] or {});
            if (best == nil or best.recipe.desynth) then
                return;
            end

            imgui.SameLine();
            if (imgui.Button('Show synth')) then
                open_recipe(best.recipe);
            end
            if (imgui.IsItemHovered()) then
                set_tooltip(('How to make %s: %s %d.'):fmt(db.item_name(source.id), db.crafts[best.recipe.main].name, best.recipe.level));
            end
            return;
        end

        local breaks = db.breaks_into[recipe.result] or {};
        local pick   = easiest(breaks);
        if (pick == nil) then
            return;
        end

        imgui.SameLine();
        if (imgui.Button('Show desynth')) then
            open_recipe(pick);
        end
        if (imgui.IsItemHovered()) then
            local text = ('Break %s down: %s %d.'):fmt(db.item_name(recipe.result), db.crafts[pick.main].name, pick.level);
            if (#breaks > 1) then
                text = ('%s %d desynths, all on the item page under Breaks into.'):fmt(text, #breaks);
            end
            set_tooltip(text);
        end
    end

    function draw_recipe(recipe)
        item_icon(recipe.result, 32);
        local title = recipe_label(recipe);
        if (recipe.desynth) then
            title = ('Desynthesis: %s'):fmt(title);
        end
        imgui.TextColored(COLORS.title, title);
        if (recipe.tag ~= nil and recipe.tag ~= '') then
            imgui.SameLine();
            imgui.TextDisabled(('[%s]'):fmt(recipe.tag));
        end
        draw_favorite_button(recipe);
        draw_track_button(recipe);
        draw_desynth_button(recipe);

        draw_craft_requirements(recipe);
        if (state.show_skillups[1]) then
            draw_skillups(recipe);
        end

        if (recipe.keyitem ~= 0) then
            imgui.TextColored(COLORS.keyitem, ('Requires key item: %s'):fmt(db.keyitem_name(recipe.keyitem)));
        end

        local cost, missing = draw_materials(recipe);
        draw_results(recipe, cost, missing);

        local others = db.made_by[recipe.result];
        if (others ~= nil and #others > 1) then
            section('Other recipes for this item');
            local list = {};
            for _, entry in ipairs(others) do
                if (entry.recipe ~= recipe) then
                    list[#list + 1] = entry;
                end
            end
            recipe_table('##others', list, function (entry) return entry.recipe; end, function (entry) return entry.tier; end);
        end
    end
end

-- ---------------------------------------------------------------------------
-- Item detail
-- ---------------------------------------------------------------------------

-- This section keeps its helpers to itself. Lua allows only 200 top-level locals in one file.
local draw_detail;
do
    local function position_tooltip(row)
        if (row.x ~= nil and imgui.IsItemHovered()) then
            set_tooltip(('%s  (%.1f, %.1f, %.1f)'):fmt(db.zone_name(row.zone), row.x, row.y, row.z));
        end
    end

    local function draw_vendors(rows)
        if (not begin_fit_table('##vendors', 4, SORT_FLAGS)) then
            return;
        end

        setup_column('NPC', ImGuiTableColumnFlags_WidthFixed, 130);
        setup_column('Zone', ImGuiTableColumnFlags_WidthFixed, 150);
        setup_column('Price', ImGuiTableColumnFlags_WidthFixed, 60);
        setup_column('Notes', bit.bor(ImGuiTableColumnFlags_WidthStretch, ImGuiTableColumnFlags_NoSort));
        imgui.TableHeadersRow();

        local sorted = sorted_rows('##vendors', rows, {
            function (row) return row.npc:lower(); end,
            function (row) return zone_key(row.zone); end,
            function (row) return row.price; end,
        });
        for index, row in ipairs(sorted) do
            if (index > MAX_ROWS) then
                break;
            end

            imgui.TableNextRow();
            imgui.TableNextColumn();
            imgui.Text(row.npc);
            position_tooltip(row);
            imgui.TableNextColumn();
            imgui.Text(db.zone_name(row.zone));
            imgui.TableNextColumn();
            imgui.Text(commas(row.price));
            imgui.TableNextColumn();
            imgui.TextDisabled(vendor_note(row));
        end

        imgui.EndTable();
        imgui.TextDisabled('Nation vendor prices shift with your fame. Hover an NPC for coordinates.');
    end

    local function draw_guilds(rows)
        if (not begin_fit_table('##guilds', 5, SORT_FLAGS)) then
            return;
        end

        setup_column('NPC', ImGuiTableColumnFlags_WidthFixed, 130);
        setup_column('Zone', ImGuiTableColumnFlags_WidthFixed, 150);
        setup_column('Price', ImGuiTableColumnFlags_WidthFixed, 90);
        setup_column('Hours', ImGuiTableColumnFlags_WidthFixed, 110);
        setup_column('Notes', bit.bor(ImGuiTableColumnFlags_WidthStretch, ImGuiTableColumnFlags_NoSort));
        imgui.TableHeadersRow();

        local sorted = sorted_rows('##guilds', rows, {
            function (row) return row.npc:lower(); end,
            function (row) return zone_key(row.zone); end,
            function (row) return row.price; end,
            function (row) return row.open; end,
        });
        for index, row in ipairs(sorted) do
            if (index > MAX_ROWS) then
                break;
            end

            imgui.TableNextRow();
            imgui.TableNextColumn();
            imgui.Text(row.npc);
            position_tooltip(row);
            imgui.TableNextColumn();
            imgui.Text(db.zone_name(row.zone));
            imgui.TableNextColumn();
            imgui.Text(('%s-%s'):fmt(commas(row.price), commas(row.pricemax)));
            if (imgui.IsItemHovered()) then
                set_tooltip('Price at normal stock, rising toward the second number as the shelf empties.');
            end
            imgui.TableNextColumn();
            imgui.Text(('%02d:00-%02d:00'):fmt(row.open, row.close));
            imgui.TableNextColumn();
            if (not row.stocked) then
                imgui.TextColored(COLORS.warn, 'Only stocked when players sell it');
            elseif (row.shop ~= row.npc) then
                imgui.TextDisabled(('Shares stock with %s'):fmt(row.shop));
            elseif (row.holiday ~= '') then
                imgui.TextDisabled(('Guild holiday %s'):fmt(row.holiday));
            end
        end

        imgui.EndTable();
        imgui.TextDisabled('Hours are Vana\'diel time. Guild holidays only close the shop if the server enables them.');
    end

    local function draw_drops(entries)
        if (not begin_fit_table('##drops', 5, SORT_FLAGS)) then
            return;
        end

        setup_column('Monster', ImGuiTableColumnFlags_WidthFixed, 150);
        setup_column('Zone', ImGuiTableColumnFlags_WidthFixed, 150);
        setup_column('Lv', ImGuiTableColumnFlags_WidthFixed, 44);
        setup_column('Chance', ImGuiTableColumnFlags_WidthFixed, 54);
        setup_column('Notes', bit.bor(ImGuiTableColumnFlags_WidthStretch, ImGuiTableColumnFlags_NoSort));
        imgui.TableHeadersRow();

        local sorted = sorted_rows('##drops', entries, {
            function (entry) return entry.mob.name:lower(); end,
            function (entry) return zone_key(entry.mob.zone); end,
            function (entry) return entry.mob.lvmin; end,
            function (entry) return entry.chance; end,
        });
        for index, entry in ipairs(sorted) do
            if (index > MAX_ROWS) then
                break;
            end

            local mob = entry.mob;
            imgui.TableNextRow();
            imgui.TableNextColumn();
            if (mob.nm) then
                imgui.TextColored(COLORS.warn, mob.name);
            else
                imgui.Text(mob.name);
            end
            imgui.TableNextColumn();
            imgui.Text(db.zone_name(mob.zone));
            imgui.TableNextColumn();
            imgui.Text(level_range(mob.lvmin, mob.lvmax));
            imgui.TableNextColumn();
            if (#entry.rolls > 0) then
                imgui.Text(percent(entry.chance));
            else
                imgui.TextDisabled('-');
            end

            imgui.TableNextColumn();
            local notes = {};
            if (mob.nm) then
                notes[#notes + 1] = 'NM';
            end
            if (#entry.rolls > 1) then
                notes[#notes + 1] = ('%d rolls'):fmt(#entry.rolls);
            end
            if (entry.steal) then
                notes[#notes + 1] = 'Steal';
            end
            imgui.TextDisabled(table.concat(notes, ', '));
        end

        imgui.EndTable();
        imgui.TextDisabled('Chance is per kill without Treasure Hunter, all rolls combined.');
    end

    local function draw_helm(rows)
        if (not begin_fit_table('##helm', 3, SORT_FLAGS)) then
            return;
        end

        setup_column('Type', ImGuiTableColumnFlags_WidthFixed, 90);
        setup_column('Zone', ImGuiTableColumnFlags_WidthFixed, 180);
        setup_column('Chance', ImGuiTableColumnFlags_WidthStretch);
        imgui.TableHeadersRow();

        local sorted = sorted_rows('##helm', rows, {
            function (row) return row.kind:lower(); end,
            function (row) return zone_key(row.zone); end,
            function (row) return row.rate; end,
        });
        for _, row in ipairs(sorted) do
            imgui.TableNextRow();
            imgui.TableNextColumn();
            imgui.Text(row.kind);
            imgui.TableNextColumn();
            imgui.Text(db.zone_name(row.zone));
            imgui.TableNextColumn();
            imgui.Text(percent(row.rate));
        end

        imgui.EndTable();
        imgui.TextDisabled('Chance per successful gather at that zone\'s points.');
    end

    local function tab(label, key, count, draw)
        if (count == 0) then
            return;
        end

        if (imgui.BeginTabItem(('%s (%d)###%s'):fmt(label, count, key))) then
            draw();
            imgui.EndTabItem();
        end
    end

    -- Prefers a normal synth over desynthesis, an NQ result over an HQ one, no key item, then the lowest level.
    local function recipe_rank(entry)
        local rank = entry.recipe.level;
        if (entry.recipe.keyitem ~= 0) then
            rank = rank + 500;
        end
        if (entry.tier > 0) then
            rank = rank + 1000;
        end
        if (entry.recipe.desynth) then
            rank = rank + 2000;
        end

        return rank;
    end

    function best_recipe(made_by)
        local best = nil;
        for _, entry in ipairs(made_by) do
            if (best == nil or recipe_rank(entry) < recipe_rank(best)) then
                best = entry;
            end
        end

        return best;
    end

    local function draw_see_craft(made_by)
        local best = best_recipe(made_by);
        if (best == nil) then
            return;
        end

        imgui.SameLine();
        if (imgui.SmallButton('See craft')) then
            open_recipe(best.recipe);
        end
        if (imgui.IsItemHovered()) then
            local recipe = best.recipe;
            local text   = ('%s %d'):fmt(db.crafts[recipe.main].name, recipe.level);
            if (#made_by > 1) then
                text = ('%s. %d recipes make this, all listed under Made by.'):fmt(text, #made_by);
            end
            set_tooltip(text);
        end
    end

    -- What an item breaks down into: one row per desynthesis, with every result tier side by side.
    local function draw_breaks(recipes)
        if (not begin_fit_table('##breaks', 8, SORT_FLAGS)) then
            return;
        end

        setup_column('Lv', ImGuiTableColumnFlags_WidthFixed, 34);
        setup_column('Craft', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('Crystal', ImGuiTableColumnFlags_WidthFixed, 70);
        setup_column('NQ', ImGuiTableColumnFlags_WidthFixed, 120);
        setup_column('HQ1', ImGuiTableColumnFlags_WidthFixed, 120);
        setup_column('HQ2', ImGuiTableColumnFlags_WidthFixed, 120);
        setup_column('HQ3', ImGuiTableColumnFlags_WidthFixed, 120);
        setup_column('Succ.', ImGuiTableColumnFlags_WidthFixed, 40);
        imgui.TableHeadersRow();

        local rows = sorted_rows('##breaks', recipes, {
            function (recipe) return recipe.level; end,
            function (recipe) return db.crafts[recipe.main].short; end,
            function (recipe) return db.item_lname(recipe.crystal); end,
            function (recipe) return db.item_lname(recipe.result); end,
            function (recipe) return db.item_lname(recipe.hq[1].id); end,
            function (recipe) return db.item_lname(recipe.hq[2].id); end,
            function (recipe) return db.item_lname(recipe.hq[3].id); end,
            function (recipe) return success_key(recipe); end,
        });
        for index, recipe in ipairs(rows) do
            imgui.TableNextRow();
            imgui.TableNextColumn();
            local color = recipe_color(recipe, recipe.main, recipe.level);
            if (color ~= nil) then
                imgui.PushStyleColor(ImGuiCol_Text, color);
            end
            local clicked = imgui.Selectable(('%d##breaks%d'):fmt(recipe.level, index), false, ImGuiSelectableFlags_SpanAllColumns);
            if (color ~= nil) then
                imgui.PopStyleColor(1);
            end
            if (clicked) then
                open_recipe(recipe);
            end

            imgui.TableNextColumn();
            imgui.Text(db.crafts[recipe.main].short);
            imgui.TableNextColumn();
            imgui.TextDisabled(crystal_short(recipe.crystal));
            imgui.TableNextColumn();
            imgui.Text(result_name({ id = recipe.result, qty = recipe.qty }));
            for tier = 1, 3 do
                imgui.TableNextColumn();
                if (recipe.hq[tier].id ~= 0) then
                    imgui.TextColored(COLORS.hq, result_name(recipe.hq[tier]));
                else
                    imgui.TextDisabled('-');
                end
            end

            imgui.TableNextColumn();
            local outlook = synth_outlook(recipe);
            if (outlook ~= nil) then
                imgui.TextColored(success_color(outlook.success), percent(outlook.success));
            else
                imgui.TextDisabled('-');
            end
        end

        imgui.EndTable();
        imgui.TextDisabled('Desynthesis gives an HQ result 60% of the time it succeeds. Click a row for the full recipe.');
    end

    local function draw_item(id)
        item_icon(id, 32);
        imgui.TextColored(COLORS.title, db.item_name(id));
        draw_see_craft(db.made_by[id] or {});

        local bag, total = player.count(id);
        local item       = db.items[id];
        local line       = ('Have %d in bag, %d in all storage'):fmt(bag, total);
        if (item ~= nil and item.basesell > 0) then
            line = ('%s.  Sells to NPCs for about %s gil.'):fmt(line, commas(item.basesell));
        end
        imgui.TextDisabled(line);

        imgui.AlignTextToFramePadding();
        imgui.TextDisabled('My price');
        imgui.SameLine();
        draw_price_input(id);

        local description = db.item_description(id);
        if (description ~= '') then
            imgui.PushTextWrapPos(0);
            imgui.TextUnformatted(description);
            imgui.PopTextWrapPos();
        end

        if (CRYSTAL_IDS[id]) then
            imgui.TextColored(COLORS.warn, 'Crystals drop from most field monsters while you have Signet, Sanction or Sigil.');
        end

        local made_by  = db.made_by[id] or {};
        local used_in  = db.used_in[id] or {};
        local breaks   = db.breaks_into[id] or {};
        local vendors  = db.vendors[id] or {};
        local guilds   = db.guilds[id] or {};
        local drops    = db.drops[id] or {};
        local helm     = db.helm[id] or {};

        if (#made_by + #used_in + #breaks + #vendors + #guilds + #drops + #helm == 0) then
            imgui.Spacing();
            imgui.TextDisabled('No source in the data. It may come from quests, battlefields, chests, fishing or digging.');
            return;
        end

        imgui.Spacing();
        if (imgui.BeginTabBar('##itemtabs')) then
            tab('Vendors', 'vendors', #vendors, function () draw_vendors(vendors); end);
            tab('Guilds', 'guilds', #guilds, function () draw_guilds(guilds); end);
            tab('Drops', 'drops', #drops, function () draw_drops(drops); end);
            tab('Gathering', 'helm', #helm, function () draw_helm(helm); end);
            tab('Made by', 'madeby', #made_by, function ()
                recipe_table('##madeby', made_by, function (entry) return entry.recipe; end, function (entry) return entry.tier; end);
            end);
            tab('Breaks into', 'breaks', #breaks, function () draw_breaks(breaks); end);
            tab('Used in', 'usedin', #used_in, function ()
                recipe_table('##usedin', used_in, function (entry) return entry; end, function () return 0; end);
            end);
            imgui.EndTabBar();
        end
    end

    -- Moves the detail between the book's right pane and its own window.
    local function draw_detach_button()
        local label   = 'Pop out';
        local tooltip = 'Open this in its own window, leaving the book as just the list.';
        if (state.detached) then
            label   = 'Dock';
            tooltip = 'Put this back inside the book.';
        end

        if (imgui.SmallButton(label)) then
            state.detached       = not state.detached;
            state.detail_open[1] = true;
            state.save_layout();
        end
        if (imgui.IsItemHovered()) then
            set_tooltip(tooltip);
        end
    end

    function draw_detail()
        if (#state.history > 0) then
            if (imgui.SmallButton('< Back')) then
                go_back();
            end
            imgui.SameLine();
        end
        if (state.view ~= nil) then
            if (imgui.SmallButton('Close')) then
                state.view    = nil;
                state.history = {};
            end
            imgui.SameLine();
        end
        draw_detach_button();
        imgui.Separator();

        if (state.view == nil) then
            imgui.TextDisabled('Pick a recipe or item on the left.');
            return;
        end

        if (state.view.kind == 'recipe') then
            draw_recipe(state.view.recipe);
        else
            draw_item(state.view.id);
        end
    end
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Synth history
-- ---------------------------------------------------------------------------

-- A window opening under a resting mouse leaves the game drawing its own cursor behind it. While any craftbook
-- window is hovered ImGui draws its cursor on top; the shared setting goes back the moment the mouse leaves.
local hovered        = false;
local cursor_claimed = false;
local cursor_before  = false;

local function note_hover()
    if (imgui.IsWindowHovered(ImGuiHoveredFlags_RootAndChildWindows)) then
        hovered = true;
    end
end

local function set_draw_cursor(value)
    pcall(function ()
        imgui.GetIO().MouseDrawCursor = value;
    end);
end

local function claim_cursor()
    if (cursor_claimed) then
        return;
    end

    local ok, current = pcall(function ()
        return imgui.GetIO().MouseDrawCursor;
    end);
    cursor_before  = ok and current == true;
    cursor_claimed = true;
    set_draw_cursor(true);
end

local function release_cursor()
    if (not cursor_claimed) then
        return;
    end

    cursor_claimed = false;
    set_draw_cursor(cursor_before);
end

-- Call right after Begin. The first Esc leaves an active text box and the next one closes the window.
local function close_on_escape(open)
    if (not state.esc_closes[1]) then
        return;
    end
    if (imgui.IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows) and not imgui.IsAnyItemActive() and imgui.IsKeyPressed(ImGuiKey_Escape, false)) then
        open[1] = false;
    end
end

-- The history window keeps its helpers to itself. Lua allows only 200 top-level locals in one file.
local draw_history;
do
    local HISTORY_ROWS       = 500;
    local HISTORY_NAME_WIDTH = 220;

    local history_cache = {};

    local function outcome_color(outcome)
        if (outcome:sub(1, 2) == 'HQ') then
            return COLORS.hq;
        end
        if (outcome == 'Break') then
            return COLORS.bad;
        end
        if (outcome == 'Interrupted') then
            return COLORS.warn;
        end

        return nil;
    end

    local function entry_recipe_name(entry)
        local recipe = db.recipe_by_id[entry.recipe];
        if (recipe ~= nil) then
            return db.item_name(recipe.result);
        end
        if (entry.item ~= 0) then
            return db.item_name(entry.item);
        end

        return 'Unknown recipe';
    end

    local function entry_result(entry)
        if (entry.item == 0) then
            return entry_recipe_name(entry);
        end
        if (entry.qty > 1) then
            return ('%s x%d'):fmt(db.item_name(entry.item), entry.qty);
        end

        return db.item_name(entry.item);
    end

    local function new_summary(recipe_id)
        return { recipe = recipe_id, synths = 0, nq = 0, hq = 0, grades = { 0, 0, 0 }, breaks = 0, skillups = 0, gained = 0 };
    end

    -- Total skill gained by one synth, in tenths, across every craft it raised.
    local function entry_gain(entry)
        local tenths = 0;
        for _, amount in pairs(entry.skillups or {}) do
            tenths = tenths + amount;
        end

        return tenths;
    end

    local function tenths_text(tenths)
        return ('+%d.%d'):fmt(math.floor(tenths / 10), tenths % 10);
    end

    local function entry_skillup_text(entry)
        local parts = {};
        for craft = 1, #db.crafts do
            local amount = (entry.skillups or {})[craft];
            if (amount ~= nil) then
                parts[#parts + 1] = ('%s %s'):fmt(tenths_text(amount), db.crafts[craft].short);
            end
        end

        return table.concat(parts, '  ');
    end

    local function count_entry(summary, entry)
        summary.synths = summary.synths + 1;
        local gain = entry_gain(entry);
        if (gain > 0) then
            summary.skillups = summary.skillups + 1;
            summary.gained   = summary.gained + gain;
        end
        if (entry.outcome == 'NQ' or entry.outcome == 'Desynth' or entry.outcome == 'Success') then
            summary.nq = summary.nq + 1;
        elseif (entry.outcome:sub(1, 2) == 'HQ') then
            summary.hq = summary.hq + 1;
            local grade = tonumber(entry.outcome:sub(3, 3));
            if (grade ~= nil and entry.outcome:sub(4, 4) == '') then
                summary.grades[grade] = summary.grades[grade] + 1;
            end
        elseif (entry.outcome == 'Break') then
            summary.breaks = summary.breaks + 1;
        end
    end

    -- Rebuilt only when a synth lands or the character filter changes.
    local function history_view()
        local char = history.character();
        local key  = ('%d|%s|%s'):fmt(history.revision or 0, char, tostring(state.log_all[1]));
        if (history_cache.key == key) then
            return history_cache;
        end

        local rows      = {};
        local total     = new_summary(0);
        local by_recipe = {};
        local recipes   = {};
        for index = #history.entries, 1, -1 do
            local entry = history.entries[index];
            if (state.log_all[1] or entry.char == char) then
                rows[#rows + 1] = entry;
                count_entry(total, entry);

                local summary = by_recipe[entry.recipe];
                if (summary == nil) then
                    summary = new_summary(entry.recipe);
                    summary.name = entry_recipe_name(entry);
                    by_recipe[entry.recipe] = summary;
                    recipes[#recipes + 1] = summary;
                end
                count_entry(summary, entry);
            end
        end

        history_cache = { key = key, rows = rows, total = total, recipes = recipes };
        return history_cache;
    end

    local function hq_rate(summary)
        local made = summary.nq + summary.hq;
        if (made == 0) then
            return 0;
        end

        return summary.hq / made;
    end

    local function draw_history_log(view)
        local columns = 6;
        if (state.log_all[1]) then
            columns = 7;
        end
        if (not begin_table('##historylog2', columns, bit.bor(LIST_FLAGS, SORT_FLAGS), { 0, -imgui.GetTextLineHeightWithSpacing() })) then
            return;
        end

        imgui.TableSetupScrollFreeze(0, 1);
        setup_column('When', ImGuiTableColumnFlags_WidthFixed, 90);
        setup_column('Result', ImGuiTableColumnFlags_WidthFixed, HISTORY_NAME_WIDTH);
        setup_column('Outcome', ImGuiTableColumnFlags_WidthFixed, 80);
        setup_column('Tier', ImGuiTableColumnFlags_WidthFixed, 36);
        setup_column('Lost', ImGuiTableColumnFlags_WidthFixed, 36);
        setup_column('Skill-up', ImGuiTableColumnFlags_WidthFixed, 90);
        if (state.log_all[1]) then
            setup_column('Character', ImGuiTableColumnFlags_WidthFixed, 90);
        end
        imgui.TableHeadersRow();

        local rows = sorted_rows('##historylog2', view.rows, {
            function (entry) return -entry.time; end,
            function (entry) return entry_result(entry):lower(); end,
            function (entry) return entry.outcome; end,
            function (entry) return entry.tier; end,
            function (entry) return entry.lost; end,
            function (entry) return entry_gain(entry); end,
            function (entry) return entry.char:lower(); end,
        });
        for index, entry in ipairs(rows) do
            if (index > HISTORY_ROWS) then
                break;
            end

            imgui.TableNextRow();
            imgui.TableNextColumn();
            imgui.TextDisabled(os.date('%m/%d %H:%M', entry.time));

            imgui.TableNextColumn();
            local recipe = db.recipe_by_id[entry.recipe];
            if (recipe ~= nil) then
                if (imgui.TextLink(('%s##hist%d'):fmt(entry_result(entry), index))) then
                    state.visible[1] = true;
                    open_recipe(recipe);
                end
            else
                imgui.Text(entry_result(entry));
            end

            imgui.TableNextColumn();
            colored_text(outcome_color(entry.outcome), entry.outcome);

            imgui.TableNextColumn();
            if (entry.tier >= 0) then
                imgui.Text(('T%d'):fmt(entry.tier));
            else
                imgui.TextDisabled('-');
            end

            imgui.TableNextColumn();
            if (entry.lost > 0) then
                imgui.TextColored(COLORS.bad, tostring(entry.lost));
            end

            imgui.TableNextColumn();
            imgui.TextColored(COLORS.good, entry_skillup_text(entry));

            if (state.log_all[1]) then
                imgui.TableNextColumn();
                imgui.TextDisabled(entry.char);
            end
        end

        imgui.EndTable();
    end

    local function draw_history_recipes(view)
        if (not begin_table('##historyrecipes2', 11, bit.bor(LIST_FLAGS, SORT_FLAGS), { 0, -imgui.GetTextLineHeightWithSpacing() })) then
            return;
        end

        imgui.TableSetupScrollFreeze(0, 1);
        setup_column('Recipe', ImGuiTableColumnFlags_WidthFixed, HISTORY_NAME_WIDTH);
        setup_column('Synths', ImGuiTableColumnFlags_WidthFixed, 50);
        setup_column('NQ', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('HQ', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('HQ1', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('HQ2', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('HQ3', ImGuiTableColumnFlags_WidthFixed, 40);
        setup_column('Breaks', ImGuiTableColumnFlags_WidthFixed, 50);
        setup_column('HQ %', ImGuiTableColumnFlags_WidthFixed, 50);
        setup_column('Skill-ups', ImGuiTableColumnFlags_WidthFixed, 60);
        setup_column('Gained', ImGuiTableColumnFlags_WidthFixed, 50);
        imgui.TableHeadersRow();

        local rows = sorted_rows('##historyrecipes2', view.recipes, {
            function (summary) return summary.name:lower(); end,
            function (summary) return summary.synths; end,
            function (summary) return summary.nq; end,
            function (summary) return summary.hq; end,
            function (summary) return summary.grades[1]; end,
            function (summary) return summary.grades[2]; end,
            function (summary) return summary.grades[3]; end,
            function (summary) return summary.breaks; end,
            function (summary) return hq_rate(summary); end,
            function (summary) return summary.skillups; end,
            function (summary) return summary.gained; end,
        });
        for index, summary in ipairs(rows) do
            imgui.TableNextRow();
            imgui.TableNextColumn();
            local recipe = db.recipe_by_id[summary.recipe];
            if (recipe ~= nil) then
                if (imgui.TextLink(('%s##histrecipe%d'):fmt(summary.name, index))) then
                    state.visible[1] = true;
                    open_recipe(recipe);
                end
            else
                imgui.Text(summary.name);
            end

            imgui.TableNextColumn();
            imgui.Text(tostring(summary.synths));
            imgui.TableNextColumn();
            imgui.Text(tostring(summary.nq));
            imgui.TableNextColumn();
            imgui.TextColored(COLORS.hq, tostring(summary.hq));
            for grade = 1, 3 do
                imgui.TableNextColumn();
                imgui.TextDisabled(tostring(summary.grades[grade]));
            end
            imgui.TableNextColumn();
            imgui.TextColored(COLORS.bad, tostring(summary.breaks));
            imgui.TableNextColumn();
            imgui.Text(percent(hq_rate(summary)));
            imgui.TableNextColumn();
            imgui.Text(tostring(summary.skillups));
            imgui.TableNextColumn();
            if (summary.gained > 0) then
                imgui.TextColored(COLORS.good, tenths_text(summary.gained));
            else
                imgui.TextDisabled('-');
            end
        end

        imgui.EndTable();
    end

    function draw_history()
        imgui.SetNextWindowSize({ 640, 420 }, ImGuiCond_FirstUseEver);
        if (imgui.Begin('Craftbook history###cbhistory', state.log_visible, ImGuiWindowFlags_None)) then
            draw_skin(true, 1);
            close_on_escape(state.log_visible);
            note_hover();
            local view  = history_view();
            local total = view.total;
            imgui.Text(('%d synths'):fmt(total.synths));
            imgui.SameLine();
            imgui.TextDisabled(('%d NQ'):fmt(total.nq));
            imgui.SameLine();
            imgui.TextColored(COLORS.hq, ('%d HQ (%s)'):fmt(total.hq, percent(hq_rate(total))));
            imgui.SameLine();
            imgui.TextColored(COLORS.bad, ('%d breaks'):fmt(total.breaks));
            imgui.SameLine();
            imgui.TextColored(COLORS.good, ('%s skill from %d skill-ups'):fmt(tenths_text(total.gained), total.skillups));
            imgui.SameLine();
            imgui.Checkbox('All characters', state.log_all);
            if (imgui.IsItemHovered()) then
                set_tooltip(('Off: only %s.'):fmt(history.character()));
            end

            if (imgui.BeginTabBar('##historytabs')) then
                if (imgui.BeginTabItem('Log')) then
                    draw_history_log(view);
                    imgui.EndTabItem();
                end
                if (imgui.BeginTabItem('By recipe')) then
                    draw_history_recipes(view);
                    imgui.EndTabItem();
                end
                imgui.EndTabBar();
            end
            imgui.TextDisabled('HQ1+ means several grades give the same item, so only the lowest is certain. Tier is at your skill and support when it landed.');
        end
        imgui.End();
    end

    function ui.set_state(value)
        state = value;
    end
end

local function synths_possible(rows)
    local synths = nil;
    for _, row in ipairs(rows) do
        local bag = player.count(row.id);
        local can = math.floor(bag / row.count);
        if (synths == nil or can < synths) then
            synths = can;
        end
    end

    return synths or 0;
end

local function draw_tracked_row(row)
    local bag, total = player.count(row.id);
    local color      = COLORS.good;
    if (bag < row.count and total >= row.count) then
        color = COLORS.warn;
    elseif (bag < row.count) then
        color = COLORS.bad;
    end

    imgui.TableNextRow();
    imgui.TableNextColumn();
    imgui.TextColored(color, ('%d/%d'):fmt(bag, row.count));
    imgui.TableNextColumn();
    imgui.TextColored(color, db.item_name(row.id));
    if (total > bag and imgui.IsItemHovered()) then
        set_tooltip(('%d more in storage'):fmt(total - bag));
    end
end

-- The right-hand column: HQ tier and chance, success, and main-craft skill-up chance, support included.
local function draw_tracked_odds(recipe)
    local outlook = synth_outlook(recipe);
    if (outlook == nil) then
        imgui.TextDisabled('-');
        return;
    end

    if (not outlook.can_hq) then
        imgui.TextDisabled('No HQ');
    elseif (outlook.tier == nil) then
        imgui.TextColored(COLORS.hq, ('HQ %s'):fmt(percent(outlook.hq)));
    else
        imgui.TextColored(COLORS.hq, ('T%d %s'):fmt(outlook.tier, percent(outlook.hq)));
    end
    if (imgui.IsItemHovered()) then
        set_tooltip('HQ tier and HQ chance when the synth succeeds.');
    end

    imgui.TextColored(success_color(outlook.success), ('Succ %s'):fmt(percent(outlook.success)));
    if (imgui.IsItemHovered()) then
        set_tooltip('Chance the synth does not break.');
    end

    local skillup = skillup_outlook(recipe, recipe.main);
    if (skillup == nil) then
        return;
    end

    imgui.TextDisabled(('SU %s'):fmt(percent(skillup_per_synth(skillup, outlook.success))));
    if (imgui.IsItemHovered()) then
        set_tooltip(('%s skill-up chance per synth.'):fmt(db.crafts[recipe.main].name));
    end
end

-- Returns true when the player right-clicked the name to stop tracking it.
local function draw_tracked_name(recipe, index, synths)
    if (imgui.TextLink(('%s##tracked%d'):fmt(db.item_name(recipe.result), index))) then
        state.visible[1] = true;
        open_recipe(recipe);
    end
    local untrack = imgui.IsItemClicked(ImGuiMouseButton_Right);
    if (imgui.IsItemHovered()) then
        set_tooltip('Click to open in the book. Right-click to stop tracking.');
    end

    imgui.SameLine();
    imgui.TextDisabled(('(%d)'):fmt(synths));
    if (imgui.IsItemHovered()) then
        set_tooltip('Synths your bag covers.');
    end

    return untrack;
end

-- One row of the tracker table: the recipe and its materials on the left, the odds on the right.
local function draw_tracked_recipe(recipe, index)
    local rows   = material_rows(recipe);
    local synths = synths_possible(rows);

    imgui.TableNextRow();
    imgui.TableNextColumn();
    local untrack = draw_tracked_name(recipe, index, synths);

    if (begin_table(('##trackedrows%d'):fmt(index), 2, ImGuiTableFlags_SizingFixedFit)) then
        for _, row in ipairs(rows) do
            draw_tracked_row(row);
        end
        imgui.EndTable();
    end

    if (state.tracker_odds[1]) then
        imgui.TableNextColumn();
        draw_tracked_odds(recipe);
    end

    return untrack;
end

local function draw_tracker()
    -- Under Classic the art carries the note's opacity, so the flat fill behind it is switched off.
    if (active_theme.skin ~= nil and skin.get(active_theme.skin) ~= nil) then
        imgui.SetNextWindowBgAlpha(0);
    else
        imgui.SetNextWindowBgAlpha(state.tracker_alpha);
    end
    imgui.SetNextWindowPos({ 20, 200 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSize({ 320, 300 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('Craftbook tracker###cbtracker', state.tracker, TRACKER_FLAGS)) then
        draw_skin(false, state.tracker_alpha);
        note_hover();
        local remove = nil;
        local columns = 1;
        if (state.tracker_odds[1]) then
            columns = 2;
        end
        if (begin_table(('##tracker%d'):fmt(columns), columns, TRACKER_TABLE_FLAGS)) then
            for index, id in ipairs(state.tracked) do
                local recipe = db.recipe_by_id[id];
                if (recipe ~= nil and draw_tracked_recipe(recipe, index)) then
                    remove = index;
                end
            end
            imgui.EndTable();
        end

        if (remove ~= nil) then
            table.remove(state.tracked, remove);
            state.save_tracked();
        end
    end
    imgui.End();
end

local function draw_scrolled_detail()
    if (state.scroll_detail) then
        imgui.SetScrollY(0);
        state.scroll_detail = false;
    end
    draw_detail();
end

-- The list and the detail side by side.
local function draw_docked_panes()
    local width = imgui.GetContentRegionAvail();
    local left  = math.max(320, math.floor(width * 0.40));

    imgui.BeginChild('##list', { left, 0 }, bit.bor(ImGuiChildFlags_Borders, ImGuiChildFlags_ResizeX));
    draw_list();
    imgui.EndChild();

    imgui.SameLine();

    imgui.BeginChild('##detail', { 0, 0 }, ImGuiChildFlags_Borders);
    draw_scrolled_detail();
    imgui.EndChild();
end

-- With the detail popped out the book is only the list, so it may be much narrower.
local function draw_list_pane()
    imgui.BeginChild('##listonly', { 0, 0 }, ImGuiChildFlags_Borders);
    draw_list();
    imgui.EndChild();
end

local function draw_book()
    imgui.SetNextWindowSize({ 1000, 620 }, ImGuiCond_FirstUseEver);
    if (state.detached) then
        imgui.SetNextWindowSizeConstraints({ 360, 240 }, { 4000, 4000 });
    else
        imgui.SetNextWindowSizeConstraints({ 700, 360 }, { 4000, 4000 });
    end

    if (imgui.Begin('Craftbook###craftbook', state.visible, ImGuiWindowFlags_None)) then
        draw_skin(true, 1);
        close_on_escape(state.visible);
        note_hover();
        if (not db.loaded) then
            imgui.TextColored(COLORS.bad, db.error or 'Data not loaded.');
        else
            icons.enabled = state.icons[1];

            draw_filters();
            refresh_results();
            if (state.detached) then
                draw_list_pane();
            else
                draw_docked_panes();
            end
        end
    end
    imgui.End();
end

-- ---------------------------------------------------------------------------
-- Settings window
-- ---------------------------------------------------------------------------

local draw_settings;
do
    local MIN_SCALE   = 0.75;
    local MAX_SCALE   = 2.00;
    local MIN_OPACITY = 0.10;

    local WINDOW_TYPES = { 'Type 1', 'Type 2', 'Type 3', 'Type 4', 'Type 5', 'Type 6', 'Type 7', 'Type 8' };

    -- The scale slider edits this copy and applies on release, so the window does not resize under the mouse.
    local scale_edit = { 1 };

    local function tooltip(text)
        if (imgui.IsItemHovered()) then
            set_tooltip(text);
        end
    end

    local function saved_checkbox(label, value, text)
        if (imgui.Checkbox(label, value)) then
            state.save_settings();
        end
        tooltip(text);
    end

    local function draw_theme()
        local names   = themes.names();
        local current = themes.index_of(state.theme);
        local picked  = draw_combo('Theme', names, current, nil, in_order(names));
        tooltip('The look of every craftbook window. /cb theme <name> works too.');
        if (picked ~= current) then
            state.theme = themes.key_at(picked);
            state.save_theme();
        end
    end

    local function draw_window_type()
        local first = 'Game setting';
        local game  = skin.game_type();
        if (game ~= nil) then
            first = ('Game setting (%s)'):fmt(WINDOW_TYPES[game + 1]);
        end

        local current = state.window_type + 1;
        local picked  = draw_combo('Window type', WINDOW_TYPES, current, first, in_order(WINDOW_TYPES));
        tooltip('Classic draws the window art from your game install.\nGame setting follows Config > Windows > Shared > Window Type.');
        if (picked ~= current) then
            state.window_type = picked - 1;
            state.save_settings();
        end
    end

    local function draw_scale()
        imgui.SetNextItemWidth(px(160));
        imgui.SliderFloat('UI scale', scale_edit, MIN_SCALE, MAX_SCALE, '%.2f');
        if (imgui.IsItemDeactivatedAfterEdit()) then
            state.scale = math.floor(scale_edit[1] * 20 + 0.5) / 20;
            state.save_settings();
        elseif (not imgui.IsItemActive()) then
            scale_edit[1] = state.scale;
        end
        tooltip('Text and widget size for every craftbook window. Applies when you let go.');

        imgui.SameLine();
        if (imgui.SmallButton('Reset##scale')) then
            state.scale = 1;
            state.save_settings();
        end
    end

    local function draw_detached()
        local value = { state.detached };
        if (imgui.Checkbox('Detail in its own window', value)) then
            state.detached       = value[1];
            state.detail_open[1] = true;
            state.save_settings();
        end
        tooltip('Same as Pop out and Dock: the book shows only the list and the recipe or item opens beside it.');
    end

    local function draw_tracker_opacity()
        local value = { state.tracker_alpha };
        imgui.SetNextItemWidth(px(160));
        if (imgui.SliderFloat('Background', value, MIN_OPACITY, 1, '%.2f')) then
            state.tracker_alpha = value[1];
        end
        if (imgui.IsItemDeactivatedAfterEdit()) then
            state.save_settings();
        end
        tooltip('How solid the tracker note is behind its text.');
    end

    function draw_settings()
        if (imgui.Begin('Craftbook settings###cbsettings', state.settings_visible, ImGuiWindowFlags_AlwaysAutoResize)) then
            draw_skin(true, 1);
            close_on_escape(state.settings_visible);
            note_hover();

            section('Appearance');
            draw_theme();
            if (active_theme.skin ~= nil) then
                draw_window_type();
            end
            draw_scale();
            saved_checkbox('Item icons', state.icons, 'Show item icons in the lists and on item and recipe pages.');

            section('Layout');
            draw_detached();
            saved_checkbox('Esc closes windows', state.esc_closes, 'Pressing Esc closes the craftbook window you are in.');

            section('Recipe page');
            saved_checkbox('Skill-ups section', state.show_skillups, 'Show the skill-up chance and gain odds on each recipe.');

            section('Tracker note');
            saved_checkbox('Show the note', state.tracker, 'Show or hide the tracked recipes note. /cb track does the same.');
            saved_checkbox('Odds column', state.tracker_odds, 'Show HQ tier, success and skill-up chance beside each tracked recipe.');
            draw_tracker_opacity();
        end
        imgui.End();
    end
end

local function draw_detail_window()
    imgui.SetNextWindowSize({ 560, 620 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('Craftbook detail###cbdetail', state.detail_open, ImGuiWindowFlags_None)) then
        draw_skin(true, 1);
        close_on_escape(state.detail_open);
        note_hover();
        draw_scrolled_detail();
    end
    imgui.End();
end

-- /cb lvl: a level range (and craft) for this opening only, with the Skill-ups filter out of the way.
-- What it replaced waits in state.quick and comes back when the book closes.
function ui.quick_look(low, high, craft)
    if (state.quick == nil) then
        state.quick = { mode = state.mode, craft = state.craft, level_min = state.level_min[1], level_max = state.level_max[1], skillup = state.skillup[1] };
    end

    state.level_min[1] = low;
    state.level_max[1] = high;
    state.skillup[1]   = false;
    state.search[1]    = '';
    if (craft ~= nil) then
        state.craft = craft;
    end
    if (state.mode ~= MODE_INGREDIENTS) then
        state.mode = MODE_RESULTS;
    end
    state.visible[1] = true;
end

local function end_quick_look()
    local saved = state.quick;
    state.mode         = saved.mode;
    state.craft        = saved.craft;
    state.level_min[1] = saved.level_min;
    state.level_max[1] = saved.level_max;
    state.skillup[1]   = saved.skillup;
    state.quick        = nil;
end

function ui.render()
    if (state == nil) then
        return;
    end
    if (state.quick ~= nil and not state.visible[1]) then
        end_quick_look();
    end

    local tracking = db.loaded and state.tracker[1] and #state.tracked > 0;
    local logging  = db.loaded and state.log_visible[1];
    local detail   = db.loaded and state.detached and state.detail_open[1] and state.view ~= nil;
    local settings = state.settings_visible[1];
    if (not tracking and not logging and not detail and not settings and not state.visible[1]) then
        release_cursor();
        return;
    end
    hovered = false;

    link_id = 0;
    if (db.loaded) then
        db.prepare_names();
        player.refresh(#db.crafts);
    end

    skin.forced = state.window_type;
    local theme = themes.get(state.theme);
    if (theme ~= active_theme) then
        use_theme(theme);
    end

    if (font_base == nil) then
        font_base = imgui.GetFontSize();
    end
    -- The current font at a new size, which popups and tooltips inherit.
    local font_pushed = ui_scale() ~= 1 and pcall(imgui.PushFont, imgui.GetFont(), font_base * ui_scale());

    local pushed_colors, pushed_vars = themes.push(theme, ui_scale());
    if (tracking) then
        draw_tracker();
    end
    if (state.visible[1]) then
        draw_book();
    end
    if (detail) then
        draw_detail_window();
    end
    if (logging) then
        draw_history();
    end
    if (settings) then
        draw_settings();
    end
    themes.pop(pushed_colors, pushed_vars);
    if (font_pushed) then
        imgui.PopFont();
    end

    if (hovered) then
        claim_cursor();
    else
        release_cursor();
    end
end

function ui.release()
    release_cursor();
    skin.release();
end

-- HQ tier (0-3) the recipe lands at right now, or nil when it cannot HQ.
function ui.synth_tier(recipe)
    player.refresh(#db.crafts);
    use_real_skills = true;
    local outlook = synth_outlook(recipe);
    use_real_skills = false;
    if (outlook == nil or not outlook.can_hq) then
        return nil;
    end

    return outlook.tier;
end

-- An exact name wins; otherwise a search matching only one craftable item opens it.
local function find_item(text)
    local lower = text:lower();
    local words = words_of(text);
    local found = nil;
    local count = 0;
    for _, id in ipairs(db.item_ids) do
        local name = db.items[id].lname;
        if (name == lower) then
            return id;
        end
        if (db.made_by[id] ~= nil and contains_all(name, words)) then
            found = id;
            count = count + 1;
        end
    end

    if (count == 1) then
        return found;
    end

    return nil;
end

function ui.search(text)
    state.visible[1] = true;
    state.search[1]  = text;
    if (state.mode == MODE_FAVORITES) then
        state.mode = MODE_RESULTS;
    end

    if (text == '' or not db.loaded) then
        return;
    end

    db.prepare_names();
    local id = find_item(text);
    if (id == nil) then
        return;
    end

    local best = best_recipe(db.made_by[id] or {});
    if (best ~= nil and not best.recipe.desynth) then
        open_recipe(best.recipe);
        return;
    end

    open_item(id);
end

return ui;
