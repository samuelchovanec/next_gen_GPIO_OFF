gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
util.no_globals()

local MAX_CONFIG_STATES = 5

local matrix = require "matrix2d"
local rpc = require "rpc"
local md5 = require "md5"
local json = require "json"
local loader = require "loader"
local font = resource.load_font "font.ttf"
local black = resource.create_colored_texture(0, 0, 0, 1)

local py = rpc.create()

local wall_state = {wall_time={}, os={}, playback={}}
local show_state_end = 0
local alternative_idx = 'default'
local scaling = 'keep_aspect'
local pos_x1 = 0
local pos_y1 = 0
local pos_x2 = 100
local pos_y2 = 100
local audio = true
local pop = false
local fuse = false
local use_overlay = true
local overlay_name

local function log(fmt, ...)
    print(string.format("[player] "..fmt, ...))
end

local function scale_into(target_w, target_h, w, h, max_stretch)
    local scale_x = target_w / w
    local scale_y = target_h / h
    local max_scale = math.min(scale_x, scale_y)
    if scale_x == max_scale then
        scale_y = math.min(scale_y, max_scale * max_stretch)
    else
        scale_x = math.min(scale_x, max_scale * max_stretch)
    end
    local transform = matrix.trans(target_w/2, target_h/2) *
                      matrix.scale(scale_x, scale_y) *
                      matrix.trans(-w/2, -h/2)
    local x1, y1 = transform(0, 0)
    local x2, y2 = transform(w, h)
    return x1, y1, x2, y2
end

-- Utils -----------------------------------------------------

local function SharedTime()
    local local_diff = 0
    local target_diff = 0
    local jumped = false
    local local_time = 0

    local function update(shared_time, os_sent_time)
        -- compensate delay caused by info-beamer only handling
        -- TCP events every frame. The packet includes the timestamp
        -- of when the packet was sent, so we can calculate and
        -- compensate the delay.
        local send_delay = os.time() - os_sent_time
        target_diff = shared_time + send_delay - sys.now()
    end

    local function tick()
        if math.abs(target_diff - local_diff) > 0.3 then
            print('time jump')
            jumped = true
            local_diff = target_diff
        else
            jumped = false
        end
        local_diff = local_diff * 0.95 + target_diff * 0.05
        local_time = local_diff + sys.now()
        wall_state.wall_time.time = local_time
        wall_state.wall_time.diff = string.format("%.5f", target_diff - local_diff)
    end

    local function get()
        return local_time, jumped
    end

    return {
        update = update;
        tick = tick;
        get = get;
    }
end

local SharedTime = SharedTime()

-- Presentation ----------------------------------------------

local function Display()
    local rotation = 0
    local is_portrait = false
    local transform

    local w, h = NATIVE_WIDTH, NATIVE_HEIGHT

    local function round(v)
        return math.floor(v+.5)
    end

    local function update_placement(new_rotation)
        rotation = new_rotation

        is_portrait = rotation == 90 or rotation == 270

        gl.setup(w, h)

        if rotation == 0 then
            transform = matrix.ident()
        elseif rotation == 90 then
            transform = matrix.trans(w, 0) *
                        matrix.rotate_deg(rotation)
        elseif rotation == 180 then
            transform = matrix.trans(w, h) *
                        matrix.rotate_deg(rotation)
        elseif rotation == 270 then
            transform = matrix.trans(0, h) *
                        matrix.rotate_deg(rotation)
        else
            return error(string.format("cannot rotate by %d degree", rotation))
        end
    end

    local function draw_video(vid, x1, y1, x2, y2)
        local tx1, ty1 = transform(x1, y1)
        local tx2, ty2 = transform(x2, y2)
        local x1, y1, x2, y2 = round(math.min(tx1, tx2)),
                               round(math.min(ty1, ty2)),
                               round(math.max(tx1, tx2)),
                               round(math.max(ty1, ty2))
        return vid:place(x1, y1, x2, y2, rotation)
    end

    local function draw_image(img, x1, y1, x2, y2)
        return img:draw(x1, y1, x2, y2)
    end

    local function frame_setup()
        return matrix.apply_gl(transform)
    end

    local function size()
        if is_portrait then
            return h, w
        else
            return w, h
        end
    end

    local function place(x1, y1, x2, y2)
        local w, h = size()
        return w * x1 / 100, h * y1 / 100, w * x2 / 100, h * y2 / 100
    end

    update_placement(0)

    return {
        update_placement = update_placement;
        frame_setup = frame_setup;
        draw_image = draw_image;
        draw_video = draw_video;
        is_portrait = function() return is_portrait end;
        size = size;
        place = place;
    }
