local win = am.window{
    title = "Aether Explorer",
    width = 800,
    height = 450,
    resizable = true,
    depth_buffer = true,
}

local camera

local spaceship
local spaceship_rotation
local spaceship_velocity = vec3(0, 0, 0)
local particle

local function is_raining()
    return math.perlin(am.frame_time / 200) > 0.3
end

local shader

local main_action

local raindrop

local function init_shader()
    local vshader = [[
        precision highp float;
        uniform mat4 MV;
        uniform mat4 P;
        uniform vec3 sky;
        attribute vec3 pos;
        attribute vec3 color;
        varying vec3 v_pos;
        varying vec3 v_color;
        varying vec3 v_sky;
        void main() {
            gl_Position = P * MV * vec4(pos, 1);
            v_color = mix(color * sky, + color, 0.2);
            v_pos = gl_Position.xyz;
            v_sky = sky;
        }
    ]]
    local fshader = [[
        precision mediump float;
        uniform sampler2D tex;
        varying vec3 v_color;
        varying vec3 v_pos;
        varying vec3 v_sky;
        void main() {
            float d = v_pos.x * v_pos.x + v_pos.y * v_pos.y + v_pos.z * v_pos.z;
            float mixAmount = min(max((d - 2000.0) / 500.0, 0.0), 1.0);
            gl_FragColor = vec4(mix(v_color, v_sky, mixAmount), 1.0);
        }
    ]]
    shader = am.program(vshader, fshader)
end

local loaded_chunks = {}
local chunk_queue = {}

local function depth_noise(x, y)
    local coarse = (math.simplex(vec2(x / 32, y / 32)) - 0.25) * 15
    if coarse < 0 then
        return 0
    end
    local fine = math.abs(math.simplex(vec2(x / 10, y / 10)) - 0.125) * 6
    return fine + coarse
end

local function mountain_noise(x, y)
    return (math.perlin(vec2(x / 15, y / 15)) + 1) * 4.5
end

local function height_noise(x, y)
    return math.simplex(vec2((x - 4) / 100, (y - 4) / 100)) * 10.0
end

local function random_color(r, g, b, x, y)
    local rng = am.rand(((x % 50) * 123) + (y % 50))
    r = math.max(math.min(r + rng(-20, 20), 255), 0) / 255
    g = math.max(math.min(g + rng(-20, 20), 255), 0) / 255
    b = math.max(math.min(b + rng(-20, 20), 255), 0) / 255
    return vec3(r, g, b)
end

