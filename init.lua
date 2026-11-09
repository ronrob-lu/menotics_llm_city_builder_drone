-- menotics_llm_city_builder_drone — init.lua
-- Autonomous city-building Drone powered by Ollama / OpenAI API.
-- Builds procedural structures on a strict 100-block grid in ~30s.
-- Zero street clutter, dynamic materials, video metadata generator.
--
-- REQUIRED minetest.conf setting:
--   secure.http_mods = menotics_llm_city_builder_drone
--
-- Configuration: <world_folder>/openrouter.json or <world_folder>/ollama.json
--
-- MIT License 2026, ronrob-lu, Antigravity

local MODNAME = minetest.get_current_modname()
local MODPATH = minetest.get_modpath(MODNAME)

-- ============================================================
-- Configuration
-- ============================================================

local CONFIG = {
    openrouter = {
        api_url             = "http://127.0.0.1:11434/v1/chat/completions",
        api_key             = "ollama",
        model               = "qwen2.5-coder:latest",
        temperature         = 0.7,
        repeat_penalty      = 1.0,    -- 1.0 disables repeat penalty (essential for voxel strings like "WWWW")
        top_k               = 0,      -- 0 disables top_k cutoff
        top_p               = 1.0,
        sleep_between_calls = 5.0,    -- minimum seconds between API calls
        timeout             = 300,    -- heavy timeout support for Ollama models (seconds)
    },
    grid = {
        step                = 100,    -- distance between structure centers (100 blocks)
        row_length          = 10,     -- number of structures per row before starting a new row
    },
    builder = {
        build_duration      = 30.0,   -- target duration to build entire structure (~30 seconds)
        fly_speed           = 16.0,   -- transit speed between grid points
        max_structures      = 0,      -- 0 for unlimited
        player_radius       = 80,     -- drone only operates if a player is within this radius (0 to disable check)
        sound_distance      = 150,    -- hear distance for block placement sound in nodes (set to 0 for global / complete game)
    }
}

-- ============================================================
-- Config Loader (Supports openrouter.json, ollama.json)
-- ============================================================

local function load_config()
    local worldpath = minetest.get_worldpath()
    local config_files = {
        -- 1. Dedicated Ollama configs (Highest Priority)
        worldpath .. "/ollama.json",
        worldpath .. "/ollama,json",
        MODPATH .. "/ollama.json",
        MODPATH .. "/ollama,json",
        worldpath .. "/drone_config.json",
        worldpath .. "/menotics_city_builder.json",
        -- 2. OpenRouter configs (only accepted if api_url is explicitly configured)
        worldpath .. "/openrouter.json",
        MODPATH .. "/openrouter.json",
    }

    local loaded_from = nil
    local data = nil

    for _, path in ipairs(config_files) do
        local f = io.open(path, "r")
        if f then
            local raw = f:read("*all")
            f:close()
            local ok, parsed = pcall(minetest.parse_json, raw)
            if ok and parsed and type(parsed) == "table" then
                -- If checking openrouter.json from another mod, only use it if it has an explicit api_url
                local is_ollama = path:find("ollama") ~= nil
                if is_ollama or parsed.api_url then
                    data = parsed
                    loaded_from = path
                    break
                end
            end
        end
    end

    -- Allow overrides from minetest.conf
    local conf_url = minetest.settings:get("menotics_city_builder_api_url")
                  or minetest.settings:get("menotics_llm_city_builder_drone.api_url")
                  or minetest.settings:get("city_builder_api_url")
    local conf_model = minetest.settings:get("menotics_city_builder_model")
                    or minetest.settings:get("menotics_llm_city_builder_drone.model")
    local conf_radius = minetest.settings:get("menotics_llm_city_builder_drone.player_radius")
                     or minetest.settings:get("drone_player_radius")

    if data then
        if data.api_url             then CONFIG.openrouter.api_url             = tostring(data.api_url) end
        if data.api_key             then CONFIG.openrouter.api_key             = tostring(data.api_key) end
        if data.model               then CONFIG.openrouter.model               = tostring(data.model)   end
        if data.temperature         then CONFIG.openrouter.temperature         = tonumber(data.temperature) or CONFIG.openrouter.temperature end
        if data.repeat_penalty      then CONFIG.openrouter.repeat_penalty      = tonumber(data.repeat_penalty) or CONFIG.openrouter.repeat_penalty end
        if data.top_k               then CONFIG.openrouter.top_k               = tonumber(data.top_k) or CONFIG.openrouter.top_k end
        if data.top_p               then CONFIG.openrouter.top_p               = tonumber(data.top_p) or CONFIG.openrouter.top_p end
        if data.timeout             then CONFIG.openrouter.timeout             = tonumber(data.timeout) or CONFIG.openrouter.timeout end
        if data.sleep_between_calls then CONFIG.openrouter.sleep_between_calls = tonumber(data.sleep_between_calls) or CONFIG.openrouter.sleep_between_calls end
        if data.grid_step           then CONFIG.grid.step                      = tonumber(data.grid_step) or CONFIG.grid.step end
        if data.grid_row_length     then CONFIG.grid.row_length                = tonumber(data.grid_row_length) or CONFIG.grid.row_length end
        if data.build_duration      then CONFIG.builder.build_duration         = tonumber(data.build_duration) or CONFIG.builder.build_duration end
        if data.max_structures      then CONFIG.builder.max_structures         = tonumber(data.max_structures) or CONFIG.builder.max_structures end
        if data.player_radius       then CONFIG.builder.player_radius          = tonumber(data.player_radius) or CONFIG.builder.player_radius end
        if data.sound_distance      then CONFIG.builder.sound_distance         = tonumber(data.sound_distance) or CONFIG.builder.sound_distance end
    else
        minetest.log("warning",
            "[" .. MODNAME .. "] No config file found in world or mod folder. "
            .. "Defaulting to: " .. CONFIG.openrouter.api_url)
    end

    if conf_url and conf_url ~= "" then
        CONFIG.openrouter.api_url = conf_url
        loaded_from = (loaded_from and (loaded_from .. " + ") or "") .. "minetest.conf"
    end
    if conf_model and conf_model ~= "" then
        CONFIG.openrouter.model = conf_model
    end
    if conf_radius and tonumber(conf_radius) then
        CONFIG.builder.player_radius = tonumber(conf_radius)
    end
    local conf_sound_dist = minetest.settings:get("menotics_llm_city_builder_drone.sound_distance")
                         or minetest.settings:get("drone_sound_distance")
    if conf_sound_dist and tonumber(conf_sound_dist) then
        CONFIG.builder.sound_distance = tonumber(conf_sound_dist)
    end

    minetest.log("action", string.format(
        "[%s] Config active: Endpoint=%s, Model=%s, Timeout=%ds (Loaded from: %s)",
        MODNAME, CONFIG.openrouter.api_url, CONFIG.openrouter.model,
        CONFIG.openrouter.timeout, loaded_from or "defaults"
    ))

    return loaded_from
end

-- ============================================================
-- HTTP API (requires secure.http_mods = menotics_llm_city_builder_drone)
-- ============================================================

local http_api = minetest.request_http_api()
if not http_api then
    minetest.log("error",
        "[" .. MODNAME .. "] HTTP API unavailable! "
        .. "Add '" .. MODNAME .. "' to secure.http_mods in minetest.conf and restart the server.")
end

local last_api_call_time = 0

local function can_call_api()
    local now = minetest.get_us_time() / 1e6
    return (now - last_api_call_time) >= CONFIG.openrouter.sleep_between_calls
end

-- ============================================================
-- Dynamic Material Resolver (NO bundled ky_materials)
-- Uses ky_materials ONLY if separately installed,
-- otherwise dynamically resolves to default: or mcl_core:
-- ============================================================

local function find_existing_node(candidates)
    for _, name in ipairs(candidates) do
        if minetest.registered_nodes[name] then
            return name
        end
    end
    return nil
end

local has_ky = (minetest.get_modpath("ky_materials") ~= nil)
               or (minetest.registered_nodes["ky_materials:stone"] ~= nil)

local KY_MAP = {
    ["W"] = "ky_materials:wood",
    ["w"] = "ky_materials:wood_red",
    ["S"] = "ky_materials:greystone",
    ["s"] = "ky_materials:stone",
    ["R"] = "ky_materials:redstone",
    ["b"] = "ky_materials:brick_grey",
    ["B"] = "ky_materials:brick_red",
    ["G"] = "ky_materials:glass",
    ["T"] = "ky_materials:trunk",
    ["t"] = "ky_materials:trunk_white",
    ["g"] = "ky_materials:dirt_with_grass",
    ["D"] = "ky_materials:dirt",
    ["r"] = "ky_materials:redsand",
    ["F"] = "ky_materials:fence_wood",
    ["f"] = "ky_materials:fence_stone",
    ["x"] = "ky_materials:gravel_dirt",
    ["X"] = "ky_materials:gravel_stone",
    ["#"] = "ky_materials:street",
}

local DEFAULT_CANDIDATES = {
    ["W"] = {"default:wood", "mcl_core:wood", "mcl_core:planks_oak"},
    ["w"] = {"default:aspen_wood", "default:acacia_wood", "mcl_core:planks_acacia",
             "mcl_core:planks_mangrove", "mcl_core:planks_crimson", "default:wood", "mcl_core:wood"},
    ["S"] = {"default:stone_block", "default:stone", "mcl_core:stonebrick", "mcl_core:stone"},
    ["s"] = {"default:stone", "mcl_core:stone", "default:cobble", "mcl_core:cobble"},
    ["R"] = {"default:desert_stone", "default:brick", "mcl_core:granite",
             "mcl_core:red_sandstone", "mcl_core:stone"},
    ["b"] = {"default:stonebrick", "mcl_core:stonebrick", "default:brick", "mcl_core:brick"},
    ["B"] = {"default:brick", "mcl_core:brick", "default:stonebrick", "mcl_core:stonebrick"},
    ["G"] = {"default:glass", "mcl_core:glass"},
    ["T"] = {"default:tree", "mcl_core:tree", "mcl_core:log_oak"},
    ["t"] = {"default:aspen_tree", "mcl_core:log_birch", "default:tree", "mcl_core:tree"},
    ["g"] = {"default:dirt_with_grass", "mcl_core:dirt_with_grass", "mapgen_dirt_with_grass"},
    ["D"] = {"default:dirt", "mcl_core:dirt", "mapgen_dirt"},
    ["r"] = {"default:desert_sand", "default:silver_sand", "default:sand", "mcl_core:redsand", "mcl_core:sand"},
    ["F"] = {"default:fence_wood", "mcl_fences:fence", "default:wood", "mcl_core:wood"},
    ["f"] = {"walls:cobblestone", "mcl_walls:cobblestone", "default:fence_wood", "default:stone", "mcl_core:stone"},
    ["x"] = {"default:gravel", "mcl_core:gravel", "default:stone", "mcl_core:stone"},
    ["X"] = {"default:gravel", "mcl_core:gravel", "default:stone", "mcl_core:stone"},
    ["#"] = {"default:stone_block", "mcl_core:stonebrick", "default:stone", "mcl_core:stone"},
}