end
local Display = Display()

-- Debugging ----------------------------------------------------

local BAR = 'IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII........................................'

util.data_mapper{
    ["debug/update"] = function(raw)
        for k, v in pairs(json.decode(raw)) do
            wall_state[k] = v
        end
    end;

    ["debug/show"] = function(duration)
        show_state_end = sys.now() + tonumber(duration)
    end;

    ["trigger"] = function(trigger_cmd)
        py.trigger(trigger_cmd)
    end;

    ["sys/syncer/progress"] = function(progress)
        wall_state.os.updating = true
        progress = math.min(1, tonumber(progress))
        local bar_progress = math.max(1, 40-math.floor(progress*40))
        wall_state.os.update_progress = string.format(
            '[%s] %.2f%%', BAR:sub(bar_progress, bar_progress+39), progress*100
        )
    end;

    ["sys/syncer/updating"] = function(active)
        wall_state.os.updating = active == "1"
        wall_state.os.update_progress = ''
    end;

    ["sys/syncer/status"] = function(new_status)
        wall_state.os.status = new_status
    end;
}

local function render_state()
    local x, y = 10, 10
    local function write(xx, text, r,g,b,a, size)
        size = size or 20
        font:write(x+xx, y, text, size, r,g,b,a)
        y = y + size + 3
        if y > HEIGHT - 30 then
            x = x + 600
            y = 10
        end
    end
    local function write_obj(depth, obj)
        local keys = {}
        for k, v in pairs(obj) do
            keys[#keys+1] = k
        end
        table.sort(keys)
        for idx, k in ipairs(keys) do
            local v = obj[k]
            if type(v) == "table" then
                if next(v) then
                    y = y + 3
                    write(depth*30, k, 1,1,1,1)
                    write_obj(depth+1, v)
                    y = y + 3
                end
            else
                write(depth*30, string.format("%s    %s", k, v), 1,0.5,0.5,1)
            end
        end
    end
    write(0, "[DEBUG]", 1,1,1,1, 40)
    write(0, "", 0,0,0,0)
    if wall_state.peer.is_leader then
        local num_peers = wall_state.peers and #wall_state.peers or 0
        write(0, string.format("Leader device %d controlling group of %d devices", wall_state.config.device_id, num_peers), 1,1,1,1)
    else
        local leader_id = wall_state.leader and wall_state.leader.device_id or '<unknown>'
        write(0, string.format("Follower device %d, controlled by %s", wall_state.config.device_id, leader_id), 1,1,1,1)
    end
    write(0, "", 0,0,0,0)
    write_obj(0, wall_state)
end

-- Fallback wrapper ----------------------------------------------

local function mk_fallback()
    return setmetatable({
        asset = nil,
        asset_name = nil,

        update = function(self, new_asset_name)
            if self.asset and new_asset_name == self.asset_name then
                return
            end
            if self.asset then
                self.asset:dispose()
            end
            self.asset_name = new_asset_name
            self.asset = resource.load_image{
                file = new_asset_name,
            }
        end;

        draw = function(self, ...)
            return self.asset:draw(...)
        end;

        state = function(self, ...)
            return self.asset:state(...)
        end;

        dispose = function(self)
            -- nop
        end;
    }, {
        __typename = "image"
    })
end

local function ResourceLoader(child)
    return function()
        local obj = {
            res = nil,
            asset_name = nil,
        }
        function obj:update(config_resource, load_args)
            local asset_name = config_resource.asset_name
            if asset_name ~= self.asset_name then
                print('loading asset ' .. asset_name)
                if self.next_res then
                    self.next_res:dispose()
                    self.next_res = nil
                end
                load_args = load_args or {}
                load_args.file = child .. "/" .. asset_name
                local asset_type = config_resource.type
                if asset_type == "video" then
                    load_args.raw = true
                    self.next_res = resource.load_video(load_args)
                elseif asset_type == "image" then
                    load_args.fastload = true
                    self.next_res = resource.load_image(load_args)
                else
                    error("invalid asset type")
                end
                self.asset_name = asset_name
            end
        end
        function obj:is_loading()
            return self.next_res and self.next_res:state() == "loading"
        end
        function obj:draw(...)
            if not self.res then
                return
            end
            if type(self.res) == "image" then
                return Display.draw_image(self.res, ...)
            else
                return Display.draw_video(self.res, ...)
            end
        end
        function obj:size()
            if not self.res then
                return 0, 0
            end
            return self.res:size()
        end
        function obj:swap_next()
            if self.next_res then
                if self.res then
                    self.res:dispose()
                end
                self.res = self.next_res
                self.next_res = nil
            end
        end
        return obj
    end
end

-- Child nodes -------------------------------------------------------

local ChildLoader = loader.setup "ng-content.lua"

function ChildLoader.before_load(child, api)
    api.time = SharedTime.get
    api.size = Display.size
    api.draw_image = Display.draw_image
    api.draw_video = Display.draw_video
    api.create_resource = ResourceLoader(child)
end

local OverlayLoader = loader.setup "ng-overlay.lua"

function OverlayLoader.before_load(child, api)
    api.time = SharedTime.get
    api.size = Display.size
    api.draw_image = Display.draw_image
    api.draw_video = Display.draw_video
    api.create_resource = ResourceLoader(child)
end

local function Overlay()
    local name, overlay

    local function call_if_defined(fn, ...)
        if overlay and overlay[fn] then
            return overlay[fn](...)
        end
    end

    local function swap(next_name)
        local updated = next_name ~= name
        if updated then
            call_if_defined('stop')
            name = next_name
        end
        overlay = OverlayLoader.modules[name]
        if updated then
            call_if_defined('start')
        end
    end

    return setmetatable({
        _swap = swap,
        _call_if_defined = call_if_defined,
    }, {
        __index = function(t, key)
            return overlay[key]
        end
    })
end

local overlay = Overlay()

-- Config loading ----------------------------------------------------

local playlist_by_state = {}
local states = {} -- loaded revs in oldest->newest order

local FallbackH = mk_fallback()
local FallbackV = mk_fallback()

local function add_state_playlist(config_state, playlist)
    for idx, existing_state in ipairs(states) do
        if existing_state == config_state then
            table.remove(states, idx)
            playlist_by_state[existing_state] = nil
            break
        end
    end
    if #states >= MAX_CONFIG_STATES then
        local removed_state = table.remove(states, 1)
        playlist_by_state[removed_state] = nil
    end
    states[#states+1] = config_state
    playlist_by_state[config_state] = playlist
    wall_state.playable_states = states
end

local function playlist_item(config_state, item_idx, cnt)
    local playlist = playlist_by_state[config_state]
    if not playlist then
        return nil
    end
    local alternatives = playlist[item_idx]
    local alt_group = alternatives[alternative_idx]
    local item = alt_group[cnt % #alt_group + 1]
    if item then
        return item
    end
    return alternatives.default[1]
end

util.json_watch("config.json", function(config)
    wall_state.config = {
        setup_id = config.__metadata.setup_id,
        device_id = config.__metadata.device_id,
    }

    FallbackH:update(config.fallback_h.asset_name)
    FallbackV:update(config.fallback_v.asset_name)

    local device_data = config.__metadata.device_data

    alternative_idx = device_data.alternative_idx or 'default'
    pos_x1 = device_data.x1 or 0
    pos_y1 = device_data.y1 or 0
    pos_x2 = device_data.x2 or 100
    pos_y2 = device_data.y2 or 100
    scaling = config.scaling
    audio = config.audio
    pop = config.pop
    fuse = config.fuse
    overlay_name = config.overlay.asset_name
    use_overlay = device_data.overlay ~= false

    local rotation = device_data.rotation or 0
    Display.update_placement(rotation, 0, 1)

    wall_state.screen = {
        alternative_idx = alternative_idx,
        rotation = rotation,
        pos = {
            x1 = pos_x1,
            y1 = pos_y1,
            x2 = pos_x2,
            y2 = pos_y2,
        },
    }

    local config_hash = md5.new()
    config_hash:update(tostring(config.__metadata.config_rev))

    local playlist = {}
    for _, item in ipairs(config.playlist) do
        config_hash:update(item.asset.asset_name)
        local alternatives = {
            default = {{
                file = resource.open_file(item.asset.asset_name),
                type = item.asset.type,
                asset_id = item.asset.asset_id,
                asset_filename = item.asset.filename,
            }},
            [1]={}, [2]={}, [3]={}, [4]={},
            [5]={}, [6]={}, [7]={}, [8]={},
        }
        for _, alt_item in ipairs(item.alternatives) do
            table.insert(alternatives[alt_item.alternative_idx], {
                file = resource.open_file(alt_item.asset.asset_name),
                type = alt_item.asset.type,
                asset_id = alt_item.asset.asset_id,
                asset_filename = alt_item.asset.filename,
            })
        end
        playlist[#playlist+1] = alternatives
    end

    local config_state = md5.tohex(config_hash:finish()):sub(1, 16)
    add_state_playlist(config_state, playlist)

    log('config state: %s', config_state)
    pp(playlist)

    node.gc()
end)

local function submit_pop(item, duration)
    py.submit_pop({
        play_start = os.time(),
        duration = duration,
        asset_id = item.asset_id,
        asset_filename = item.asset_filename,
    })
end

-- Players ------------------------------------------------------

local function Fallback()
    local function preload()
    end

    local function size()
        local res = Display.is_portrait() and FallbackV or FallbackH
        local state, w, h = res:state()
        if state == "loading" then
            return nil, nil
        else
            return w, h
        end
    end

    local function draw(x1, y1, x2, y2)
        local res = Display.is_portrait() and FallbackV or FallbackH
        Display.draw_image(res, x1, y1, x2, y2)
    end

    local function dispose()
    end

    return {
        preload = preload,
        size = size,
        draw = draw,
        dispose = dispose,
    }
end

local function Child(filename)
    local module = ChildLoader.modules[filename]
    local instance
    
    local function preload(cnt, rnd)
        if module and module.preload then
            instance = module.preload(cnt, rnd)
        end
    end

    local function size()
        if instance and instance.size then
            local w, h = Display.size()
            return instance:size(w, h)
        end
    end

    local function draw(...)
        if instance and instance.draw then
            return instance:draw(...)
        end
    end

    local function hide()
        if instance and instance.hide then
            return instance:hide()
        end
    end

    local function dispose()
        if instance and instance.dispose then
            instance:dispose()
            instance = nil
        end
    end

    return {
        preload = preload,
        size = size,
        draw = draw,
        hide = hide,
        dispose = dispose,
    }
end

local function Video(file)
    local res

    local function preload()
        res = resource.load_video{
            file = file:copy(),
            raw = true,
            paused = true,
            looped = true,
            audio = audio,
        }
    end

    local function size()
        local state, w, h = res:state()
        if state == "loading" then
            return nil, nil
        else
            return w, h
        end
    end

    local function draw(x1, y1, x2, y2)
        res:start()
        Display.draw_video(res, x1, y1, x2, y2):layer(-1)
    end

    local function hide()
        res:layer(-2)
    end

    local function dispose()
        res:dispose()
    end

    return {
        preload = preload,
        size = size,
        draw = draw,
        hide = hide,
        dispose = dispose,
    }
end

local function Image(file)
    local res

    local function preload()
        res = resource.load_image{
            file = file:copy(),
            fastload = true,
        }
    end

    local function size()
        local state, w, h = res:state()
        if state == "loading" then
            return nil, nil
        else
            return w, h
        end
    end

    local function draw(x1, y1, x2, y2)
        Display.draw_image(res, x1, y1, x2, y2)
    end

    local function dispose()
        res:dispose()
    end

    return {
        preload = preload,
        size = size,
        draw = draw,
        dispose = dispose,
    }
end

local old, cur, nxt
local fallback_name = newproxy()

local function new_fallback_player()
    return {
        player = Fallback(),
        duration = 1,
        asset_name = fallback_name,
        idx = -1,
        started = sys.now(),
        forced_end = sys.now() + 1,
        cnt = 0,
        rnd = 0,
    }
end

cur = new_fallback_player()

-- Service Control ----------------------------------------------------

py.register("time", SharedTime.update)

py.register("preload", function(opt)
    pp(opt)
    if nxt then
        nxt.player.dispose()
        nxt = nil
    end

    local item = playlist_item(opt.config_state, opt.item_idx, opt.cnt)

    if not item then
        nxt = {
            player = Fallback(),
            duration = opt.duration,
            asset_name = fallback_name,
            idx = opt.item_idx,
            type = "image",
        }
    elseif item.type == "child" then
        nxt = {
            player = Child(item.asset_filename),
            duration = opt.duration,
            asset_name = item.asset_filename,
            idx = opt.item_idx,
            item = item,
            type = "child",
        }
    elseif item.type == "image" then
        nxt = {
            player = Image(item.file),
            duration = opt.duration,
            asset_name = item.asset_filename,
            idx = opt.item_idx,
            item = item,
            type = "image",
        }
    else
        nxt = {
            player = Video(item.file),
            duration = opt.duration,
            asset_name = item.asset_filename,
            idx = opt.item_idx,
            item = item,
            type = "video",
        }
    end
    nxt.cnt = opt.cnt
    nxt.rnd = opt.rnd
    nxt.player.preload(opt.cnt, opt.rnd)
end)

py.register("switch", function()
    if not nxt then
        return
    end
    if pop and nxt.item then
        submit_pop(nxt.item, nxt.duration)
    end
    if old then
        old.player.dispose()
    end
    if (
        fuse and 
        cur.asset_name == nxt.asset_name and -- same asset
        nxt.idx > cur.idx -- later within the loop (aka don't fuse across playlist wraparound)
    ) then
        nxt.player = cur.player
    else
        old = cur
    end

    cur = nxt
    cur.started = sys.now()
    cur.forced_end = sys.now() + cur.duration + 1
    nxt = nil
end)

-- Rendering ----------------------------------------------------

function node.render()
    overlay._swap(overlay_name)
    Display.frame_setup()
    gl.clear(0,0,0,0)
    SharedTime.tick()

    if sys.now() >= cur.forced_end then
        cur.player.dispose()
        cur = new_fallback_player()
    end

    if cur then
        if old and old.player.hide then
            old.player.hide()
        end

        local player_state = {
            duration = cur.duration,
            progress = math.min(1.0, 1.0 / cur.duration * (sys.now() - cur.started)),
            cnt = cur.cnt,
            rnd = cur.rnd,
            type = cur.type,
        }

        wall_state.playback.asset = cur.asset_name
        wall_state.playback.pos = string.format("%.2fs / %.2fs", sys.now() - cur.started, cur.duration)
        wall_state.playback.progress = string.format("%.2f%%", 100 / cur.duration * (sys.now() - cur.started))

        -- Get available display space
        local d_x1, d_y1, d_x2, d_y2 = Display.place(
            pos_x1, pos_y1, pos_x2, pos_y2
        )

        -- Calculate available content space from available
        -- display space. Ask overlay if enabled.
        local c_x1, c_y1, c_x2, c_y2
        if use_overlay then
            c_x1, c_y1, c_x2, c_y2 = overlay.content_placement(
                d_x1, d_y1, d_x2, d_y2, player_state
            )
        else
            c_x1, c_y1, c_x2, c_y2 = d_x1, d_y1, d_x2, d_y2
        end

        local w, h = cur.player.size()
        if w and h then
            local max_scale
            if scaling == 'keep_aspect' then
                max_scale = 1
            elseif scaling == 'keep_5' then
                max_scale = 1.05
            elseif scaling == 'keep_10' then
                max_scale = 1.1
            elseif scaling == 'keep_15' then
                max_scale = 1.15
            elseif scaling == 'keep_20' then
                max_scale = 1.2
            end
            if max_scale then
                local x, y = c_x1, c_y1
                local off_x1, off_y1, off_x2, off_y2 = scale_into(
                    c_x2-c_x1, c_y2-c_y1, w, h, max_scale
                )
                c_x1 = x + off_x1
                c_y1 = y + off_y1
                c_x2 = x + off_x2
                c_y2 = y + off_y2
            end
        end

        if use_overlay then
            if overlay.wrap_content_draw then
                overlay.wrap_content_draw(
                    cur.player.draw, c_x1, c_y1, c_x2, c_y2, player_state
                )
            else
                cur.player.draw(c_x1, c_y1, c_x2, c_y2)
            end
            overlay.draw(d_x1, d_y1, d_x2, d_y2, player_state)
        else
            cur.player.draw(c_x1, c_y1, c_x2, c_y2)
        end
                
        if old then
            old.player.dispose()
            old = nil
        end
    end

    gl.ortho()
    if sys.now() < show_state_end then
        black:draw(0, 0, WIDTH, HEIGHT, 0.6)

        local time = SharedTime.get()
        local x = (time * 800) % WIDTH
        local y = (time * 800) % HEIGHT 
        black:draw(0, y-10, WIDTH, y+10)
        black:draw(x-10, 0, x+10, HEIGHT)

        render_state()
    end

    node.gc()
end