local function add_top_bottom_quad(q, a, b)
    q[#q+1] = a
    q[#q+1] = b
    q[#q+1] = b + 1
    q[#q+1] = a
    q[#q+1] = b + 1
    q[#q+1] = a + 1
end

local function add_triangle(q, a, b, c)
    q[#q+1] = a
    q[#q+1] = b
    q[#q+1] = c
    q[#q+1] = c + 1
    q[#q+1] = b + 1
    q[#q+1] = a + 1
end

local function get_height(x, y)
    local depth = depth_noise(x, y)
    if depth > 0 then
        local mountain = mountain_noise(x, y)
        local height = height_noise(x, y)
        local clamp = math.min(depth, 10) / 10
        return height + mountain * clamp, height - depth
    end
end

local tree_vertices = {
    vec3(0.0, 0.0, 0.5),
    vec3(-0.43,0.0,  -0.25),
    vec3(0.43, 0.0, -0.25),
    vec3(0.0, 1.0, 0.5),
    vec3(-0.43,1.0,  -0.25),
    vec3(0.43, 1.0, -0.25),
    vec3(0.0, 1.30, 1.34),
    vec3(-1.30,1.30,  -0.90),
    vec3(1.30, 1.30, -0.90),
    vec3(0.0, 4.0, 0.0),
}

local tree_color = {
    {70, 50, 25},
    {70, 50, 25},
    {70, 50, 25},
    {10, 60, 5},
    {15, 80, 7},
    {10, 60, 5},
    {15, 80, 7},
    {10, 60, 5},
    {15, 80, 7},
    {15, 80, 7},
}

local tree_indices = {
    2, 3, 0,
    1, 5, 2,
    0, 4, 1,
    5, 6, 3,
    4, 8, 5,
    4, 6, 7,
    6, 8, 9,
    8, 7, 9,
    7, 6, 9,
    2, 5, 3,
    1, 4, 5,
    0, 3, 4,
    5, 8, 6,
    4, 7, 8,
    4, 3, 6,
}

local function add_tree(v, c, q, x, y, r)
    local height = get_height(x, y)
    local scale = (r() + 0.5) * 0.65
    local offset = #v + 1
    for i = 1, #tree_vertices do
        v[#v+1] = tree_vertices[i] * scale + vec3(x, height, y)
        c[#c+1] = random_color(tree_color[i][1], tree_color[i][2], tree_color[i][3], x + i, y - i)
    end
    for i = 1, #tree_indices do
        q[#q+1] = offset + tree_indices[i]
    end
end

local function generate_chunk(x1, y1)
    local v = {}
    local c = {}
    local point_by_pos = {}
    x1 = x1 * 16
    y1 = y1 * 16
    for y = y1 - 8, y1 + 8 do
        for x = x1 - 8, x1 + 8 do
            local top, bottom = get_height(x, y)
            if bottom ~= nil then
                local key = x .. ',' .. y
                point_by_pos[key] = #v + 1
                v[#v+1] = vec3(x, bottom, y)
                c[#c+1] = random_color(70, 50, 25, x, y)
                v[#v+1] = vec3(x, top, y)
                c[#c+1] = random_color(20, 120, 10, x, y)
            end
        end
    end
    local q = {}
    for y = y1 - 8, y1 + 7 do
        for x = x1 - 8, x1 + 7 do
            local l = {
                point_by_pos[(x) .. ',' .. (y)],
                point_by_pos[(x+1) .. ',' .. (y)],
                point_by_pos[(x+1) .. ',' .. (y+1)],
                point_by_pos[(x) .. ',' .. (y+1)],
            }
            local count = 0
            for i = 1, 4 do
                if l[i] ~= nil then
                    count = count + 1
                end
            end
            if count == 2 then
                for i = 1, 4 do
                    local p1 = l[i]
                    local p2 = l[(((i - 1) + 1) % 4) + 1]
                    if p1 ~= nil and p2 ~= nil then
                        add_top_bottom_quad(q, p1, p2)
                        break
                    end
                end
            elseif count == 3 then
                for i = 1, 4 do
                    local p1 = l[i]
                    local p2 = l[(((i - 1) + 1) % 4) + 1]
                    local p3 = l[(((i - 1) + 2) % 4) + 1]
                    if p1 ~= nil and p2 ~= nil and p3 ~= nil then
                        add_top_bottom_quad(q, p1, p3)
                        add_triangle(q, p1, p2, p3)
                        break
                    end
                end
            elseif count == 4 then
                -- don't triangulate same way for every tile, looks too boring
                if ((x * 7) + (y * 5)) % 2 == 1 then
                    add_triangle(q, l[1], l[2], l[3])
                    add_triangle(q, l[1], l[3], l[4])
                else
                    add_triangle(q, l[2], l[3], l[4])
                    add_triangle(q, l[1], l[2], l[4])
                end

                -- maybe add a tree?
                local rng = am.rand(((x * 13) + (y * 6)) % 1201)
                if rng() > 0.95 then
                    add_tree(v, c, q, x, y, rng)
                end
            end
        end
    end

    if #q == 0 then
        return am.group()
    else
        local vbuf = am.vec3_array(v)
        local qbuf = am.ushort_elem_array(q)
        local cbuf = am.vec3_array(c)
        return am.bind { pos = vbuf, color = cbuf } ^ am.draw("triangles", qbuf)
    end
end

local inital_load = true

local function load_terrain(chunk_group)
    local x = math.floor(camera.eye.x / 16)
    local y = math.floor(camera.eye.z / 16)
    local chunks_to_add = {}
    for px = -5, 5 do
        for py = -5, 5 do
            chunks_to_add[(x+px)..','..(y+py)] = {x = x + px, y = y + py}
        end
    end
    local chunks_to_remove = {}
    for k, _ in pairs(loaded_chunks) do
        if chunks_to_add[k] ~= nil then
            chunks_to_add[k] = nil
        else
            chunks_to_remove[#chunks_to_remove+1] = k
        end
    end
    for i = 1, #chunks_to_remove do
        local k = chunks_to_remove[i]
        chunk_group:remove(k)
        loaded_chunks[k] = nil
    end
    for k, v in pairs(chunks_to_add) do
        chunks_to_remove[#chunks_to_remove+1] = k
        if inital_load then
            local node = generate_chunk(v.x, v.y):tag(k)
            chunk_group:append(node)
        else
            chunk_queue[#chunk_queue+1] = {k, v}
        end
        loaded_chunks[k] = true
    end
    if #chunk_queue > 0 then
        local k = chunk_queue[1][1]
        local v = chunk_queue[1][2]
        if loaded_chunks[k] then
            local node = generate_chunk(v.x, v.y):tag(k)
            chunk_group:append(node)
        end
        table.remove(chunk_queue, 1)
    end
    inital_load = false
    return false
end

local function create_spaceship()
    local y = get_height(5, 5)
    local translate = am.translate(vec3(5, y, 5))
    local rotate = am.rotate(math.pi, vec3(0, 1, 0))
    local draw = am.bind {
        color = am.vec3_array{
            vec3(0, 0.2, 0.5), vec3(0, 0.2, 0.5), vec3(0, 0.2, 0.5), vec3(0, 0.4, 1),
        },
        pos = am.vec3_array{
            vec3(0, 0.1, 0.5),
            vec3(-0.25, 0.1, -0.5),
            vec3(0.25, 0.1, -0.5),
            vec3(0, 0.35, -0.5),
        },
    } ^ am.draw("triangles", am.ushort_elem_array {
        1, 2, 3,
        2, 1, 4,
        3, 2, 4,
        1, 3, 4,
    })
    rotate:append(draw)
    translate:append(rotate)

    spaceship = translate
    spaceship_rotation = rotate
end

local function create_particle()
    local draw = am.bind {
        color = am.vec3_array {
            vec3(1, 0.6, 0), vec3(1, 1, 0), vec3(1, 0.8, 0), vec3(0.8, 0.4, 0),
        },
        pos = am.vec3_array {
            vec3(-0.047, -0.033, 0.082),
            vec3(-0.047, -0.033, -0.082),
            vec3(0.094, -0.033, 0),
            vec3(0, 0.1, 0),
        },
    } ^ am.draw("triangles", am.ushort_elem_array {
        1, 2, 3,
        2, 1, 4,
        3, 2, 4,
        1, 3, 4,
    })

    particle = draw
end

local function create_raindrop()
    local draw = am.bind {
        color = am.vec3_array {
            vec3(1, 1, 1), vec3(1, 1, 1),
        },
        pos = am.vec3_array {
            vec3(0, 4, 0),
            vec3(0, -4, 0),
        },
    } ^ am.draw("lines")

    raindrop = draw
end

local function create_title()
    local white = {}
    for i = 1, 80 do
        white[i] = vec3(1,1,1)
    end
    return am.bind {
        color = am.vec3_array (white),
        pos = am.vec3_array {vec3(0.0,7.5,-6),vec3(-2.0,8.5,-6),vec3(0.0,8.5,-6),vec3(-1.0,9.5,-6),vec3(-2.0,7.5,-6),vec3(-2.0,6.5,-6),vec3(0.0,6.5,-6),vec3(1.0,7.5,-6),vec3(1.0,9.5,-6),vec3(3.0,9.5,-6),vec3(1.0,6.5,-6),vec3(3.0,6.5,-6),vec3(3.0,7.5,-6),vec3(4.0,9.5,-6),vec3(5.0,9.5,-6),vec3(5.0,6.5,-6),vec3(6.0,9.5,-6),vec3(7.0,9.5,-6),vec3(7.0,7.5,-6),vec3(9.0,7.5,-6),vec3(9.0,9.5,-6),vec3(9.0,6.5,-6),vec3(7.0,6.5,-6),vec3(10.0,7.5,-6),vec3(10.0,9.5,-6),vec3(12.0,9.5,-6),vec3(10.0,6.5,-6),vec3(12.0,6.5,-6),vec3(12.0,7.5,-6),vec3(13.0,9.5,-6),vec3(13.0,7.5,-6),vec3(14.0,7.5,-6),vec3(15.0,6.5,-6),vec3(13.0,6.5,-6),vec3(15.0,8.5,-6),vec3(14.0,9.5,-6),vec3(-5.0,3.5,-6),vec3(-5.0,5.5,-6),vec3(-3.0,5.5,-6),vec3(-5.0,2.5,-6),vec3(-3.0,2.5,-6),vec3(-3.0,3.5,-6),vec3(-2.0,5.5,-6),vec3(-1.0,4.0,-6),vec3(-2.0,2.5,-6),vec3(0.0,2.5,-6),vec3(0.0,5.5,-6),vec3(1.0,5.5,-6),vec3(1.0,3.5,-6),vec3(2.0,3.5,-6),vec3(4.0,5.5,-6),vec3(1.0,2.5,-6),vec3(3.0,4.5,-6),vec3(2.0,5.5,-6),vec3(4.0,2.5,-6),vec3(6.0,2.5,-6),vec3(7.0,2.5,-6),vec3(7.0,5.5,-6),vec3(9.0,5.5,-6),vec3(9.0,2.5,-6),vec3(10.0,5.5,-6),vec3(10.0,3.5,-6),vec3(11.0,3.5,-6),vec3(12.0,2.5,-6),vec3(10.0,2.5,-6),vec3(12.0,4.5,-6),vec3(11.0,5.5,-6),vec3(16.0,5.5,-6),vec3(16.0,3.5,-6),vec3(17.0,3.5,-6),vec3(18.0,2.5,-6),vec3(16.0,2.5,-6),vec3(18.0,4.5,-6),vec3(17.0,5.5,-6),vec3(13.0,3.5,-6),vec3(13.0,5.5,-6),vec3(15.0,5.5,-6),vec3(13.0,2.5,-6),vec3(15.0,2.5,-6),vec3(15.0,3.5,-6)}
    } ^ am.draw("lines", am.ushort_elem_array{3, 1, 4, 3, 2, 4, 5, 2, 1, 5, 5, 6, 1, 7, 8, 9, 9, 10, 11, 8, 12, 11, 8, 13, 14, 15, 15, 16, 15, 17, 18, 19, 19, 20, 20, 21, 20, 22, 19, 23, 24, 25, 25, 26, 27, 24, 28, 27, 24, 29, 30, 31, 31, 32, 32, 33, 31, 34, 32, 35, 35, 36, 30, 36, 37, 38, 38, 39, 40, 37, 41, 40, 37, 42, 43, 44, 44, 45, 44, 46, 44, 47, 48, 49, 49, 50, 51, 55, 49, 52, 50, 53, 53, 54, 48, 54, 55, 56, 57, 58, 58, 59, 59, 60, 57, 60, 61, 62, 62, 63, 63, 64, 62, 65, 63, 66, 66, 67, 61, 67, 68, 69, 69, 70, 70, 71, 69, 72, 70, 73, 73, 74, 68, 74, 75, 76, 76, 77, 78, 75, 79, 78, 75, 80})
end

local function spawn_particle(velocity)
    local dx = (math.random() - 0.5) * 0.2
    local dy = (math.random() - 0.5) * 0.2
    local dz = (math.random() - 0.5) * 0.2
    local node = am.translate(
        spaceship.position + vec3(dx, dy, dz)
    )
    local scale = am.scale(1)

    local tau = math.pi * 2
    local rotation = am.rotate(quat(
        math.random() * tau,
        math.random() * tau,
        math.random() * tau
    ))
    rotation:append(particle)
    scale:append(rotation)
    node:append(scale)
    camera:append(node)

    local counter = 50
    local function update()
        local s = 3 * (counter / 50)
        node.position = node.position + velocity * am.delta_time
        scale.scale = vec3(s, s, s)

        if counter == 0 then
            camera:remove(node)
            return true
        else
            counter = counter - 1
        end
    end

    node:action(update)
end

local function spawn_raindrop()
    local dx = (math.random() - 0.5) * 50
    local dy = (math.random() - 0.5) * 50 + 20
    local dz = (math.random() - 0.5) * 50
    local node = am.translate(
        spaceship.position + vec3(dx, dy, dz)
    )

    node:append(raindrop)
    camera:append(node)

    local counter = 50
    local function update()
        node.position = node.position + vec3(0, -100, 0) * am.delta_time

        if counter == 0 then
            camera:remove(node)
            return true
        else
            counter = counter - 1
        end
    end

    node:action(update)
end

local function time_of_day()
    return ((am.frame_time / 240) % 1)
end

local function sky_effects(node)
    local sky_time = time_of_day() * (2 * math.pi)

    local sunset = (20000 ^ math.sin(sky_time - (2 * math.pi / 3))) / 10000

    local sky_r = (math.sin(sky_time) + 1) / 2 * 0.65 + sunset / 3
    local sky_g = (math.sin(sky_time) + 1) / 2 * 0.8 + sunset / 7
    local sky_b = (math.sin(sky_time) + 2 - (math.min(math.sin(sky_time), 0) ^ 10)) / 3
    sky_r = math.max(math.min(sky_r, 1), 0)
    sky_g = math.max(math.min(sky_g, 1), 0)
    sky_b = math.max(math.min(sky_b, 1), 0)

    node.sky = vec3(sky_r, sky_g, sky_b)
    win.clear_color = vec4(sky_r, sky_g, sky_b, 1)

    return false
end

local rain = am.sfxr_synth {
    wave_type = 'noise',
    p_env_attack = -0.08437553427906255,
    p_env_sustain = 0.16056052270237794,
    p_env_punch = 0.8376237582801731,
    p_env_decay = 0.144974117444178,
    p_base_freq = 0.04430129040165638,
    p_freq_limit = 0,
    p_freq_ramp = 0.059114750362785726,
    p_freq_dramp = -0.08041877606808882,
    p_vib_strength = 0.5522679571912658,
    p_vib_speed = 0.3001317341611113,
    p_arp_mod = 0.3574439720054907,
    p_arp_speed = 0.5480959530849505,
    p_duty = -0.17013320592443398,
    p_duty_ramp = -0.1104278047513457,
    p_repeat_speed = 0.041774806666022,
    p_pha_offset = -0.06989596069662736,
    p_pha_ramp = 0.0001352789854212541,
    p_lpf_freq = 1.0699610624157407,
    p_lpf_ramp = -0.13961208705305866,
    p_lpf_resonance = 0.15622074933510732,
    p_hpf_freq = -0.08896285784043828,
    p_hpf_ramp = 0.044428710487090885,
    sound_vol = 0.25,
    sample_rate = 44100,
    sample_size = 8,
    p_vib_delay = nil
}

local function init()
    init_shader()

    local chunk_group = am.group()
    chunk_group:action(load_terrain)

    create_spaceship()
    create_particle()
    create_raindrop()

    camera = am.lookat(vec3(0, 0, 0), vec3(0, 0, -1), vec3(0, 1, 0))
    camera:append(chunk_group)
    camera:append(spaceship)
    camera:append(create_title())

    local sky_changer = am.bind { sky = vec3(0, 0, 0) }
    sky_changer:action(sky_effects)
    sky_effects(sky_changer)

    win.scene = 
        am.cull_face("back")
        ^am.use_program(shader)
        ^am.bind {
            P = math.perspective(math.rad(90), win.width/win.height, 0.1, 200.0),
        }
        ^ sky_changer
        ^ camera

    win.scene:action(main_action)
end

local effectcounter = 0

local function move_spaceship()
    local pos = spaceship.position
    local rot = spaceship_rotation.rotation

    local delta = 0
    if win:key_down("left") or win:key_down("a") then
        delta = 10
    elseif win:key_down("right") or win:key_down("d") then
        delta = -10
    end
    rot = rot * quat(delta * am.delta_time, vec3(0, 1, 0))

    -- normalize rotation
    local rlen = rot.w * rot.w +
    rot.x * rot.x +
    rot.y * rot.y +
    rot.z * rot.z
    if rlen > 0 then
        rot = quat(
            rot.w / rlen,
            rot.x / rlen,
            rot.y / rlen,
            rot.z / rlen
        )
    end

    spaceship_rotation.rotation = rot

    local play_sound = false

    effectcounter = effectcounter + am.delta_time

    if win:key_down("space") then
        -- upwards thrust
        spaceship_velocity = spaceship_velocity + vec3(0, am.delta_time * 30, 0)

        if effectcounter > 0.1 then
            spawn_particle(vec3(0, -5, 0))
            play_sound = true
        end
    end

    if win:key_down("up") or win:key_down("w") then
        -- forwards thrust
        spaceship_velocity = spaceship_velocity +
            rot * vec3(0, 0, am.delta_time * 15)

        if effectcounter > 0.1 then
            spawn_particle(rot * vec3(0, 0, -5))
            play_sound = true
        end
    end

    if play_sound then
        win.scene:action(am.play(68334702, false, (math.random() * 0.25) + 0.875))
    end

    while effectcounter > 0.1 do
        effectcounter = effectcounter - 0.1

        if is_raining() then
            win.scene:action(am.play(rain, false, (math.random() * 0.25) + 0.875, 0.25))
            for _ = 1, 10 do
                spawn_raindrop()
            end
        end
    end

    -- air resistance
    spaceship_velocity = spaceship_velocity * (0.5 ^ am.delta_time)

    -- gravity
    spaceship_velocity = spaceship_velocity {
        y = spaceship_velocity.y - am.delta_time * 9.8
    }

    -- apply velocity
    pos = pos + spaceship_velocity * am.delta_time


    -- collision
    local top, bottom = get_height(pos.x, pos.z)
    if bottom ~= nil then
        if pos.y > bottom and pos.y < top then
            if math.abs(pos.y - bottom) < math.abs(pos.y - top) then
                pos = pos { y = bottom }
                spaceship_velocity = spaceship_velocity * (0.3 ^ am.delta_time)
                if spaceship_velocity.y > 0 then
                    spaceship_velocity = spaceship_velocity { y = 0 }
                end
            else
                pos = pos { y = top }
                spaceship_velocity = spaceship_velocity * (0.3 ^ am.delta_time)
                if spaceship_velocity.y < 0 then
                    spaceship_velocity = spaceship_velocity { y = 0 }
                end
            end
        end
    end

    spaceship.position = pos

    -- if we fell, reset
    if pos.y < -100 then
        local y = get_height(5, 5)
        spaceship.position = vec3(5, y, 5)
        spaceship_velocity = vec3(0, 0, 0)
    end
end

local function update_camera()
    local pos = spaceship.position
    camera.eye = pos + vec3(0, 6, 6)
    camera.center = pos
end

local ambience_counter = 0

function main_action()
    if win:key_pressed("escape") then
        win:close()
        return true
    end

    move_spaceship()
    update_camera()
    if ambience_counter <= 0 then
        if (math.cos(time_of_day() * 2 * math.pi) ^ 2) - 0.3 > math.random() then
            -- don't generate too many sound types or we could exhaust memory, since all sounds are cached
            -- 20 should be plenty
            local seed = math.random(20) * 5000000 + 7
            win.scene:action(am.play(seed))
        end
        ambience_counter = ambience_counter + math.random() + 1
    end
    ambience_counter = ambience_counter - am.delta_time
end

init()
