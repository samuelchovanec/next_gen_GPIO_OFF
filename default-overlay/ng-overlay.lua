local api = ...
local matrix = require "matrix2d"

local M = {}

local reserve_bottom, reserve_right, placement
local ken_burns, progress_style

local progress_shader = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform float progress_angle;

    float interp(float x) {
        return 2.0 * x * x * x - 3.0 * x * x + 1.0;
    }

    void main() {
        vec2 pos = TexCoord;
        float angle = atan(pos.x - 0.5, pos.y - 0.5);
        float dist = clamp(distance(pos, vec2(0.5, 0.5)), 0.0, 0.5) * 2.0;
        float alpha = interp(pow(dist, 8.0));
        if (angle > progress_angle) {
            gl_FragColor = vec4(1.0, 1.0, 1.0, alpha);
        } else {
            gl_FragColor = vec4(0.5, 0.5, 0.5, alpha);
        }
    }
]]
local white = resource.create_colored_texture(1,1,1,1)
local black = resource.create_colored_texture(0,0,0,1)

local function Playlist()
    local preload = 1
    local total_duration
    local next_swap, next_idx
    local playlist = {}
    local state = 'init'
    local player = api.create_resource()

    local function recalc_next_switch()
        if total_duration == 0 then
            return
        end
        local now = api.time()
        local cycle_offset = now % total_duration
        local cycle_start = now - cycle_offset
        next_idx = nil
        for idx, item in ipairs(playlist) do
            if item.offset > cycle_offset then
                next_idx = idx
                next_swap = cycle_start + item.offset
                break
            end
        end
        if not next_idx then
            next_idx = 1
            next_swap = cycle_start + total_duration
        end
        state = 'preload'
    end

    local function update(new_playlist)
        playlist = new_playlist
        total_duration = 0
        for _, item in ipairs(playlist) do
            item.duration = math.max(2, item.duration)
            item.offset = total_duration
            total_duration = total_duration + item.duration
        end
        if state == 'init' and #playlist > 0 then
            state = 'swap'
            player:update(playlist[1].asset)
            next_swap = api.time()
        else
            recalc_next_switch()
        end
    end

    local function draw(...)
        if total_duration == 0 then
            return
        end
        local now, jumped = api.time()
        if jumped then
            recalc_next_switch()
        end
        if state == 'preload' and now > next_swap - preload then
            player:update(playlist[next_idx].asset)
            state = 'swap'
        elseif state == 'swap' and now >= next_swap then
            player:swap_next()
            state = 'preload'
            recalc_next_switch()
        end
        player:draw(...)
    end

    local function size()
        if total_duration == 0 then
            return 0, 0
        else
            return player:size()
        end
    end

    return {
        update = update;
        draw = draw;
        size = size;
    }
end

local overlay = Playlist()

local function draw_progress(x1, y1, x2, y2, player_state)
    if not progress_style then
        return
    end
    local w, h = x2 - x1, y2 - y1
    local progress = player_state.progress
    if progress_style == "bar_thin_white" then
        white:draw(x1, y2-10, x1+w*progress, y2, 0.5)
    elseif progress_style  == "bar_thick_white" then
        white:draw(x1, y2-20, x1+w*progress, y2, 0.5)
    elseif progress_style  == "bar_thin_black" then
        black:draw(x1, y2-10, x1+w*progress, y2, 0.5)
    elseif progress_style  == "bar_thick_black" then
        black:draw(x1, y2-20, x1+w*progress, y2, 0.5)
    elseif progress_style  == "circle" then
        progress_shader:use{
            progress_angle = math.pi - progress * math.pi * 2
        }
        white:draw(x2-40, y2-40, x2-10, y2-10)
        progress_shader:deactivate()
    end
end

local function reserved_to_pixel(total, reserved)
    if reserved >= 0 and reserved < 1 then
        return total * reserved
    elseif reserved >= 1 then
        return reserved
    else
        return 0
    end
end

function M.content_placement(x1, y1, x2, y2, player_state)
    -- place content on all available area
    local c_x1 = x1
    local c_y1 = y1
    local c_x2 = x2 - reserved_to_pixel(x2-x1, reserve_right)
    local c_y2 = y2 - reserved_to_pixel(y2-y1, reserve_bottom)
    local do_ken_burns = 
        (player_state.type == "image" and ken_burns == "images") or 
        ken_burns == "all"
    if do_ken_burns then
        local progress = player_state.progress
        local function lerp(s, e, t)
            return s + t * (e-s)
        end
        local w = c_x2 - c_x1
        local h = c_y2 - c_y1
        local paths = {
            {from = {x=0.0,  y=0.0,  s=1.0 }, to = {x=0.08, y=0.08, s=0.9 }},
            {from = {x=0.05, y=0.0,  s=0.93}, to = {x=0.03, y=0.03, s=0.97}},
            {from = {x=0.02, y=0.05, s=0.91}, to = {x=0.01, y=0.05, s=0.95}},
            {from = {x=0.07, y=0.05, s=0.91}, to = {x=0.04, y=0.03, s=0.95}},
        }
        local path = paths[player_state.rnd % #paths + 1]
        local from, to = path.from, path.to
        if player_state.rnd % 10 < 5 then
            to, from = from, to
        end
        local transform = matrix.trans(c_x1, c_y1) *
                          matrix.scale(
                              1/lerp(from.s, to.s, progress),
                              1/lerp(from.s, to.s, progress)
                          ) *
                          matrix.trans(
                              -lerp(w*from.x, w*to.x, progress),
                              -lerp(h*from.y, h*to.y, progress)
                          )

        local k_x1, k_y1 = transform(0, 0)
        local k_x2, k_y2 = transform(w, h)
        return k_x1, k_y1, k_x2, k_y2
    else
        return c_x1, c_y1, c_x2, c_y2
    end
end

function M.draw(x1, y1, x2, y2, player_state)
    if placement == "auto" then
        if reserve_bottom > 0 and reserve_right == 0 then
            overlay.draw(x1, y2 - reserved_to_pixel(y2-y1, reserve_bottom), x2, y2)
        elseif reserve_right > 0 and reserve_bottom == 0 then
            overlay.draw(x2 - reserved_to_pixel(x2-x1, reserve_right), y1, x2, y2)
        else
            overlay.draw(x1, y1, x2, y2)
        end
    else
        local w, h = overlay.size()
        if placement == "br_margin20" then
            overlay.draw(x2-20-w, y2-20-h, x2-20, y2-20)
        elseif placement == "tr_margin20" then
            overlay.draw(x2-20-w, y1+20, x2-20, y1+20+h)
        end
    end
    draw_progress(x1, y1, x2, y2, player_state)
end

function M.load()
    print("overlay load")
end

function M.updated_config_json(config)
    reserve_bottom = config.reserve_bottom
    reserve_right = config.reserve_right
    ken_burns = config.ken_burns
    progress_style = config.progress_style
    placement = config.placement
    overlay.update(config.overlays)
end

function M.unload()
    print("overlay unload")
end

return M
