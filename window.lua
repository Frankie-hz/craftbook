require('common');
require('win32types');

local chat = require('chat');
local d3d  = require('d3d8');
local ffi  = require('ffi');
local C    = ffi.C;

ffi.cdef[[
    BOOL GetClientRect(HWND hWnd, LPRECT lpRect);
    BOOL GetWindowRect(HWND hWnd, LPRECT lpRect);
    BOOL IsZoomed(HWND hWnd);
    BOOL SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int X, int Y, int cx, int cy, UINT uFlags);
    BOOL ShowWindow(HWND hWnd, int nCmdShow);
]];

pcall(ffi.cdef, 'typedef struct { DWORD cbSize; DWORD flags; HCURSOR hCursor; POINT ptScreenPos; } craftbook_cursor_info;');
pcall(ffi.cdef, 'BOOL GetCursorInfo(craftbook_cursor_info* info);');

local CURSOR_SHOWING = 1;

local SWP_NOMOVE    = 0x0002;
local SWP_NOZORDER  = 0x0004;
local SW_RESTORE    = 9;
local BACKBUFFER    = 0;
local RESTORE_DELAY = 0.2;

local window = {};

local function message(text)
    print(chat.header(addon.name) .. chat.message(text));
end

local function game_window()
    return ffi.cast('HWND', AshitaCore:GetProperties():GetFinalFantasyHwnd());
end

-- The size the game really renders at, read from its back buffer.
local function render_size()
    local result, surface = d3d.get_device():GetBackBuffer(BACKBUFFER, C.D3DBACKBUFFER_TYPE_MONO);
    if (result ~= C.S_OK or surface == nil) then
        return nil, nil;
    end

    local _, desc = surface:GetDesc();
    surface:Release();
    if (desc == nil) then
        return nil, nil;
    end

    return desc.Width, desc.Height;
end

-- Sizes the window so its drawing area is exactly the render size; the frame is whatever Windows adds around it.
local function resize(hwnd, width, height)
    local client = ffi.new('RECT');
    local frame  = ffi.new('RECT');
    C.GetClientRect(hwnd, client);
    C.GetWindowRect(hwnd, frame);

    local border_w = (frame.right - frame.left) - (client.right - client.left);
    local border_h = (frame.bottom - frame.top) - (client.bottom - client.top);
    C.SetWindowPos(hwnd, nil, 0, 0, width + border_w, height + border_h, bit.bor(SWP_NOMOVE, SWP_NOZORDER));
    message(('Game window set to %dx%d, the size the game renders at.'):fmt(width, height));
end

-- A stretched window (maximized, snapped or dragged) scales the picture but not ImGui's mouse, so addons miss clicks.
function window.fit()
    local width, height = render_size();
    if (width == nil) then
        message('Could not read the render size.');
        return;
    end

    local hwnd = game_window();
    if (C.IsZoomed(hwnd) == 0) then
        resize(hwnd, width, height);
        return;
    end

    -- Un-maximize first; the borders are only measurable once the restore has gone through.
    C.ShowWindow(hwnd, SW_RESTORE);
    ashita.tasks.oncef(RESTORE_DELAY, function ()
        resize(hwnd, width, height);
    end);
end

local cursor_info = nil;

-- True while Windows draws the mouse (the game's hardware mouse), false while it is hidden, nil when it cannot tell.
function window.system_cursor_visible()
    local ok, visible = pcall(function ()
        if (cursor_info == nil) then
            cursor_info = ffi.new('craftbook_cursor_info');
            cursor_info.cbSize = ffi.sizeof(cursor_info);
        end
        if (C.GetCursorInfo(cursor_info) == 0) then
            return nil;
        end

        return cursor_info.flags % 2 == CURSOR_SHOWING;
    end);
    if (not ok) then
        return nil;
    end

    return visible;
end

return window;
