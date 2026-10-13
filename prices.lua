require('common');

local MAX_PRICE = 999999999;
local MAX_LINES = 100000;

-- Custom prices the player typed in, per item: what they pay for it and what they sell it for.
-- Shared by every character on this install.
local prices = {
    values   = {},
    revision = 0,
};

local function folder()
    return ('%s\\config\\addons\\%s\\'):fmt(AshitaCore:GetInstallPath(), addon.name);
end

local function file_path()
    return folder() .. 'ah_prices.tsv';
end

function prices.load()
    prices.values   = {};
    prices.revision = prices.revision + 1;

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

        local id, price = line:match('^(%d+)\t(%d+)');
        if (id ~= nil) then
            prices.values[tonumber(id)] = tonumber(price);
        end
    end

    file:close();
end

function prices.save()
    prices.revision = prices.revision + 1;
    if (not ashita.fs.exists(folder())) then
        ashita.fs.create_dir(folder());
    end

    local file = io.open(file_path(), 'w');
    if (file == nil) then
        return;
    end

    local ids = {};
    for id, _ in pairs(prices.values) do
        ids[#ids + 1] = id;
    end
    table.sort(ids);

    for _, id in ipairs(ids) do
        file:write(('%d\t%d\n'):fmt(id, prices.values[id]));
    end

    file:close();
end

function prices.get(id)
    return prices.values[id];
end

function prices.set(id, price)
    if (price <= 0) then
        prices.values[id] = nil;
        return;
    end

    prices.values[id] = math.min(price, MAX_PRICE);
end

return prices;
