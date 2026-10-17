require('common');

local ffi = require('ffi');
local d3d = require('d3d8');
local C   = ffi.C;

local MAX_ICONS = 512;

local icons = {
    enabled = true,
    broken  = false,
    full    = false,
    cache   = {},
    count   = 0,
};

function icons.release()
    for _, entry in pairs(icons.cache) do
        if (entry ~= false) then
            entry.texture:Release();
        end
    end

    icons.cache = {};
    icons.count = 0;
    icons.full  = false;
end

-- Call before anything is drawn. A full cache is emptied here, between frames, never while ImGui still has this
-- frame's icons queued to draw: releasing those mid-frame left ImGui drawing freed textures.
function icons.new_frame()
    if (icons.full) then
        icons.release();
    end
end

local function create(item_id)
    local item = AshitaCore:GetResourceManager():GetItemById(item_id);
    if (item == nil or item.Bitmap == nil or item.ImageSize == nil or item.ImageSize == 0) then
        return false;
    end

    local texture = ffi.new('IDirect3DTexture8*[1]');
    local result  = C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), item.Bitmap, item.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0xFF000000, nil, nil, texture);
    if (result ~= C.S_OK) then
        return false;
    end

    local handle = ffi.cast('IDirect3DTexture8*', texture[0]);
    return { texture = handle, id = tonumber(ffi.cast('uint32_t', handle)) };
end

function icons.get(item_id)
    if (not icons.enabled or icons.broken) then
        return nil;
    end

    local entry = icons.cache[item_id];
    if (entry == nil) then
        if (icons.count >= MAX_ICONS) then
            icons.full = true;
            return nil;
        end

        local ok, created = pcall(create, item_id);
        if (not ok) then
            icons.broken = true;
            print(('[craftbook] Item icons disabled: %s'):fmt(tostring(created)));
            return nil;
        end

        entry = created;
        icons.cache[item_id] = entry;
        if (entry ~= false) then
            icons.count = icons.count + 1;
        end
    end

    if (entry == false) then
        return nil;
    end

    return entry.id;
end

return icons;
