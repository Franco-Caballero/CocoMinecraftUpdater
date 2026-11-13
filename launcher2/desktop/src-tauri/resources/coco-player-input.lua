-- Only Coco's own actions; no native menus, file chooser, shell or external links.
local last_move = 0
local function send(action)
    if action == 'wake' then
        local now = mp.get_time()
        if now - last_move < 0.15 then return end
        last_move = now
    end
    mp.commandv('script-message', 'coco-input', action)
end
local bindings = {
    MBTN_LEFT='toggle', MBTN_LEFT_DBL='fullscreen', MOUSE_MOVE='wake',
    SPACE='toggle', k='toggle', j='back', l='forward', LEFT='back', RIGHT='forward',
    UP='volume-up', DOWN='volume-down', m='mute', f='fullscreen', ESC='escape',
}
for key, action in pairs(bindings) do
    mp.add_forced_key_binding(key, 'coco-' .. key, function() send(action) end)
end
