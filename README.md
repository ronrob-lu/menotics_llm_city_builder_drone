# Menotics LLM City Builder Drone

Autonomous city-building drone mod for **Luanti / Minetest** (compatible with Minetest Game, MineClone2, and VoxeLibre).

Powered by local **Ollama** (or **OpenRouter** / any OpenAI-compatible API). An autonomous flying drone plans procedurally designed voxel structures and constructs them on a clean, exact **100-block grid** in **~30 seconds** per structure, with green construction lasers, dynamic material adaptation, and automated video title metadata logging.

---

## Key Features

- **Autonomous Flying Drone** — Replaces ground NPCs with a smooth-flying drone equipped with glowing thrust flame particles and neon-green laser construction beams.
- **No Nametag & No Terminal** — Operates completely autonomously without terminal blocks or obstructive floating nametags.
- **Ollama & OpenAI-Compatible API** — Fully compatible with Ollama's Chat Completions endpoint (`http://<ip>:11434/v1/chat/completions`) and OpenRouter. Supports long timeouts (`timeout: 300`+) for heavy local LLMs.
- **Strict 100-Block Grid** — Eliminates street clutter and search delays. Structures are placed exactly 100 blocks apart (center-to-center). When a row reaches its limit (default: 10 structures), the drone creates a second row.
- **~30-Second Dynamic Build Speed** — Block pacing dynamically adjusts so any structure finishes in approximately 30 seconds with continuous laser animations and sound effects.
- **Single Drone Enforcement** — Strictly allows only one drone in the world at a time.
- **Chat Announcements** — Broadcasts `Planning completed` (with architectural rationale) and `Structure end` to chat.
- **Structure Metadata for Video Titles** — Automatically creates `<world>/structure-meta/{id}.txt` for every build, containing dimensions, coordinates, LLM architectural descriptions, and ready-to-use YouTube video title suggestions.
- **Dynamic Material Resolution** — No bundled `ky_materials` required! If `ky_materials` is installed separately, it uses it; otherwise it automatically maps materials to standard nodes from `default:` (Minetest Game) or `mcl_core:` (MineClone2 / VoxeLibre).

---

## Installation

1. Copy the `menotics_llm_city_builder_drone` directory into your Luanti/Minetest `mods/` directory.
2. Enable the mod in your world configuration or add `load_mod_menotics_llm_city_builder_drone = true` to `world.mt`.
3. Add the mod to `secure.http_mods` in your `minetest.conf`:
   ```ini
   secure.http_mods = menotics_llm_city_builder_drone
   ```
   *(Required for HTTP communication with Ollama / OpenRouter).*

---

## Configuration

Copy `openrouter.example.json` to your world folder as **`<world_folder>/openrouter.json`** or **`<world_folder>/ollama.json`**:

### Example: Local or Networked Ollama
```json
{
  "api_url": "http://127.0.0.1:11434/v1/chat/completions",
  "api_key": "ollama",
  "model": "qwen2.5-coder:latest",
  "temperature": 0.7,
  "timeout": 300,
  "sleep_between_calls": 5.0,
  "grid_step": 100,
  "grid_row_length": 10,
  "build_duration": 30.0,
  "max_structures": 0
}
```

### Example: OpenRouter
```json
{
  "api_url": "https://openrouter.ai/api/v1/chat/completions",
  "api_key": "sk-or-v1-YOUR_KEY_HERE",
  "model": "openai/gpt-oss-20b",
  "temperature": 0.7,
  "timeout": 90,
  "sleep_between_calls": 10.0,
  "grid_step": 100,
  "grid_row_length": 10,
  "build_duration": 30.0
}
```

| Setting | Default | Description |
|---|---|---|
| `api_url` | `http://127.0.0.1:11434/v1/chat/completions` | OpenAI-compatible Chat Completions endpoint. |
| `api_key` | `"ollama"` | Bearer token (`"ollama"` for local Ollama). |
| `model` | `"qwen2.5-coder:latest"` | LLM model name. |
| `timeout` | `300` | HTTP fetch and AI planning timeout in seconds. |
| `sleep_between_calls` | `5.0` | Minimum cooldown between builds. |
| `grid_step` | `100` | Center-to-center distance between structures in blocks. |
| `grid_row_length` | `10` | Number of structures per row before wrapping to the next row. |
| `build_duration` | `30.0` | Target time in seconds to erect the full structure. |
| `max_structures` | `0` | City limit (0 = unlimited). |