local KY_CACHE = {}
local DEFAULT_CACHE = {}

local function resolve_symbol_node_ky(symbol)
    if KY_CACHE[symbol] then return KY_CACHE[symbol] end
    local resolved = KY_MAP[symbol] or "ky_materials:stone"
    if not minetest.registered_nodes[resolved] then
        resolved = find_existing_node({
            "ky_materials:stone", "default:stone", "mcl_core:stone"
        }) or "air"
    end
    KY_CACHE[symbol] = resolved
    return resolved
end

local function resolve_symbol_node_default(symbol)
    if DEFAULT_CACHE[symbol] then return DEFAULT_CACHE[symbol] end
    local candidates = DEFAULT_CANDIDATES[symbol] or {}
    local resolved = find_existing_node(candidates)
                  or find_existing_node({"default:stone", "mcl_core:stone"})
                  or "air"
    DEFAULT_CACHE[symbol] = resolved
    return resolved
end

local function resolve_symbol_node(symbol, use_ky)
    if symbol == "." or symbol == "_" or symbol == " " or symbol == "~" then
        return "air"
    end

    local pick_ky
    if use_ky ~= nil then
        pick_ky = use_ky and has_ky
    else
        -- If ky_materials is activated, 50% 50% chance to use default or ky materials
        pick_ky = has_ky and (math.random(1, 2) == 1)
    end

    if pick_ky then
        return resolve_symbol_node_ky(symbol)
    else
        return resolve_symbol_node_default(symbol)
    end
end

local function resolve_block_name(name, custom_palette, use_ky)
    if not name or type(name) ~= "string" or name == "" then return "air" end
    name = name:match("^%s*(.-)%s*$") -- trim

    if custom_palette and custom_palette[name] then
        return resolve_block_name(custom_palette[name], nil, use_ky)
    end

    if #name == 1 then
        return resolve_symbol_node(name, use_ky)
    end

    if minetest.registered_nodes[name] then
        return name
    end

    -- Try symbol resolution for common keywords
    local lower = name:lower()
    if lower == "air" or lower == "none" or lower == "empty" or lower == "void" then return "air" end
    if lower:find("glass") then return resolve_symbol_node("G", use_ky) end
    if lower:find("brick") then return resolve_symbol_node("b", use_ky) end
    if lower:find("wood") or lower:find("plank") then return resolve_symbol_node("W", use_ky) end
    if lower:find("log") or lower:find("tree") or lower:find("trunk") then return resolve_symbol_node("T", use_ky) end
    if lower:find("stone") then return resolve_symbol_node("S", use_ky) end
    if lower:find("grass") then return resolve_symbol_node("g", use_ky) end
    if lower:find("dirt") then return resolve_symbol_node("D", use_ky) end
    if lower:find("fence") then return resolve_symbol_node("F", use_ky) end
    if lower:find("sand") then return resolve_symbol_node("r", use_ky) end

    return resolve_symbol_node("S", use_ky)
end

-- ============================================================
-- Structure Catalog
-- ============================================================

local STRUCTURE_TYPES = {}

