local api = ...

local M = {}

local function instance(rnd)
    local c = resource.create_colored_texture(
        rnd % 100 / 255,
        rnd % 25 / 25,
        rnd % 13 / 13,
        1
    )

    local function size(self, w, h)
        return w, h
    end

    local function draw(self, x1, y1, x2, y2)
        api.draw_image(c, x1, y1, x2, y2)
    end

    local function dispose()
        c:dispose()
        print("DISPOSE")
    end

    return {
        size = size,
        draw = draw,
        dispose = dispose,
    }
end

function M.preload(cnt, rnd)
    print("PRELOAD! ", cnt, rnd)
    return instance(rnd)
end

return M