---

## How It Works

1. **Deployment**: Spawn the drone using the craftable Drone Spawner Egg or `/drone_spawn`.
2. **Grid Anchoring**: On first spawn, the drone sets its origin `(X0, Y0, Z0)` at its current position.
3. **Planning**: The drone calls Ollama to generate a voxel structure plan. When ready, it announces:
   `[CityBuilderDrone] Planning completed: <Label> (ID: structure_001) — "<Description>"`
4. **Metadata Log**: The mod immediately writes `<world>/structure-meta/structure_001.txt` with video title ideas.
5. **Fast 30s Build**: The drone moves over the build area, shooting green laser beams and placing all blocks in ~30 seconds.
6. **Structure End**: The drone announces:
   `[CityBuilderDrone] Structure end: <Label> (ID: structure_001)`
7. **Grid Advance**: The drone flies 100 blocks away to slot `(Col=1, Row=0)`. When `Col=10` is reached, it creates `Row=1` (stepping 100 blocks in Z) and resets `Col=0`.

---

## In-Game Commands

| Command | Privileges | Description |
|---|---|---|
| `/drone_tp` or `/tp_drone` | `interact` | Teleport directly to the city builder drone (safely lands you near drone and lights up sky beacon). Also supports `/tp drone`, `/teleport drone`, `/drone tp`. |
| `/drone_find` or `/drone_where` | none | Locate the drone, display distance/compass bearing, and fire a glowing light beacon into the sky. |
| `/drone_recall` or `/recall_drone` | `interact` | Bring the drone directly to your current position. |
| `/drone [subcommand]` | `interact` | Drone command interface (`/drone tp`, `/drone find`, `/drone recall`, `/drone status`, `/drone spawn`, `/drone kill`). |
| `/drone_spawn` | `interact` | Deploy the autonomous city builder drone (enforces 1-drone limit). |
| `/drone_kill` | `interact` | Despawn the drone. |
| `/drone_status` | none | View drone state, active grid slot, debug/record toggles, and city progress. |
| `/drone_reset_grid` | `server` | Reset the grid origin to your current position. |
| `/mcb_debug <on\|off>` | `interact` | Toggle drone debug chat messages (default: `off`). All muted chat produces zero `debug.txt` output. |
| `/mcb_record <on\|off>` | `interact` | Toggle video recording triggers (default: `on`). Sends `[mcb_start]FILE:structure_001` 1s before building and `[mcb_stop]FILE:structure_001` 2s after completion. |

---

## Crafting Recipe

The Drone Spawner is craftable with standard vanilla materials:

| | Recipe | |
|:---:|:---:|:---:|
| Copper / Gold | Steel / Iron | Copper / Gold |
| Steel / Iron | Glass | Steel / Iron |
| Copper / Gold | Steel / Iron | Copper / Gold |

---

## Structure Metadata Output

Every completed plan creates a text report inside `<world_folder>/structure-meta/<id>.txt`:

```text
============================================================
STRUCTURE METADATA REPORT
============================================================
Structure ID:       structure_001
Name / Label:       Two-Story House with Garden
Structure Type:     two_story_house_with_garden
Target Dimensions:  Width=9, Depth=9, Height=10
Total Blocks:       342
Grid Position:      Row 0, Column 0
Grid Center:        (X=100, Y=12, Z=0)
Timestamp:          2026-09-02 20:30:00Z
Model / AI Engine:  qwen2.5-coder:latest

============================================================
ARCHITECTURAL SUMMARY
============================================================
Two-story residential townhouse with hollow open floors, flat roof, and garden yard.

============================================================
VIDEO TITLE GENERATION IDEAS
============================================================
1. Autonomous Drone Builds Two-Story House with Garden in Luanti | Ollama AI Voxel City #structure_001
2. I Built an AI Drone that Constructs Two-Story House with Garden Block-by-Block
3. Two-Story House with Garden Built in 30 Seconds by Autonomous Builder Drone!
4. AI City Construction Drone: Two-Story House with Garden (Structure ID: structure_001)
```

---

## License

MIT License 2026, ronrob-lu, Antigravity