local function load_structures()
    local path = MODPATH .. "/structures.json"
    local f = io.open(path, "r")
    if not f then
        minetest.log("error", "[" .. MODNAME .. "] structures.json not found! Cannot build.")
        return
    end
    local raw = f:read("*all")
    f:close()
    local ok, data = pcall(minetest.parse_json, raw)
    if ok and data and data.structures then
        STRUCTURE_TYPES = data.structures
        minetest.log("action", string.format("[%s] Loaded %d structure types from structures.json.", MODNAME, #STRUCTURE_TYPES))
    else
        minetest.log("error", "[" .. MODNAME .. "] Failed to parse structures.json!")
    end
end

-- ============================================================
-- Grid State & Persistence
-- Strict 100-block grid with no street clutter
-- ============================================================

local grid_state = {
    origin_x = nil,
    origin_y = nil,
    origin_z = nil,
    next_col = 0,
    next_row = 0,
    structures = {},
    drone_killed = false,
    mcb_debug = false,
    mcb_record = true,
}

local function grid_state_path()
    return minetest.get_worldpath() .. "/city_drone_grid.json"
end

local function save_grid_state()
    local json = minetest.write_json(grid_state)
    local f = io.open(grid_state_path(), "w")
    if f then
        f:write(json)
        f:close()
    else
        minetest.log("error", "[" .. MODNAME .. "] Cannot write city_drone_grid.json!")
    end
end

local function load_grid_state()
    local f = io.open(grid_state_path(), "r")
    if not f then
        -- Fallback to legacy file if present
        f = io.open(minetest.get_worldpath() .. "/city_structure.json", "r")
        if not f then
            minetest.log("action", "[" .. MODNAME .. "] No grid state found — will initialize on drone spawn.")
            return
        end
    end

    local raw = f:read("*all")
    f:close()
    local ok, data = pcall(minetest.parse_json, raw)
    if ok and data then
        grid_state.origin_x = data.origin_x
        grid_state.origin_y = data.origin_y
        grid_state.origin_z = data.origin_z
        grid_state.next_col = tonumber(data.next_col) or 0
        grid_state.next_row = tonumber(data.next_row) or 0
        grid_state.structures = data.structures or {}
        grid_state.last_drone_pos = data.last_drone_pos

        if type(data.mcb_debug) == "boolean" then
            grid_state.mcb_debug = data.mcb_debug
        else
            grid_state.mcb_debug = false
        end

        if type(data.mcb_record) == "boolean" then
            grid_state.mcb_record = data.mcb_record
        else
            grid_state.mcb_record = true
        end

        -- Allow override from minetest.conf
        local conf_debug = minetest.settings:get_bool("mcb_debug")
        if conf_debug ~= nil then
            grid_state.mcb_debug = conf_debug
        end
        local conf_record = minetest.settings:get_bool("mcb_record")
        if conf_record ~= nil then
            grid_state.mcb_record = conf_record
        end

        minetest.log("action", string.format(
            "[%s] Loaded grid state: %d structures, next slot: (col=%d, row=%d, origin_y=%s, debug=%s, record=%s)",
            MODNAME, #grid_state.structures, grid_state.next_col, grid_state.next_row, tostring(grid_state.origin_y),
            grid_state.mcb_debug and "ON" or "OFF", grid_state.mcb_record and "ON" or "OFF"
        ))
    end
end

-- ============================================================
-- Terrain Helper & Ground Detection
-- ============================================================

local function is_dust_or_decor(nodename)
    if not nodename or nodename == "air" or nodename == "ignore" then return true end
    if nodename:find("snow") and not nodename:find("snowblock") and not nodename:find("snow_block") then return true end
    if minetest.get_item_group(nodename, "leaves") > 0 or
       minetest.get_item_group(nodename, "tree") > 0 or
       minetest.get_item_group(nodename, "wood") > 0 or
       minetest.get_item_group(nodename, "sapling") > 0 then
        return true
    end
    local grp_attached = minetest.get_item_group(nodename, "attached_node")
    local grp_flora = minetest.get_item_group(nodename, "flora")
    local grp_plant = minetest.get_item_group(nodename, "plant")
    return (grp_attached > 0 or grp_flora > 0 or grp_plant > 0)
end

local function is_ground_node(nodename)
    if not nodename or nodename == "air" or nodename == "ignore" then
        return false
    end
    if is_dust_or_decor(nodename) then
        return false
    end
    local def = minetest.registered_nodes[nodename]
    if not def then return false end
    if def.walkable then
        return true
    end
    if def.liquidtype and def.liquidtype ~= "none" then
        return true
    end
    return false
end

local function scan_single_column_y(xi, zi, start_y, end_y)
    if minetest.load_area then
        pcall(minetest.load_area, {x = xi - 1, y = end_y, z = zi - 1}, {x = xi + 1, y = start_y, z = zi + 1})
    end
    for y = start_y, end_y, -1 do
        local ok, n = pcall(minetest.get_node, {x = xi, y = y, z = zi})
        if ok and n and n.name and n.name ~= "air" and n.name ~= "ignore" then
            if is_ground_node(n.name) then
                return y
            end
        end
    end
    return nil
end

function get_surface_y(x, z, near_y)
    local xi, zi = math.floor(x), math.floor(z)
    local ref = near_y or (grid_state and grid_state.origin_y) or 10

    -- Scan downward across a deep range: from high above reference altitude down to bedrock/seabed
    local start_y = math.min(math.max(math.floor(ref) + 30, 80), 200)
    local end_y   = math.max(-32, ((grid_state and grid_state.origin_y) and (grid_state.origin_y - 50)) or -32)

    local solid_y = scan_single_column_y(xi, zi, start_y, end_y)

    -- If center column didn't find solid ground (e.g. hole, 1x1 void or obstruction), sample adjacent points
    if not solid_y then
        local offsets = {{2, 0}, {-2, 0}, {0, 2}, {0, -2}, {3, 3}, {-3, -3}}
        for _, off in ipairs(offsets) do
            solid_y = scan_single_column_y(xi + off[1], zi + off[2], start_y, end_y)
            if solid_y then break end
        end
    end

    -- Fallback: NEVER fallback to a high near_y! Always fallback to origin ground level or 1
    if not solid_y then
        solid_y = (grid_state and grid_state.origin_y) or 1
        minetest.log("warning", string.format(
            "[%s] Ground not found at (X=%d, Z=%d), using ground fallback Y=%d",
            MODNAME, xi, zi, solid_y
        ))
    end

    return solid_y + 1
end

-- Samples multiple points across the structure footprint and returns the median ground level
local function get_plot_ground_level(x1, z1, x2, z2, cx, cz, ref_y)
    local samples = {
        {x = cx, z = cz},
        {x = x1, z = z1},
        {x = x2, z = z1},
        {x = x1, z = z2},
        {x = x2, z = z2},
        {x = math.floor((x1 + x2) / 2), z = z1},
        {x = math.floor((x1 + x2) / 2), z = z2},
        {x = x1, z = math.floor((z1 + z2) / 2)},
        {x = x2, z = math.floor((z1 + z2) / 2)},
    }
    local y_vals = {}
    for _, pt in ipairs(samples) do
        local sy = get_surface_y(pt.x, pt.z, ref_y) - 1
        table.insert(y_vals, sy)
    end
    table.sort(y_vals)
    return y_vals[math.ceil(#y_vals / 2)]
end

-- Safely sanitize floating origin_y after world has fully initialized
local function sanitize_origin_y()
    if grid_state.origin_x and grid_state.origin_z and grid_state.origin_y then
        local ok, real_surf = pcall(get_surface_y, grid_state.origin_x, grid_state.origin_z, grid_state.origin_y)
        if ok and real_surf then
            local real_ground = real_surf - 1
            if math.abs(grid_state.origin_y - real_ground) > 10 then
                minetest.log("action", string.format(
                    "[%s] Auto-correcting floating origin_y (%d -> %d) to true ground level",
                    MODNAME, grid_state.origin_y, real_ground
                ))
                grid_state.origin_y = real_ground
                save_grid_state()
            end
        end
    end
end

minetest.after(2.0, sanitize_origin_y)

-- Player proximity & Beacon helpers
local function get_nearest_player(pos)
    local nearest = nil
    local min_dist = math.huge
    for _, player in ipairs(minetest.get_connected_players()) do
        local ppos = player:get_pos()
        if ppos then
            local d = vector.distance(pos, ppos)
            if d < min_dist then
                min_dist = d
                nearest = player
            end
        end
    end
    return nearest, min_dist
end

local function get_compass_direction(from_pos, to_pos)
    local dx = to_pos.x - from_pos.x
    local dz = to_pos.z - from_pos.z
    local angle = math.atan2(dx, dz) * (180 / math.pi)
    if angle < 0 then angle = angle + 360 end
    local dirs = {"North", "North-East", "East", "South-East", "South", "South-West", "West", "North-West"}
    local idx = math.floor((angle + 22.5) / 45) % 8 + 1
    return dirs[idx]
end

local function spawn_drone_beacon(pos)
    for i = 1, 35 do
        minetest.add_particle({
            pos = {
                x = pos.x + (math.random(-10, 10) * 0.02),
                y = pos.y + (i * 1.6),
                z = pos.z + (math.random(-10, 10) * 0.02)
            },
            velocity = {x = 0, y = 2.0, z = 0},
            acceleration = {x = 0, y = 0.2, z = 0},
            expirationtime = 2.5,
            size = 3.2,
            collisiondetection = false,
            texture = "menotics_landscaper_particle.png^[colorize:#00ff55:255",
            glow = 14,
        })
    end
end

-- ============================================================
-- Structure Metadata Generator (structure-meta/{id}.txt)
-- Describes structure in words for later video title generation
-- ============================================================

local function write_structure_meta(entry, plan)
    local meta_dir = minetest.get_worldpath() .. "/structure-meta"
    minetest.mkdir(meta_dir)
    local filepath = meta_dir .. "/" .. tostring(entry.id) .. ".txt"
    local f = io.open(filepath, "w")
    if not f then
        minetest.log("error", "[" .. MODNAME .. "] Failed to open metadata file: " .. filepath)
        return
    end

    local note = plan.city_note or "Procedural voxel architectural build."
    local content = string.format([[============================================================
STRUCTURE METADATA REPORT
============================================================
Structure ID:       %s
Name / Label:       %s
Structure Type:     %s
Target Dimensions:  Width=%d, Depth=%d, Height=%d
Total Blocks:       %d
Grid Position:      Row %d, Column %d
Grid Center:        (X=%d, Y=%d, Z=%d)
Bounding Box:       (%d, %d) to (%d, %d)
Material Theme:     %s
Timestamp:          %s
Model / AI Engine:  %s

============================================================
ARCHITECTURAL SUMMARY
============================================================
%s

============================================================
VIDEO TITLE GENERATION IDEAS
============================================================
1. Autonomous Drone Builds %s in Luanti | Ollama AI Voxel City #%s
2. I Built an AI Drone that Constructs %s Block-by-Block
3. %s Built in 30 Seconds by Autonomous Builder Drone!
4. AI City Construction Drone: %s (Structure ID: %s)
5. %s
]],
        entry.id,
        entry.label,
        entry.stype_id or (plan and plan.structure_type) or "custom",
        entry.w, entry.d, entry.h or (plan.height or 0),
        entry.block_count or 0,
        entry.grid_row or 0, entry.grid_col or 0,
        entry.cx, entry.y, entry.cz,
        entry.x1, entry.z1, entry.x2, entry.z2,
        entry.material_theme or "default",
        os.date("!%Y-%m-%d %H:%M:%SZ"),
        CONFIG.openrouter.model,
        note,
        entry.label, entry.id,
        entry.label,
        entry.label,
        entry.label, entry.id,
        note
    )

    f:write(content)
    f:close()
    minetest.log("action", string.format("[%s] Structure metadata saved to %s", MODNAME, filepath))
end

-- ============================================================
-- Single Drone Enforcement
-- Only one drone can exist in the world at a time
-- ============================================================

local function is_drone_already_active(exclude_obj)
    for _, ent in pairs(minetest.luaentities) do
        if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
            if not exclude_obj or ent.object ~= exclude_obj then
                return true, ent
            end
        end
    end
    return false, nil
end

-- ============================================================
-- OpenRouter / Ollama API Communication
-- ============================================================

local function build_city_summary()
    local parts = {}
    for _, s in ipairs(grid_state.structures) do
        table.insert(parts, string.format("%s(ID:%s,built=%s)", s.label, s.id, s.built and "yes" or "no"))
    end
    return #parts > 0 and table.concat(parts, "; ") or "none yet — this is the first structure in the city grid"
end

local function build_prompt()
    local city_summary = build_city_summary()
    return string.format([[
You are an autonomous voxel city planner and architect.
Examine what exists in the city so far and decide what building, facility, home, shop, or public space to construct next.

EXISTING CITY:
%s

ARCHITECTURAL INSPIRATION (REFERENCE TYPES):
- Houses & Residences: one-story house, two-story house, house with garden, apartment building
- Commercial: shop/storefront, bakery, cafe, restaurant, market hall
- Civic & Services: town hall, library, school, hospital, police station, fire station, church/temple
- Towers & Infrastructure: watchtower, clock tower, skyscraper, water tower, factory, windmill
- Public Spaces: town square park, garden, fountain plaza

YOUR PLANNING TASK:
1. Decide what structure this city needs next to become a more complete, vibrant, and realistic city.
2. Choose dimensions appropriate for your structure:
   - width: between 5 and 14 blocks (X axis, columns)
   - depth: between 5 and 14 blocks (Z axis, rows)
   - height: between 3 and 18 blocks (Y axis, layers)
3. Design a creative name (label), structure_type category, and architectural rationale (city_note).
4. Generate the full 3D voxel blueprint.

BLOCK PALETTE:
. = air (empty interior / doorway / openings / open space)
W = wood planks
w = red wood planks
S = greystone
s = stone
b = grey brick
B = red brick
G = glass (windows)
T = wooden trunk / log
t = white trunk
g = dirt with grass (park / yard ground)
D = dirt (paths / walkways)
r = red sand
F = wood fence
f = stone fence

============================================================
ARCHITECTURAL RULES (STRICT):
============================================================
1. HOLLOW WALKABLE INTERIORS (MANDATORY FOR ALL BUILDINGS):
   - Every building (houses, shops, civic buildings, towers) MUST be hollow inside!
   - Outer perimeter = solid walls, glass windows ('G'), corner pillars, and 1x2 door opening ('.').
   - The entire interior must be empty air ('.') for players to walk freely inside.
   - NEVER fill the interior of a building with solid wall blocks or solid cubes!

2. GROUND LEVEL & STORIES:
   - Layer 0 is the solid ground floor (wood/stone for buildings, grass 'g' or dirt 'D' for parks).
   - In gardens and parks, Layer 0 is ALWAYS grass ('g') or dirt ('D'). Fences ('F'/'f') must NEVER be placed on Layer 0; fences must ALWAYS be on Layer 1.
   - Every building story has walls that are 3 blocks high:
     * 1-Story Buildings: Layer 0 = floor, Layers 1..3 = hollow walls with windows/door, Layer 4 = solid flat roof.
     * 2-Story Buildings: Layer 0 = floor, Layers 1..3 = 1st story, Layer 4 = solid intermediate floor slab, Layers 5..7 = 2nd story, Layer 8 = solid flat roof.
     * Multi-Story / Towers: 3-block hollow rooms separated by a solid horizontal floor slab every 4 layers (Layer 0, 4, 8, 12, etc.).

3. DOORS & WINDOWS:
   - Door: A vertical 1x2 opening (air '.') in the center of one outer wall on Layer 1 and Layer 2. Layer 3 above the door is a solid wall block.
   - Windows: Glass windows ('G') on outer walls at eye level (e.g. Layers 2, 3, 6).

4. ROOFS:
   - All buildings have FLAT solid roofs (a solid horizontal cap across the top of the building walls).
   - The roof layer must be completely solid and weatherproof (e.g., 'w', 'W', 'b', 'S').
   - For parks and gardens, height is 2 and the roof is open to the sky.
   - For towers and skyscrapers, the top layer is a flat rooftop observation deck with perimeter battlements/railings.

5. MATERIAL CONSISTENCY:
   - Choose ONE uniform theme per building (Wood, Brick, or Stone).
   - Do NOT randomly mix materials.

============================================================
OUTPUT FORMAT:
============================================================
Respond with ONLY valid JSON (no markdown, no backticks, no preamble):
{
  "label": "<Name of Structure, e.g. Riverside Bakery>",
  "structure_type": "<e.g. shop, house, civic, tower, park, factory>",
  "width": <chosen integer between 5 and 14>,
  "depth": <chosen integer between 5 and 14>,
  "height": <chosen integer between 3 and 18>,
  "city_note": "<short rationale, max 80 chars>",
  "layers": [
    ["<row 0 string of exactly width chars>", ... (exactly depth rows)],
    ... (exactly height layer arrays)
  ]
}
]], city_summary)
end

local function chat_send_api_error(msg)
    minetest.log("error", msg)
    local colored = (minetest.colorize and minetest.colorize("#ff2222", msg)) or msg
    minetest.chat_send_all(colored)
end

local function call_api(callback)
    if not http_api then
        callback(nil, "HTTP API unavailable — add '" .. MODNAME .. "' to secure.http_mods")
        return
    end

    last_api_call_time = minetest.get_us_time() / 1e6

    local body = minetest.write_json({
        model             = CONFIG.openrouter.model,
        temperature       = CONFIG.openrouter.temperature,
        top_p             = CONFIG.openrouter.top_p or 1.0,
        frequency_penalty = 0.0,
        presence_penalty  = 0.0,
        options = {
            repeat_penalty = CONFIG.openrouter.repeat_penalty or 1.0,
            top_k          = CONFIG.openrouter.top_k or 0,
            top_p          = CONFIG.openrouter.top_p or 1.0,
        },
        messages = {
            {role="system", content="You are an autonomous voxel city planner and architect. "
                .. "Examine what the city has built so far, decide what building or space to construct next, "
                .. "choose appropriate dimensions (width 5-14, depth 5-14, height 3-18), and generate a complete 3D voxel blueprint. "
                .. "All buildings must be hollow inside with open air ('.') for walkable space. "
                .. "Garden fences must only be an outer perimeter frame (open walkable interior yard, never solid fences inside). "
                .. "All buildings have flat solid roofs. Multi-story buildings, watchtowers, and skyscrapers MUST have solid horizontal floor slabs every 4 layers (Layer 0, 4, 8, 12, etc.) separating hollow 3-block stories. "
                .. "Strictly follow the architectural rules: 3-block story heights, 1x2 doors, glass windows, consistent materials, "
                .. "and exact 2D grid dimensions for each layer. Always return valid JSON without markdown fences."},
            {role="user", content=build_prompt()},
        },
    })

    local extra_headers = {
        "Content-Type: application/json",
        "HTTP-Referer: minetest-menotics-city-builder-drone",
        "X-Title: Menotics City Builder Drone",
    }
    if CONFIG.openrouter.api_key and CONFIG.openrouter.api_key ~= "" and CONFIG.openrouter.api_key ~= "none" then
        table.insert(extra_headers, "Authorization: Bearer " .. CONFIG.openrouter.api_key)
    end

    http_api.fetch({
        url     = CONFIG.openrouter.api_url,
        method  = "POST",
        timeout = CONFIG.openrouter.timeout,
        extra_headers = extra_headers,
        data = body,
    }, function(result)
        if not result.succeeded then
            if result.timeout then
                callback(nil, "HTTP request timed out (" .. tostring(CONFIG.openrouter.timeout) .. "s)")
            else
                callback(nil, "HTTP request failed (code=" .. tostring(result.code) .. ")")
            end
            return
        end
        if result.code ~= 200 then
            local snippet = (result.data or ""):sub(1, 200)
            callback(nil, "API HTTP " .. result.code .. ": " .. snippet)
            return
        end

        local ok, resp = pcall(minetest.parse_json, result.data)
        if not ok or not resp then
            callback(nil, "Cannot parse API JSON response")
            return
        end
        if not resp.choices or not resp.choices[1] then
            callback(nil, "API response has no choices")
            return
        end

        local content = (resp.choices[1].message or {}).content or ""
        content = content:match("```json%s*(.-)%s*```") or
                  content:match("```%s*(.-)%s*```")     or
                  content
        if not content:match("^%s*{") then
            content = content:match("({%s*[\"'].*})") or content
        end
        content = content:match("^%s*(.-)%s*$")

        local ok2, plan = pcall(minetest.parse_json, content)
        if not ok2 or not plan then
            callback(nil, "Cannot parse structure plan from AI output: " .. content:sub(1,120))
            return
        end
        if not plan.layers or type(plan.layers) ~= "table" or #plan.layers == 0 then
            callback(nil, "AI plan missing 'layers' array")
            return
        end

        local h = tonumber(plan.height) or #plan.layers
        local d = tonumber(plan.depth)
        local w = tonumber(plan.width)

        if (not d or not w) and type(plan.layers[1]) == "table" and #plan.layers[1] > 0 then
            d = d or #plan.layers[1]
            if type(plan.layers[1][1]) == "string" then
                w = w or #plan.layers[1][1]
            end
        end

        w = math.max(5, math.min(14, w or 7))
        d = math.max(5, math.min(14, d or 7))
        h = math.max(2, math.min(18, h or #plan.layers))

        plan.width = w
        plan.depth = d
        plan.height = h
        plan.label = (type(plan.label) == "string" and plan.label ~= "") and plan.label or "City Structure"
        plan.structure_type = (type(plan.structure_type) == "string" and plan.structure_type ~= "") and plan.structure_type or "building"
        plan.city_note = (type(plan.city_note) == "string" and plan.city_note ~= "") and plan.city_note or "Autonomous architectural construction."

        callback(plan, nil)
    end)
end

-- ============================================================
-- Block Queue Generation (No streets)
-- ============================================================

local function clear_plot_interior(x1, z1, x2, z2, base_y, max_h)
    local clear_h = math.max(max_h or 12, 12)
    for x = x1, x2 do
        for z = z1, z2 do
            for y = base_y + 1, base_y + clear_h do
                local n = minetest.get_node({x=x, y=y, z=z})
                if n.name ~= "air" and n.name ~= "ignore" then
                    minetest.set_node({x=x, y=y, z=z}, {name="air"})
                end
            end
        end
    end
end

local function generate_foundation(x1, z1, x2, z2, base_y, use_ky)
    local blocks = {}
    local stone_node = resolve_symbol_node("S", use_ky)
    for x = x1, x2 do
        for z = z1, z2 do
            local surf = get_surface_y(x, z, base_y)
            if (surf - 1) < base_y then
                for y = surf - 1, base_y - 1 do
                    table.insert(blocks, {x=x, y=y, z=z, name=stone_node})
                end
            end
        end
    end
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.z ~= b.z then return a.z < b.z end
        if (a.z % 2) == 0 then return a.x < b.x else return a.x > b.x end
    end)
    return blocks
end

local function extract_layer_blocks(layer_data, w, d, custom_palette, use_ky)
    local blocks = {}
    local expected = w * d

    if type(layer_data) == "string" then
        for i = 1, #layer_data do
            local ch = layer_data:sub(i, i)
            table.insert(blocks, resolve_block_name(ch, custom_palette, use_ky))
        end
    elseif type(layer_data) == "table" then
        local is_row_strings = true
        for _, item in ipairs(layer_data) do
            if type(item) ~= "string" or (#item > 1 and item:find(":")) then
                is_row_strings = false
                break
            end
        end

        if is_row_strings and #layer_data > 0 and #layer_data[1] > 1 and not layer_data[1]:find(" ") then
            for r = 1, d do
                local row_str = layer_data[r] or ""
                for i = 1, w do
                    local ch = (i <= #row_str) and row_str:sub(i, i) or "."
                    table.insert(blocks, resolve_block_name(ch, custom_palette, use_ky))
                end
            end
        else
            for _, item in ipairs(layer_data) do
                if type(item) == "string" then
                    table.insert(blocks, resolve_block_name(item, custom_palette, use_ky))
                elseif type(item) == "table" then
                    for _, sub in ipairs(item) do
                        table.insert(blocks, resolve_block_name(tostring(sub), custom_palette, use_ky))
                    end
                else
                    table.insert(blocks, "air")
                end
            end
        end
    end

    while #blocks < expected do
        table.insert(blocks, "air")
    end
    return blocks
end

local function generate_structure_blocks(plan_or_layers, x1, z1, base_y, w, d, stype_id, use_ky, plan)
    local layers = plan_or_layers
    local custom_palette = nil
    if type(plan_or_layers) == "table" and plan_or_layers.layers then
        layers = plan_or_layers.layers
        custom_palette = plan_or_layers.palette
    end

    if type(layers) ~= "table" then layers = {} end

    local expected = w * d
    local raw_layer_list = {}
    for _, layer_data in ipairs(layers) do
        table.insert(raw_layer_list, extract_layer_blocks(layer_data, w, d, custom_palette, use_ky))
    end

    local fence_wood_node = resolve_symbol_node("F", use_ky)
    local fence_stone_node = resolve_symbol_node("f", use_ky)
    local grass_node = resolve_symbol_node("g", use_ky)

    -- Fence safeguard for Layer 0
    if #raw_layer_list >= 1 then
        for i = 1, expected do
            local b0 = raw_layer_list[1][i]
            if b0 == fence_wood_node or b0 == fence_stone_node then
                raw_layer_list[1][i] = grass_node
                if #raw_layer_list >= 2 and raw_layer_list[2][i] == "air" then
                    raw_layer_list[2][i] = b0
                end
            end
        end
    end

    -- Garden & Park hollow safeguards
    local stype_str = tostring(stype_id or ""):lower()
    local label_str = tostring(plan and plan.label or ""):lower()
    local is_park = stype_str:find("park") or stype_str:find("garden")
                 or label_str:find("park") or label_str:find("garden")
                 or #raw_layer_list <= 3

    if is_park then
        if #raw_layer_list >= 2 and w >= 3 and d >= 3 then
            for zi = 1, d - 2 do
                for xi = 1, w - 2 do
                    local idx = zi * w + xi + 1
                    local b = raw_layer_list[2][idx]
                    if b == fence_wood_node or b == fence_stone_node then
                        raw_layer_list[2][idx] = "air"
                    end
                end
            end
        end
        if #raw_layer_list >= 3 then
            for yi = 3, #raw_layer_list do
                for i = 1, expected do
                    local b = raw_layer_list[yi][i]
                    if b == fence_wood_node or b == fence_stone_node then
                        raw_layer_list[yi][i] = "air"
                    end
                end
            end
        end
    end

    -- Generic hollow interior safeguards for ANY building (height >= 4)
    if not is_park and #raw_layer_list >= 4 then
        for yi, raw_blocks in ipairs(raw_layer_list) do
            local is_intermediate_floor = ((yi - 1) % 4 == 0)
            local is_wall_layer = (yi >= 2 and yi <= (#raw_layer_list - 1) and not is_intermediate_floor)

            if is_wall_layer and w >= 4 and d >= 4 then
                local interior_solid = 0
                local interior_total = (w - 2) * (d - 2)
                for zi = 1, d - 2 do
                    for xi = 1, w - 2 do
                        local idx = zi * w + xi + 1
                        if raw_blocks[idx] and raw_blocks[idx] ~= "air" then
                            interior_solid = interior_solid + 1
                        end
                    end
                end
                if interior_solid > (interior_total * 0.50) then
                    for zi = 1, d - 2 do
                        for xi = 1, w - 2 do
                            local idx = zi * w + xi + 1
                            raw_blocks[idx] = "air"
                        end
                    end
                end
            end
        end
    end

    local blocks = {}
    for yi, raw_blocks in ipairs(raw_layer_list) do
        for i = 1, expected do
            local bname = raw_blocks[i] or "air"
            if bname ~= "air" then
                local zi = math.floor((i - 1) / w)
                local xi = (i - 1) % w
                table.insert(blocks, {
                    x = x1 + xi,
                    y = base_y + (yi - 1),
                    z = z1 + zi,
                    name = bname,
                })
            end
        end
    end

    -- Bottom-up serpentine build order
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.z ~= b.z then return a.z < b.z end
        if (a.z % 2) == 0 then return a.x < b.x else return a.x > b.x end
    end)
    return blocks
end

-- ============================================================
-- Drone Entity Definition (menotics_builder visuals, NO nametag)
-- ============================================================

minetest.register_entity(MODNAME .. ":builder_drone", {
    initial_properties = {
        physical = false,
        collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        visual = "cube",
        textures = {
            "menotics_builder_builder_drone_top.png",
            "menotics_builder_builder_drone_bottom.png",
            "menotics_builder_builder_drone_side.png",
            "menotics_builder_builder_drone_side.png",
            "menotics_builder_builder_drone_side.png",
            "menotics_builder_builder_drone_front.png",
        },
        static_save = true,
    },

    -- Entity fields
    state           = "IDLE",     -- IDLE | PLANNING | BUILDING | FLY_TO_GRID
    build_queue     = nil,
    build_index     = 0,
    build_start_t   = 0,
    current_entry   = nil,
    pending_stype   = nil,
    pending_plan    = nil,
    target_pos      = nil,
    planning_timer  = 0,
    thrust_timer    = 0,
    bob_timer       = 0,
    api_pending     = false,
    api_response    = nil,

    on_activate = function(self, staticdata, dtime_s)
        -- If drone was killed via command while unloaded, self-destruct immediately
        if grid_state.drone_killed then
            self.object:remove()
            return
        end

        -- Enforce single drone in the world!
        local already_active, other_ent = is_drone_already_active(self.object)
        if already_active then
            minetest.log("warning", "[" .. MODNAME .. "] Duplicate builder drone detected! Removing duplicate.")
            self.object:remove()
            return
        end

        self.object:set_armor_groups({fleshy = 100})
        self.state = "IDLE"
        self.thrust_timer = 0
        self.bob_timer = 0

        local pos = self.object:get_pos()
        if pos then
            if not grid_state.origin_x or not grid_state.origin_y then
                local ground_surf = get_surface_y(pos.x, pos.z, pos.y)
                grid_state.origin_x = math.floor(pos.x)
                grid_state.origin_y = ground_surf - 1
                grid_state.origin_z = math.floor(pos.z)
                save_grid_state()
                minetest.log("action", string.format(
                    "[%s] Initialized grid origin at (X=%d, Y=%d [ground], Z=%d)",
                    MODNAME, grid_state.origin_x, grid_state.origin_y, grid_state.origin_z
                ))
            end
        end
    end,

    get_staticdata = function(self)
        return minetest.serialize({
            state = "IDLE"
        })
    end,

    _chat = function(self, msg)
        if grid_state.mcb_debug then
            minetest.chat_send_all("[CityBuilderDrone] " .. msg)
        end
    end,

    on_step = function(self, dtime)
        local pos = self.object:get_pos()
        if not pos then return end

        local now = minetest.get_us_time() / 1e6
        self.thrust_timer = (self.thrust_timer or 0) + dtime
        self.bob_timer = (self.bob_timer or 0) + dtime
        self.save_pos_timer = (self.save_pos_timer or 0) + dtime

        -- Periodically save drone position to grid state so player can always locate it
        if self.save_pos_timer >= 3.0 then
            self.save_pos_timer = 0
            grid_state.last_drone_pos = {
                x = math.floor(pos.x),
                y = math.floor(pos.y),
                z = math.floor(pos.z)
            }
            save_grid_state()
        end

        -- Issue 2: Drone only operates if a player is nearby!
        local player_radius = CONFIG.builder.player_radius or 80
        if player_radius > 0 then
            local nearest_player, dist_to_player = get_nearest_player(pos)
            if not nearest_player or dist_to_player > player_radius then
                -- No player nearby: gently hover in place and pause all activity
                local bob = math.sin(self.bob_timer * 1.5) * 0.1
                self.object:set_velocity({x = 0, y = bob, z = 0})
                self.waiting_for_player = true
                return
            end
            self.waiting_for_player = false
        end

        -- Spawning thrust flame particles (neon green glowing downwards)
        if self.thrust_timer >= 0.12 then
            self.thrust_timer = 0
            minetest.add_particle({
                pos = {x = pos.x, y = pos.y - 0.45, z = pos.z},
                velocity = {
                    x = math.random(-8, 8) * 0.04,
                    y = -1.2 - math.random() * 0.5,
                    z = math.random(-8, 8) * 0.04
                },
                acceleration = {x = 0, y = -0.2, z = 0},
                expirationtime = 0.4 + math.random() * 0.3,
                size = 1.2 + math.random() * 1.2,
                collisiondetection = true,
                texture = "menotics_landscaper_particle.png^[colorize:#00ff55:200",
                glow = 12,
            })
        end

        local s = self.state
        if s == "IDLE" then
            self:_step_idle(pos, dtime, now)
        elseif s == "PLANNING" then
            self:_step_planning(pos, dtime, now)
        elseif s == "PRE_BUILD" then
            self:_step_pre_build(pos, dtime, now)
        elseif s == "BUILDING" then
            self:_step_building(pos, dtime, now)
        elseif s == "FLY_TO_GRID" then
            self:_step_flying(pos, dtime, now)
        end
    end,

    _step_idle = function(self, pos, dtime, now)
        -- Bob gently in place
        local bob = math.sin(self.bob_timer * 2.0) * 0.25
        self.object:set_velocity({x = 0, y = bob, z = 0})

        -- Check if ready to build next structure
        if not can_call_api() then return end
        if not http_api then return end

        -- City cap check
        if CONFIG.builder.max_structures > 0 and #grid_state.structures >= CONFIG.builder.max_structures then
            self:_chat("City build limit reached (" .. CONFIG.builder.max_structures .. " structures). Drone standing by.")
            self.state = "STANDBY"
            return
        end

        -- Ensure origin is known and grounded
        if not grid_state.origin_x or not grid_state.origin_y then
            local ground_surf = get_surface_y(pos.x, pos.z, pos.y)
            grid_state.origin_x = math.floor(pos.x)
            grid_state.origin_y = ground_surf - 1
            grid_state.origin_z = math.floor(pos.z)
            save_grid_state()
        end

        -- Calculate next grid coordinate (100 block spacing from middle)
        local col = grid_state.next_col or 0
        local row = grid_state.next_row or 0
        local cx = grid_state.origin_x + col * CONFIG.grid.step
        local cz = grid_state.origin_z + row * CONFIG.grid.step

        -- Always verify ground level at current grid center
        local center_ground = get_surface_y(cx, cz, grid_state.origin_y) - 1
        local target_hover_y = center_ground + 7.0

        -- If drone is far from grid center (horizontal OR vertical), fly/adjust there first
        local h_dist = vector.distance({x=pos.x, y=0, z=pos.z}, {x=cx, y=0, z=cz})
        local v_diff = math.abs(pos.y - target_hover_y)

        if h_dist > 2.0 or v_diff > 2.0 then
            self.target_pos = {x = cx, y = target_hover_y, z = cz}
            self.state = "FLY_TO_GRID"
            return
        end

        local struct_id = string.format("structure_%03d", #grid_state.structures + 1)
        local entry = {
            id            = struct_id,
            cx            = cx,
            cz            = cz,
            center_ground = center_ground,
            grid_col      = col,
            grid_row      = row,
            built         = false,
            ts            = os.time(),
        }

        self.current_entry = entry
        self.pending_stype = nil
        self.state = "PLANNING"
        self.api_pending = true
        self.api_response = nil
        self.planning_timer = 0

        local self_ref = self
        call_api(function(plan, err)
            if not self_ref.object or not pcall(function() self_ref.object:get_pos() end) then return end
            if err then
                self_ref.api_response = {error = err}
            else
                self_ref.api_response = plan
            end
            self_ref.api_pending = false
        end)
    end,

    _step_planning = function(self, pos, dtime, now)
        -- Maintain stable hover above grid center
        local entry = self.current_entry
        if entry then
            local target_hover_y = (entry.y or entry.center_ground or grid_state.origin_y or 10) + 7.0
            local bob = math.sin(self.bob_timer * 3.0) * 0.2
            local dy = (target_hover_y + bob) - pos.y
            local vy = math.max(-2.5, math.min(2.5, dy * 2.0))
            local dx = entry.cx - pos.x
            local dz = entry.cz - pos.z
            local vx = math.max(-2.5, math.min(2.5, dx * 2.0))
            local vz = math.max(-2.5, math.min(2.5, dz * 2.0))
            self.object:set_velocity({x = vx, y = vy, z = vz})
        else
            local bob = math.sin(self.bob_timer * 3.0) * 0.2
            self.object:set_velocity({x = 0, y = bob, z = 0})
        end

        self.planning_timer = (self.planning_timer or 0) + dtime

        if self.api_pending then
            if self.planning_timer > (CONFIG.openrouter.timeout + 10) then
                chat_send_api_error("[CityBuilderDrone] ERROR: AI model request timed out after " .. math.floor(self.planning_timer) .. "s.")
                self.api_pending = false
                self.api_response = {error = "Timeout"}
            else
                return
            end
        end

        local plan = self.api_response
        self.api_response = nil
        self.planning_timer = 0

        if not plan or plan.error then
            chat_send_api_error(string.format("[CityBuilderDrone] AI Planning failed: %s (Endpoint: %s). Retrying...",
                tostring(plan and plan.error or "No response"), CONFIG.openrouter.api_url))
            self.state = "IDLE"
            return
        end

        local entry = self.current_entry
        local w = plan.width or 8
        local d = plan.depth or 8
        local h = plan.height or (#plan.layers)

        -- Calculate structure footprint centered on cx, cz
        local cx = entry.cx
        local cz = entry.cz
        local x1 = cx - math.floor(w / 2)
        local x2 = x1 + w - 1
        local z1 = cz - math.floor(d / 2)
        local z2 = z1 + d - 1

        -- ALWAYS CHECK GROUND LEVEL ACROSS THE PLOT FOOTPRINT!
        local base_y = get_plot_ground_level(x1, z1, x2, z2, cx, cz, entry.center_ground or (grid_state.origin_y or 10))

        entry.label = plan.label or "City Structure"
        entry.stype_id = plan.structure_type or "building"
        entry.x1 = x1
        entry.z1 = z1
        entry.x2 = x2
        entry.z2 = z2
        entry.w = w
        entry.d = d
        entry.h = h
        entry.y = base_y

        -- Material resolution: If ky_materials is activated, 50% 50% chance to use default or ky_materials
        local use_ky = has_ky and (math.random(1, 2) == 1)
        entry.use_ky = use_ky
        entry.material_theme = use_ky and "ky_materials" or "default"

        -- PUSH TO CHAT: Planning completed
        self:_chat(string.format("Planning completed: %s (ID: %s, Theme: %s) — \"%s\"",
            entry.label, entry.id, entry.material_theme, plan.city_note or "Blueprint generated successfully."))

        -- Clear trees and flora in volume
        clear_plot_interior(entry.x1, entry.z1, entry.x2, entry.z2, entry.y, #plan.layers)

        -- Build queues (foundation + structure)
        local foundation = generate_foundation(entry.x1, entry.z1, entry.x2, entry.z2, entry.y, use_ky)
        local structure  = generate_structure_blocks(plan.layers, entry.x1, entry.z1, entry.y, entry.w, entry.d, entry.stype_id, use_ky, plan)

        local queue = {}
        for _, b in ipairs(foundation) do table.insert(queue, b) end
        for _, b in ipairs(structure)  do table.insert(queue, b) end

        entry.block_count = #queue

        -- Save metadata file immediately for video title generation
        write_structure_meta(entry, plan)

        -- Pacing setup: ~30 seconds total build time
        self.build_queue    = queue
        self.build_index    = 1

        if grid_state.mcb_record then
            minetest.chat_send_all("[mcb_start]FILE:" .. tostring(entry.id))
            self.pre_build_timer = 1.0
            self.state           = "PRE_BUILD"
        else
            self.build_start_t   = now
            self.state           = "BUILDING"
        end
    end,

    _step_pre_build = function(self, pos, dtime, now)
        -- Maintain stable hover above grid center during 1-second recording lead-in
        local entry = self.current_entry
        if entry then
            local target_hover_y = entry.y + 7.0
            local bob = math.sin(self.bob_timer * 3.0) * 0.2
            local dy = (target_hover_y + bob) - pos.y
            local vy = math.max(-2.5, math.min(2.5, dy * 2.0))
            local dx = entry.cx - pos.x
            local dz = entry.cz - pos.z
            local vx = math.max(-2.5, math.min(2.5, dx * 2.0))
            local vz = math.max(-2.5, math.min(2.5, dz * 2.0))
            self.object:set_velocity({x = vx, y = vy, z = vz})
        end

        self.pre_build_timer = (self.pre_build_timer or 1.0) - dtime
        if self.pre_build_timer <= 0 then
            self.pre_build_timer = nil
            self.build_start_t   = now
            self.state           = "BUILDING"
        end
    end,

    _step_building = function(self, pos, dtime, now)
        local queue = self.build_queue
        if not queue or self.build_index > #queue then
            self:_finish_structure(pos, now)
            return
        end

        local total = #queue
        local target_duration = CONFIG.builder.build_duration or 30.0
        local elapsed = now - self.build_start_t

        -- Calculate how many blocks should be placed by now
        local target_idx
        if target_duration <= 0 then
            target_idx = total
        else
            target_idx = math.floor((elapsed / target_duration) * total) + 1
        end
        if target_idx > total then target_idx = total end

        -- Place blocks up to target_idx (batch limit per tick to prevent server freeze)
        local placed_this_tick = 0
        local max_per_tick = 12
        local last_placed_pos = nil

        while self.build_index <= target_idx and placed_this_tick < max_per_tick do
            local block = queue[self.build_index]
            if block and block.name and block.name ~= "air" then
                local place_pos = {x = block.x, y = block.y, z = block.z}
                last_placed_pos = place_pos

                -- Place node
                minetest.set_node(place_pos, {
                    name   = block.name,
                    param1 = block.param1 or 0,
                    param2 = block.param2 or 0
                })

                -- Construction laser beam (neon green particles from drone to block)
                local steps = 8
                for i = 0, steps do
                    local t = i / steps
                    local px = pos.x + (place_pos.x - pos.x) * t
                    local py = (pos.y - 0.4) + (place_pos.y - (pos.y - 0.4)) * t
                    local pz = pos.z + (place_pos.z - pos.z) * t
                    minetest.add_particle({
                        pos = {x = px, y = py, z = pz},
                        velocity = {x = 0, y = 0, z = 0},
                        acceleration = {x = 0, y = 0, z = 0},
                        expirationtime = 0.25,
                        size = 1.3,
                        collisiondetection = false,
                        texture = "menotics_landscaper_particle.png^[colorize:#00ff55:255",
                        glow = 14,
                    })
                end

                -- Particle burst at block
                pcall(function()
                    minetest.add_particlespawner({
                        amount = 4,
                        time = 0.1,
                        minpos = vector.subtract(place_pos, 0.3),
                        maxpos = vector.add(place_pos, 0.3),
                        minvel = {x=-0.5, y=0.5, z=-0.5},
                        maxvel = {x=0.5, y=1.5, z=0.5},
                        minacc = {x=0, y=-9.8, z=0},
                        maxacc = {x=0, y=-9.8, z=0},
                        minexptime = 0.25,
                        maxexptime = 0.45,
                        minsize = 0.5,
                        maxsize = 1.2,
                        texture = "menotics_landscaper_particle.png^[colorize:#00ff55:220",
                    })
                end)
            end

            self.build_index = self.build_index + 1
            placed_this_tick = placed_this_tick + 1
        end

        -- Sound effect (audible at a much longer distance, or globally if sound_distance <= 0)
        if placed_this_tick > 0 and last_placed_pos then
            pcall(function()
                local sdist = CONFIG.builder.sound_distance
                local spec = { gain = 0.5 }
                if sdist and sdist > 0 then
                    spec.pos = last_placed_pos
                    spec.max_hear_distance = sdist
                end
                minetest.sound_play("default_place_node", spec, true)
            end)
        end

        -- Drone movement: hover smoothly above current building area
        local entry = self.current_entry
        if entry then
            local current_block = queue[math.min(self.build_index, total)]
            local hover_x = current_block and current_block.x or entry.cx
            local hover_y = (current_block and current_block.y or entry.y) + 3.5
            local hover_z = current_block and current_block.z or entry.cz
            local target_hover = {x = hover_x, y = hover_y, z = hover_z}

            local dist = vector.distance(pos, target_hover)
            if dist > 0.6 then
                local dir = vector.direction(pos, target_hover)
                local speed = math.min(dist * 3.0, 10.0)
                self.object:set_velocity(vector.multiply(dir, speed))
                self.object:set_yaw(math.atan2(-dir.x, dir.z))
            else
                self.object:set_velocity({x = 0, y = 0, z = 0})
            end
        end

        -- Check completion
        if self.build_index > total or elapsed >= target_duration + 2.0 then
            self:_finish_structure(pos, now)
            return
        end
    end,

    _finish_structure = function(self, pos, now)
        local entry = self.current_entry
        if entry then
            entry.built = true
            table.insert(grid_state.structures, entry)

            -- Advance grid slot
            grid_state.next_col = (grid_state.next_col or 0) + 1
            if grid_state.next_col >= CONFIG.grid.row_length then
                grid_state.next_col = 0
                grid_state.next_row = (grid_state.next_row or 0) + 1
                self:_chat(string.format("Row %d complete! Starting Row %d on grid.",
                    grid_state.next_row - 1, grid_state.next_row))
            end
            save_grid_state()

            -- PUSH TO CHAT: Structure end
            self:_chat(string.format("Structure end: %s (ID: %s)", entry.label, entry.id))

            -- RECORD SIGNAL: Trigger mcb_stop 2 seconds after structure finished
            if grid_state.mcb_record then
                local file_id = tostring(entry.id)
                minetest.after(2.0, function()
                    minetest.chat_send_all("[mcb_stop]FILE:" .. file_id)
                end)
            end
        end

        self.current_entry = nil
        self.build_queue   = nil
        self.build_index   = 0

        -- Calculate next grid coordinates (100 blocks away from center)
        local next_cx = grid_state.origin_x + grid_state.next_col * CONFIG.grid.step
        local next_cz = grid_state.origin_z + grid_state.next_row * CONFIG.grid.step

        -- Determine departure ground level (ground of structure just finished, never the high roof)
        local dep_ground = (entry and entry.y) or (get_surface_y(pos.x, pos.z, grid_state.origin_y) - 1)
        local next_ground_est = get_surface_y(next_cx, next_cz, dep_ground) - 1
        local next_y = next_ground_est + 7.0

        self.target_pos = {x = next_cx, y = next_y, z = next_cz}
        self.state = "FLY_TO_GRID"
    end,

    _step_flying = function(self, pos, dtime, now)
        if not self.target_pos then
            self.state = "IDLE"
            return
        end

        local dx = self.target_pos.x - pos.x
        local dz = self.target_pos.z - pos.z
        local h_dist = math.sqrt(dx * dx + dz * dz)

        -- Dynamically follow terrain directly below drone while in transit
        local current_ground_surf = get_surface_y(pos.x, pos.z, pos.y)
        local current_ground = current_ground_surf - 1
        local cruise_y = current_ground + 7.5

        -- As we get close to destination, lock target altitude to destination's verified ground
        if h_dist < 15.0 then
            local dest_ground = get_surface_y(self.target_pos.x, self.target_pos.z, current_ground) - 1
            self.target_pos.y = dest_ground + 7.0
        end

        local target_y = (h_dist < 15.0 and self.target_pos.y) or cruise_y
        local v_diff = target_y - pos.y

        if h_dist > 1.5 or math.abs(v_diff) > 1.5 then
            local speed = CONFIG.builder.fly_speed or 16.0
            local vx, vz = 0, 0
            if h_dist > 0.1 then
                vx = (dx / h_dist) * speed
                vz = (dz / h_dist) * speed
                self.object:set_yaw(math.atan2(-dx, dz))
            end

            -- Smooth vertical terrain tracking
            local bob = math.sin(self.bob_timer * 2.5) * 0.2
            local vy = math.max(-10.0, math.min(10.0, v_diff * 3.5)) + bob

            self.object:set_velocity({x = vx, y = vy, z = vz})
        else
            -- Arrived at target grid center and correct hover altitude above ground!
            self.object:set_velocity({x = 0, y = 0, z = 0})
            self.target_pos = nil
            self.state = "IDLE"
        end
    end,

    on_rightclick = function(self, clicker)
        if not clicker or not clicker:is_player() then return end
        local pname = clicker:get_player_name()
        local pos = self.object:get_pos() or {x=0,y=0,z=0}
        local entry = self.current_entry
        local info = string.format(
            "[%s] State: %s | Active Build: %s | City Total: %d | Next Grid Slot: (Col=%d, Row=%d) | Pos: (%.0f, %.0f, %.0f)",
            MODNAME, self.state, entry and entry.label or "none", #grid_state.structures,
            grid_state.next_col, grid_state.next_row, pos.x, pos.y, pos.z
        )
        minetest.chat_send_player(pname, info)
    end,

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
        if puncher and puncher:is_player() then
            local pos = self.object:get_pos() or {x=0,y=0,z=0}
            local inv = puncher:get_inventory()
            if inv then
                local leftover = inv:add_item("main", ItemStack(MODNAME .. ":drone_spawner"))
                if leftover and not leftover:is_empty() then
                    minetest.add_item(pos, leftover)
                end
            end

            pcall(function()
                minetest.sound_play("default_tool_breaks", {pos = pos, gain = 0.6}, true)
            end)

            if grid_state.mcb_record and (self.state == "BUILDING" or self.state == "PRE_BUILD") and self.current_entry then
                minetest.chat_send_all("[mcb_stop]FILE:" .. tostring(self.current_entry.id))
            end

            self.object:remove()
            grid_state.drone_killed = true
            grid_state.last_drone_pos = nil
            save_grid_state()

            minetest.chat_send_player(puncher:get_player_name(),
                "[CityBuilderDrone] Drone recalled and returned to your inventory.")
        end
    end,
})

-- ============================================================
-- Spawner Craftitem / Spawn Egg (Single Drone Enforced)
-- ============================================================

local function spawn_drone(pos, player_name)
    local active, existing_drone = is_drone_already_active(nil)
    if active then
        if player_name then
            local drone_pos = nil
            if existing_drone and existing_drone.object then
                drone_pos = existing_drone.object:get_pos()
            end
            drone_pos = drone_pos or grid_state.last_drone_pos
            local loc_str = ""
            if drone_pos then
                local d = math.floor(vector.distance(pos, drone_pos))
                local dir = get_compass_direction(pos, drone_pos)
                loc_str = string.format(" at (X=%.0f, Y=%.0f, Z=%.0f) — %dm %s", drone_pos.x, drone_pos.y, drone_pos.z, d, dir)
            end
            minetest.chat_send_player(player_name,
                "[CityBuilderDrone] Only 1 drone allowed! Drone is currently active" .. loc_str .. ". Type /drone_find, /drone_tp, or /drone_recall.")
        end
        return false
    end

    grid_state.drone_killed = false
    local ground_surf = get_surface_y(pos.x, pos.z, pos.y)
    local ground_y = ground_surf - 1
    local spawn_pos = {x = pos.x, y = ground_y + 2.5, z = pos.z}
    local ent = minetest.add_entity(spawn_pos, MODNAME .. ":builder_drone")
    if ent then
        grid_state.last_drone_pos = {x = math.floor(spawn_pos.x), y = math.floor(spawn_pos.y), z = math.floor(spawn_pos.z)}
        save_grid_state()
        if player_name then
            minetest.chat_send_player(player_name,
                string.format("[CityBuilderDrone] Drone activated at (%.0f, %.0f, %.0f)! Beginning grid construction.",
                    spawn_pos.x, spawn_pos.y, spawn_pos.z))
        end
        return true
    end
    return false
end

minetest.register_craftitem(MODNAME .. ":drone_spawner", {
    description     = "City Builder Drone Spawner\nRight-click or place to deploy the autonomous city builder drone.",
    inventory_image = "menotics_llm_city_builder_drone_egg.png",
    stack_max       = 1,

    on_place = function(itemstack, user, pointed_thing)
        if not user or not user:is_player() then return itemstack end
        local pos = (pointed_thing and pointed_thing.above) or user:get_pos()
        local ok = spawn_drone(pos, user:get_player_name())
        if ok then
            itemstack:take_item()
        end
        return itemstack
    end,

    on_use = function(itemstack, user, pointed_thing)
        if not user or not user:is_player() then return itemstack end
        local pos = (pointed_thing and pointed_thing.above) or user:get_pos()
        local ok = spawn_drone(pos, user:get_player_name())
        if ok then
            itemstack:take_item()
        end
        return itemstack
    end,
})

-- Craft Recipe (Works with default or mcl_core)
local steel = find_existing_node({"default:steel_ingot", "mcl_core:iron_ingot"}) or "default:stone"
local copper = find_existing_node({"default:copper_ingot", "mcl_core:gold_ingot"}) or "default:stone"
local glass = find_existing_node({"default:glass", "mcl_core:glass"}) or "default:stone"

minetest.register_craft({
    output = MODNAME .. ":drone_spawner",
    recipe = {
        {copper, steel, copper},
        {steel,  glass, steel},
        {copper, steel, copper},
    }
})

-- ============================================================
-- Chat Commands
-- ============================================================

minetest.register_chatcommand("drone_spawn", {
    params      = "",
    description = "Spawn the single autonomous city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ok = spawn_drone(player:get_pos(), name)
        if ok then
            return true, "[CityBuilderDrone] Drone successfully deployed!"
        else
            return false, "[CityBuilderDrone] Deployment blocked: only 1 drone is allowed in the world."
        end
    end,
})

minetest.register_chatcommand("spawn_city_builder_drone", {
    params      = "",
    description = "Alias: Spawn the autonomous city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_spawn"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_kill", {
    params      = "",
    description = "Despawn / kill the city builder drone cleanly from the world.",
    privs       = {interact = true},
    func = function(name, param)
        local removed = 0
        for _, ent in pairs(minetest.luaentities) do
            if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
                if grid_state.mcb_record and (ent.state == "BUILDING" or ent.state == "PRE_BUILD") and ent.current_entry then
                    minetest.chat_send_all("[mcb_stop]FILE:" .. tostring(ent.current_entry.id))
                end
                local pos = ent.object:get_pos()
                if pos then
                    pcall(function()
                        minetest.sound_play("default_death", {pos = pos, gain = 0.5}, true)
                        minetest.add_particlespawner({
                            amount = 25,
                            time = 0.2,
                            minpos = vector.subtract(pos, 0.5),
                            maxpos = vector.add(pos, 0.5),
                            minvel = {x=-2, y=1, z=-2},
                            maxvel = {x=2, y=4, z=2},
                            minexptime = 0.5,
                            maxexptime = 1.0,
                            minsize = 1.5,
                            maxsize = 3.0,
                            texture = "menotics_landscaper_particle.png^[colorize:#ff3300:220",
                        })
                    end)
                end
                ent.object:remove()
                removed = removed + 1
            end
        end

        -- Ensure any unloaded drone entity self-destructs if its chunk is loaded later
        grid_state.drone_killed = true
        grid_state.last_drone_pos = nil
        save_grid_state()

        if removed > 0 then
            return true, string.format("[CityBuilderDrone] Drone cleanly removed (%d instance(s) killed).", removed)
        else
            return true, "[CityBuilderDrone] Drone cleanly killed. State reset to despawned."
        end
    end,
})

minetest.register_chatcommand("kill_drone", {
    params      = "",
    description = "Alias: Kill the city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_kill"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_stop", {
    params      = "",
    description = "Alias: Kill the city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_kill"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_despawn", {
    params      = "",
    description = "Alias: Kill the city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_kill"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("kill_city_builder_drone", {
    params      = "",
    description = "Alias: Despawn the city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_kill"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_status", {
    params      = "",
    description = "Display current drone position, grid progress, player proximity, and city stats.",
    func = function(name, param)
        local active_drone = nil
        local drone_pos = nil
        for _, ent in pairs(minetest.luaentities) do
            if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
                active_drone = ent
                drone_pos = ent.object:get_pos()
                break
            end
        end
        drone_pos = drone_pos or grid_state.last_drone_pos

        local total = #grid_state.structures
        local built = 0
        for _, s in ipairs(grid_state.structures) do if s.built then built = built + 1 end end

        local ready = can_call_api() and "Ready" or string.format("Cooling down (%.1fs)",
            CONFIG.openrouter.sleep_between_calls - (minetest.get_us_time()/1e6 - last_api_call_time))

        local player = minetest.get_player_by_name(name)
        local pos_str = "Unknown"
        local prox_str = "N/A"
        if drone_pos then
            pos_str = string.format("(X=%.0f, Y=%.0f, Z=%.0f)", drone_pos.x, drone_pos.y, drone_pos.z)
            if player then
                local d = math.floor(vector.distance(player:get_pos(), drone_pos))
                local dir = get_compass_direction(player:get_pos(), drone_pos)
                pos_str = pos_str .. string.format(" [%dm %s]", d, dir)
                local in_range = (CONFIG.builder.player_radius <= 0) or (d <= CONFIG.builder.player_radius)
                prox_str = in_range and "YES (in range)" or string.format("PAUSED (player > %dm away)", CONFIG.builder.player_radius)
            end
        end

        return true, string.format(
            "[CityBuilderDrone] Active: %s | State: %s | Pos: %s | Player Near: %s | Built: %d/%d | Grid Slot: (Col=%d, Row=%d) | DebugChat: %s | Record: %s | API: %s (%s)",
            active_drone and "YES" or "OFFLINE/UNLOADED",
            active_drone and (active_drone.waiting_for_player and "WAITING_FOR_PLAYER" or active_drone.state) or "IDLE",
            pos_str, prox_str,
            built, total,
            grid_state.next_col, grid_state.next_row,
            grid_state.mcb_debug and "ON" or "OFF",
            grid_state.mcb_record and "ON" or "OFF",
            ready, CONFIG.openrouter.model
        )
    end,
})

minetest.register_chatcommand("drone_find", {
    params      = "",
    description = "Locate the city builder drone, show coordinates/distance, and trigger a light beacon.",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ppos = player:get_pos()

        local active_drone = nil
        local drone_pos = nil
        for _, ent in pairs(minetest.luaentities) do
            if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
                active_drone = ent
                drone_pos = ent.object:get_pos()
                break
            end
        end
        drone_pos = drone_pos or grid_state.last_drone_pos

        -- Fallback to active grid center if no pos recorded yet
        if not drone_pos and grid_state.origin_x then
            local cx = grid_state.origin_x + (grid_state.next_col or 0) * CONFIG.grid.step
            local cz = grid_state.origin_z + (grid_state.next_row or 0) * CONFIG.grid.step
            drone_pos = {x = cx, y = (grid_state.origin_y or 10) + 7, z = cz}
        end

        if not drone_pos then
            return false, "[CityBuilderDrone] No drone active or recorded. Deploy one with /drone_spawn or the spawner egg!"
        end

        local dist = math.floor(vector.distance(ppos, drone_pos))
        local dir = get_compass_direction(ppos, drone_pos)

        -- Fire a glowing beacon pillar into the sky so player can easily spot it
        if active_drone and active_drone.object then
            spawn_drone_beacon(drone_pos)
            for step = 1, 4 do
                minetest.after(step * 0.8, function()
                    if active_drone and active_drone.object and active_drone.object:get_pos() then
                        spawn_drone_beacon(active_drone.object:get_pos())
                    end
                end)
            end
        end

        return true, string.format(
            "[CityBuilderDrone] Drone located at (X=%.0f, Y=%.0f, Z=%.0f) — %dm %s! (Beacon activated in sky). Use /drone_tp to teleport there or /drone_recall to bring it to you.",
            drone_pos.x, drone_pos.y, drone_pos.z, dist, dir
        )
    end,
})

minetest.register_chatcommand("find_drone", {
    params = "",
    description = "Alias: Locate the city builder drone.",
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_find"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_where", {
    params = "",
    description = "Alias: Locate the city builder drone.",
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_find"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_tp", {
    params      = "",
    description = "Teleport directly to the city builder drone.",
    privs       = {interact = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end

        if grid_state.drone_killed then
            return false, "[CityBuilderDrone] Drone is not active (despawned/killed). Deploy one with /drone_spawn or the spawner egg!"
        end

        local active_drone = nil
        local target_pos = nil
        for _, ent in pairs(minetest.luaentities) do
            if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
                active_drone = ent
                target_pos = ent.object:get_pos()
                break
            end
        end
        target_pos = target_pos or grid_state.last_drone_pos
        if not target_pos and grid_state.origin_x then
            local cx = grid_state.origin_x + (grid_state.next_col or 0) * CONFIG.grid.step
            local cz = grid_state.origin_z + (grid_state.next_row or 0) * CONFIG.grid.step
            target_pos = {x = cx, y = (grid_state.origin_y or 10) + 7, z = cz}
        end

        if not target_pos then
            return false, "[CityBuilderDrone] No drone found. Use /drone_spawn to deploy one!"
        end

        -- Safe teleport destination:
        -- If player has fly priv, teleport right beside the drone in midair.
        -- Otherwise, place the player on safe ground near the drone to prevent fall damage.
        local privs = minetest.get_player_privs(name)
        local dest_pos = nil
        if privs and privs.fly then
            dest_pos = {x = target_pos.x + 1.5, y = target_pos.y + 0.5, z = target_pos.z + 1.5}
        else
            local ground_y = get_surface_y(target_pos.x, target_pos.z, target_pos.y)
            if ground_y and ground_y > -30000 then
                dest_pos = {x = target_pos.x + 2.0, y = ground_y + 0.5, z = target_pos.z + 2.0}
            else
                dest_pos = {x = target_pos.x, y = target_pos.y + 1.0, z = target_pos.z}
            end
        end

        player:set_pos(dest_pos)

        -- Trigger beacon light pillar so player can immediately spot the drone
        spawn_drone_beacon(target_pos)

        return true, string.format(
            "[CityBuilderDrone] Teleported to drone at (X=%.0f, Y=%.0f, Z=%.0f)!",
            target_pos.x, target_pos.y, target_pos.z
        )
    end,
})

-- Common teleport aliases
local tp_aliases = {
    "tp_drone",
    "tpdrone",
    "dronetp",
    "drone_teleport",
    "teleport_drone",
    "teleport_to_drone",
    "tptodrone",
    "drone_goto",
    "goto_drone",
}

for _, alias in ipairs(tp_aliases) do
    minetest.register_chatcommand(alias, {
        params      = "",
        description = "Alias: Teleport to the city builder drone.",
        privs       = {interact = true},
        func = function(name, param)
            local cmd = minetest.registered_chatcommands["drone_tp"]
            if cmd then return cmd.func(name, param) end
        end,
    })
end

-- Master /drone chat command with subcommands
minetest.register_chatcommand("drone", {
    params      = "<tp|find|status|recall|spawn|kill|reset_grid|record|debug>",
    description = "City builder drone command interface. (e.g. '/drone tp' to teleport to drone)",
    func = function(name, param)
        param = (param or ""):match("^%s*(.-)%s*$")
        local subcmd, rest = param:match("^(%S+)%s*(.*)$")
        subcmd = subcmd and subcmd:lower() or ""

        if subcmd == "tp" or subcmd == "teleport" or subcmd == "goto" then
            local cmd = minetest.registered_chatcommands["drone_tp"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "find" or subcmd == "where" or subcmd == "locate" then
            local cmd = minetest.registered_chatcommands["drone_find"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "status" or subcmd == "info" then
            local cmd = minetest.registered_chatcommands["drone_status"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "recall" or subcmd == "bring" then
            local cmd = minetest.registered_chatcommands["drone_recall"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "spawn" then
            local cmd = minetest.registered_chatcommands["drone_spawn"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "kill" or subcmd == "despawn" or subcmd == "stop" then
            local cmd = minetest.registered_chatcommands["drone_kill"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "reset_grid" or subcmd == "reset" then
            local cmd = minetest.registered_chatcommands["drone_reset_grid"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "record" then
            local cmd = minetest.registered_chatcommands["drone_record"]
            if cmd then return cmd.func(name, rest) end
        elseif subcmd == "debug" then
            local cmd = minetest.registered_chatcommands["drone_debug"]
            if cmd then return cmd.func(name, rest) end
        else
            return true, "[CityBuilderDrone] Available Commands:\n"
                .. "  /drone tp          - Teleport directly to the drone\n"
                .. "  /drone find        - Show drone coordinates/distance & sky beacon\n"
                .. "  /drone recall      - Bring the drone to your current position\n"
                .. "  /drone status      - View drone state, grid slot, and city progress\n"
                .. "  /drone spawn       - Deploy the drone\n"
                .. "  /drone kill        - Despawn/remove the drone\n"
                .. "  Direct shortcuts: /drone_tp, /tp_drone, /tp drone, /teleport drone"
        end
    end,
})

-- Intercept '/tp drone' and '/teleport drone'
local function hook_teleport_cmd(cmd_name)
    local def = minetest.registered_chatcommands[cmd_name]
    if def and not def._drone_tp_hooked then
        local old_func = def.func
        minetest.override_chatcommand(cmd_name, {
            _drone_tp_hooked = true,
            func = function(name, param)
                local clean = (param or ""):lower():match("^%s*(.-)%s*$")
                if clean == "drone" or clean == "to drone" or clean == "the drone" or clean == "builder_drone" then
                    local drone_cmd = minetest.registered_chatcommands["drone_tp"]
                    if drone_cmd then
                        return drone_cmd.func(name, "")
                    end
                end
                if old_func then
                    return old_func(name, param)
                end
            end,
        })
    end
end

hook_teleport_cmd("teleport")
hook_teleport_cmd("tp")

minetest.register_on_mods_loaded(function()
    hook_teleport_cmd("teleport")
    hook_teleport_cmd("tp")
end)

minetest.register_chatcommand("drone_recall", {
    params      = "",
    description = "Recall / bring the city builder drone directly to your current position.",
    privs       = {interact = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ppos = player:get_pos()

        -- Remove any existing drone entity to prevent duplicates
        for _, ent in pairs(minetest.luaentities) do
            if ent and ent.name == MODNAME .. ":builder_drone" and ent.object then
                ent.object:remove()
            end
        end

        local ok = spawn_drone(ppos, name)
        if ok then
            return true, string.format(
                "[CityBuilderDrone] Drone recalled to your position (%.0f, %.0f, %.0f)!",
                ppos.x, ppos.y, ppos.z
            )
        else
            return false, "[CityBuilderDrone] Failed to recall drone."
        end
    end,
})

minetest.register_chatcommand("recall_drone", {
    params = "",
    description = "Alias: Recall the city builder drone.",
    privs = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_recall"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_reset_grid", {
    params      = "",
    description = "Reset grid coordinates to your current player position. Requires 'server' priv.",
    privs       = {server = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local ppos = player:get_pos()
        grid_state.origin_x = math.floor(ppos.x)
        grid_state.origin_y = math.floor(ppos.y)
        grid_state.origin_z = math.floor(ppos.z)
        grid_state.next_col = 0
        grid_state.next_row = 0
        save_grid_state()
        return true, string.format(
            "[CityBuilderDrone] Grid origin reset to (X=%d, Y=%d, Z=%d). Next slot is (Col=0, Row=0).",
            grid_state.origin_x, grid_state.origin_y, grid_state.origin_z
        )
    end,
})

minetest.register_chatcommand("drone_reload", {
    params      = "",
    description = "Reload ollama.json / openrouter.json configuration without restarting server.",
    privs       = {server = true},
    func = function(name, param)
        local source = load_config()
        return true, string.format(
            "[CityBuilderDrone] Config reloaded! Endpoint: %s | Model: %s | Timeout: %ds (Source: %s)",
            CONFIG.openrouter.api_url, CONFIG.openrouter.model, CONFIG.openrouter.timeout, source or "defaults"
        )
    end,
})

minetest.register_chatcommand("drone_config", {
    params      = "",
    description = "Alias: Reload drone configuration.",
    privs       = {server = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["drone_reload"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("mcb_debug", {
    params      = "<on|off>",
    description = "Toggle city builder drone debug chat messages (default: off).",
    privs       = {interact = true},
    func = function(name, param)
        local p = (param or ""):match("^%s*(.-)%s*$"):lower()
        if p == "on" or p == "1" or p == "true" then
            grid_state.mcb_debug = true
        elseif p == "off" or p == "0" or p == "false" then
            grid_state.mcb_debug = false
        elseif p == "" then
            grid_state.mcb_debug = not grid_state.mcb_debug
        else
            return false, "Usage: /mcb_debug <on|off>"
        end
        save_grid_state()
        return true, string.format("[CityBuilderDrone] Debug chat messages: %s", grid_state.mcb_debug and "ON" or "OFF")
    end,
})

minetest.register_chatcommand("drone_debug", {
    params      = "<on|off>",
    description = "Alias: Toggle drone debug chat messages.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["mcb_debug"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("mcb_record", {
    params      = "<on|off>",
    description = "Toggle video recording signals [mcb_start] / [mcb_stop] (default: on).",
    privs       = {interact = true},
    func = function(name, param)
        local p = (param or ""):match("^%s*(.-)%s*$"):lower()
        if p == "on" or p == "1" or p == "true" then
            grid_state.mcb_record = true
        elseif p == "off" or p == "0" or p == "false" then
            grid_state.mcb_record = false
        elseif p == "" then
            grid_state.mcb_record = not grid_state.mcb_record
        else
            return false, "Usage: /mcb_record <on|off>"
        end
        save_grid_state()
        return true, string.format("[CityBuilderDrone] Record mode ([mcb_start]/[mcb_stop]): %s", grid_state.mcb_record and "ON" or "OFF")
    end,
})

minetest.register_chatcommand("mcb_revord", {
    params      = "<on|off>",
    description = "Alias: Toggle video recording signals (common typo support).",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["mcb_record"]
        if cmd then return cmd.func(name, param) end
    end,
})

minetest.register_chatcommand("drone_record", {
    params      = "<on|off>",
    description = "Alias: Toggle drone video recording signals.",
    privs       = {interact = true},
    func = function(name, param)
        local cmd = minetest.registered_chatcommands["mcb_record"]
        if cmd then return cmd.func(name, param) end
    end,
})

-- ============================================================
-- Initialization
-- ============================================================

load_config()
load_structures()
load_grid_state()

minetest.log("action", "[" .. MODNAME .. "] v1.0.0 loaded successfully.")
