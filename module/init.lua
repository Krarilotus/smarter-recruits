--[[
  Smarter Recruits

  Four changes around recruiting, each a setting of its own:

  1. Horse archers shoot on the way to their rally point and react once they are there.
     The game sends a fresh recruit to its rally point in a state (0x69) of its own. For
     horse archers that state never looks for enemies while walking, and on arrival it puts
     them into "shooting" without choosing a shot, which the shooting routine treats as
     "nothing to do" - so they stood there for good. Walking now runs the same shoot-on-the-
     move check as an ordinary move order, and the shooting state starts a shot when none is
     chosen.
  2. A recruit that is given a move order forgets its rally point. A recruit carries a
     "go to the rally point" flag until its first idle tick; a move order given before that
     left it set, so the unit walked on to the rally point once it reached its new spot.
  3. A stance button in the recruiting buildings: recruits of the player start in the chosen
     stance (normal, defensive or aggressive). The game keeps a stance per group of units
     and only gives a fresh unit a group of its own in scenarios, so in a skirmish a fresh
     recruit of the player gets one too while a stance is chosen. Single player only.
  4. A rally point button on every portrait in the barracks, mercenary post, engineer's
     guild, tunneler's guild and cathedral. It does what that unit's number key does: the
     next click on the map places the unit's rally point.

  The buttons are not new menu items. The portraits' own click and draw functions are
  wrapped: the wrapper draws the buttons over the portrait and a click inside one of them
  is handled here, anywhere else on the portrait recruits as before. That leaves the item
  list of the building menu alone, which other modules (automarket) index by position.

  Pictures are PNG files in images/ and can be replaced (see locale/description-en.md).

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local templates = require("templates")
local png = require("png")

local MODULE_NAME = "smarter-recruits"
local MODULE_FOLDERS = { "ucp/modules/smarter-recruits/" }   -- UCP maps this to the active version

local DEFAULTS = {
  horse_archers = { shoot_on_the_way = true, ride_on = true },
  rally = { keep_new_orders = true, buttons = true, fight_on_the_way = true, follow_changes = true,
    run_when_aggressive = true, terrain_speed = true, monks_fix = true },
  stance = { button = true, start = "normal" },
  debug = { log = false },
}

local STANCES = { normal = 0, defensive = 1, aggressive = 2 }

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- UpdateHorseArcher. The function is byte for byte the same in both exes apart from its
-- operands, so offsets into it hold for both.
local AOB_HORSE_ARCHER = "51 8B 15 ? ? ? ? 8B C2 69 C0 90 04 00 00 83 B8 ? ? ? ? 00 53 55 0F BF "
  .. "A8 ? ? ? ? 56 57 75 0A C7 80 ? ? ? ? ? 00 00 00 8B FD 69"
local HA_TRIBES_OPERAND = 0x5F           -- mov ecx, TribesState (before addUnitToNewTribe)
local HA_STATE_OPERAND = 0x8B            -- movsx eax, word [esi + unit.state]
local HA_WALKING_JUMP = 0x213            -- state 0x69: je "not there yet" (0F 84 rel32)
local HA_AT_RALLY = 0x22A                -- state 0x69, arrived: mov word [esi+facing],4 ...
local HA_AT_RALLY_SIZE = 13              -- ... test edx,edx / jne "not the 40th tick"
local HA_AT_RALLY_REPLAYED = 9
local HA_RALLY_CONTINUE = 0x237          -- the 40th tick: look for enemies
local HA_RALLY_COUNT = 0x2AB             -- add dword [edi + rally counter], 1
local HA_TAIL = 0x2B2                    -- pop edi / esi / ebp / ebx / ecx; ret
local HA_WALK_SHOOT = 0x3BE              -- state 0x65, still walking: the shoot-on-the-move check
local HA_SHOOTING_STATE = 0x80E          -- state 4: mov dword [esi + anim], 0 (10 bytes)
local HA_SHOOTING_STATE_SIZE = 10
local HA_DO_SHOOTING = 0x818             -- call UpdateHorseArcher_DoShooting
local HA_FREE_TO_REACT = 0x1E8           -- state 0x69: mov word [esi + unit+0x3FC], ax
local HA_FREE_TO_REACT_SIZE = 7
local HA_REPATH = 0x273                  -- state 0x69: mov ebx, [unit] / look up the rally point
local HORSE_ARCHER = 74
local HA_GUARDS = {
  [HA_WALKING_JUMP] = { 0x0F, 0x84 },
  [HA_AT_RALLY] = { 0x66, 0xC7, 0x86 },
  [HA_AT_RALLY + 9] = { 0x85, 0xD2, 0x75 },
  [HA_RALLY_COUNT] = { 0x83, 0x87 },
  [HA_TAIL] = { 0x5F, 0x5E, 0x5D, 0x5B, 0x59, 0xC3 },
  [HA_WALK_SHOOT] = { 0x66, 0x83, 0x86 },
  [HA_SHOOTING_STATE - 1] = { 0x53, 0xC7, 0x86 },
  [HA_DO_SHOOTING] = { 0xE8 },
  [HA_FREE_TO_REACT] = { 0x66, 0x89, 0x86 },
  [HA_REPATH] = { 0x8B, 0x1D },
}

-- TribesState::giveTribeMoveInstruction, at `mov word [esi + unit.state], 0x65`.
local AOB_MOVE_ORDER = "39 6C 24 14 0F BF F9 66 C7 86 ? ? ? ? 65 00 66 89 AE ? ? ? ? 89 AE ? ? ? "
  .. "? 74 0C C7"
local MOVE_ORDER_OFFSET = 7
local MOVE_ORDER_SIZE = 9

-- TribesState::addUnitToNewTribe.
local AOB_NEW_GROUP = "83 3D ? ? ? ? 00 56 8B F1 74 06 33 C0 5E C2 04 00 57 8B 7C 24 0C 69 FF 90 "
  .. "04 00 00 0F BF 8F ? ? ? ? 83 3C 8D"
local NEW_GROUP_MODE_OPERAND = 2         -- cmp dword [currentGameMode], 0
local NEW_GROUP_ENTRY_SIZE = 7
local NEW_GROUP_OWNER_OPERAND = 0x20     -- movsx ecx, word [edi + unit.owner]
local NEW_GROUP_STANCE_HOOK = 0x2A4      -- push eax / mov eax, [esp+0x10]
local NEW_GROUP_PLAYER_CHECK = 0x24      -- cmp dword [owner*4 + network ids], -1 (8 bytes)
local NEW_GROUP_PLAYER_CHECK_SIZE = 8
local NEW_GROUP_STANCE_SIZE = 5
local NEW_GROUP_GUARDS = {
  [NEW_GROUP_STANCE_HOOK] = { 0x50, 0x8B, 0x44, 0x24, 0x10, 0x50, 0x8B, 0xCE, 0xE8 },
  [NEW_GROUP_PLAYER_CHECK] = { 0x83, 0x3C, 0x8D },
  [NEW_GROUP_PLAYER_CHECK + 7] = { 0xFF, 0x0F, 0x85 },
}

-- TribesState::removeUnitFromTribe(unit, group): takes a unit out of a group.
local AOB_REMOVE_FROM_GROUP = "53 55 56 8B 74 24 10 8B D9 8B CE 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 00 57 "
  .. "8B 7C 24 18 75 39"

-- UnitsState::findNearestEnemyAndHeadTowardsIt, where it reads a group's stance. Gives the
-- stance's offset in a group (the group size differs between the exes).
local AOB_STANCE_READ = "0F BF 84 37 EC 08 00 00 3B C3 74 34 69 C0 ? ? ? ? 0F BF 88 ? ? ? ? 0F BF "
  .. "80 ? ? ? ?"
local STANCE_READ_OPERAND = 0x1C

-- MenuItemActionHandler_General_ToolbarButtonPressed: what the number keys call in a
-- recruiting building. Read for the local player and the click sound. Found by a pattern
-- 0x1B bytes in, because improved-tunnelers puts a jump over the first 9 bytes.
local AOB_TOOLBAR = "A1 ? ? ? ? 8B C8 69 C9 F4 39 00 00 39 99 ? ? ? ? 74 18 39 1D ?"
local TOOLBAR_PATTERN_OFFSET = 0x1B
local TOOLBAR_LOCAL_PLAYER = { 0x1B, { 0xA1 } }
local TOOLBAR_SOUND_ID = { 0x227, { 0x68 } }
local TOOLBAR_SOUNDS = { 0x22C, { 0xB9 } }
local TOOLBAR_PLAY_SOUND = 0x23D

-- The Save dialog's file name box renderer: the item rectangle globals and the pencil.
local AOB_NAME_BOX = "A1 ? ? ? ? 8B 0D ? ? ? ? 8B 15 ? ? ? ? 56 57 6A 05 03 C8 51 8B 0D ? ? ? ? 03 "
  .. "D1 52 50 51 B9 ? ? ? ?"
local NAME_BOX = {
  itemY = { 0x00, { 0xA1 } },
  itemHeight = { 0x05, { 0x8B, 0x0D } },
  itemWidth = { 0x0B, { 0x8B, 0x15 } },
  itemX = { 0x18, { 0x8B, 0x0D } },
  pencil = { 0x23, { 0xB9 } },
}
local NAME_BOX_DRAW_COLOUR_BOX = 0x69
local NAME_BOX_TEXT_MANAGER = { 0x9C, { 0xB9 } }
local NAME_BOX_SHADOWED_TEXT = 0xA1      -- call renderInGameTextWithShadow
local DRAW_COLOUR_BOX_SURFACE = 0x03     -- call setupPencilSurface
local DRAW_COLOUR_BOX_CLIP = 0x23        -- call setupPencil

-- handleMenuElementsCallbacks, where it asks whether the mouse is over an item: the mouse
-- and its "is the mouse in this box" test. (The ui module patches the function's start.)
local AOB_MENU_ITEM = "8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 "
  .. "B9 ? ? ? ? E8"
local MENU_ITEM_MOUSE = { 0x19, { 0xB9 } }
local MENU_ITEM_IS_INSIDE = 0x1E

-- The screen's pixel format (0x565 or 0x555).
local AOB_PIXEL_FORMAT = "81 3D ? ? ? 00 65 05 00 00 75 40"
local PIXEL_FORMAT_OPERAND = 2

-- Unit offsets in UnitsState.units (stride 0x490).
local UNIT_OWNER = 0x96
local UNIT_GO_TO_RALLY_POINT = 0xB0
local UNIT_STATE = 0x2C0
local UNIT_SHOOTING_VARIATION = 0x424

local SKIRMISH_MODE = 0x63

-- updateUnits, where it decides whether a unit is due to look for enemies: the third operand
-- is the game's tick counter.
local AOB_TICK_COUNTER = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15 ? ? ? ?"
local TICK_COUNTER_OPERAND = 14
local DUMP_EVERY = 120                   -- three seconds at normal speed

-- updateUnits, where it calls the unit's own update function:
-- mov ecx,eax / imul ecx,ecx,0x490 / add ecx,esi / cmp word [ecx+logicalState],4 / je.
-- The hook takes the `cmp` (8 bytes); the call that follows is left for other modules.
local AOB_UNIT_UPDATE = "8B C8 69 C9 90 04 00 00 03 CE 66 83 B9 A0 06 00 00 04 74 15"
local UNIT_UPDATE_HOOK = 0x0A
local UNIT_UPDATE_HOOK_SIZE = 8
-- ... and right after it calls the unit's update function (`call eax`): `mov eax, [current unit]`.
local UNIT_UPDATED_HOOK = 0x24
local UNIT_UPDATED_GUARDS = { [0x22] = { 0xFF, 0xD0 }, [0x24] = { 0xA1 } }
local UNIT_UPDATED_HOOK_SIZE = 5
local UNIT_ANIMATION_SHEET = 0x08         -- 1 = walking sheet, 0x81 = running sheet
local UNIT_STATE_SPEED = 0x2BE            -- stateBasedSpeed: -1 stands, 0 walks, 1 runs, 2 gallops
-- Recruits that can run, as their walking state (0x65) makes them: { animation sheet, speed }.
-- The others (crossbowmen, pikemen, swordsmen, assassins, Arab swordsmen, fire throwers,
-- horse archers, engineers, laddermen, tunnelers) only ever walk there. Same in both exes.
local RUNS = {
  [22] = { 0x81, 1 }, [24] = { 0x81, 1 }, [26] = { 0x81, 1 }, [28] = { 0x81, 2 },
  [70] = { 0x81, 1 }, [71] = { 1, 1 }, [72] = { 0x81, 1 }, [37] = { 0x81, 1 },
}
local STANCE_READ_TRIBE_SIZE = 0x0E      -- imul eax, eax, <group size>
local UNITS_STATE_TO_UNITS = 0x614        -- unit fields relative to UnitsState
local UNIT_TYPE = 0x8E
local UNIT_MOVE_STATUS = 0xF6
local UNIT_RESUME_X = 0xF0
local UNIT_RESUME_Y = 0xF2
local UNIT_TRIBE = 0x2D8
local UNIT_MOVEMENT_TYPE = 0x346
local UNIT_SELECTED = 0x34
local UNIT_LOGICAL_STATE = 0x8C
local UNIT_UID = 0x98
local UNIT_FREE_TO_REACT = 0x3FC
local UNIT_TARGETING = 0x39C
local IDLE_TICKS = 40                     -- a second at normal speed
local STILL_TICKS = 40                    -- on the same tile this long = standing, not walking
local UNIT_POSITION = 0xC4                -- tile x, y (two words)
-- Each recruit's idle states (state 0 and the ones whose code starts with unit +0x2AC = 0xA,
-- the same in both exes; archers also rest in 7 and 8 between their idle animations).
local IDLE_STATES = {
  [22] = { 0, 7, 8, 11 }, [23] = { 0, 1, 2 }, [24] = { 0, 1, 6 }, [25] = { 0, 1, 2, 3 },
  [26] = { 0, 1, 2, 3 }, [27] = { 0, 1, 3 }, [28] = { 0, 1, 3 }, [70] = { 0, 7, 8, 11 },
  [71] = { 0, 1 }, [72] = { 0, 8, 11 }, [73] = { 0, 1 }, [74] = { 0, 1 }, [75] = { 0, 1, 3 },
  [76] = { 0, 8, 11 }, [30] = { 0, 1 }, [29] = { 0, 1, 2 }, [5] = { 0, 1 }, [37] = { 0, 1, 2 },
}
local TRIBE_COUNT = 0x5C                  -- a group's member count
local TRIBE_UID = 0x34                    -- a group's uid; unit +0x2E4 holds its group's
local TRIBE_ACTIVE = 0x40
local UNIT_TRIBE_UID = 0x2E4
-- Unit types whose walking state looks for enemies by stance only on a route (their update
-- sets unit +0x3FC there when the group's patrol flag is set): the melee recruits.
local REACTS_ON_ROUTE = { 24, 25, 26, 27, 28, 37, 71, 73, 75 }
local MARK_COUNT = 0x4000
-- Rally slot per unit type: the counter at PlayerData + 0x2A00 + slot * 4.
local RALLY_SLOTS = {
  [22] = 0, [23] = 1, [24] = 2, [26] = 3, [25] = 4, [27] = 5, [28] = 6,
  [70] = 10, [74] = 11, [71] = 12, [73] = 13, [72] = 14, [76] = 15, [75] = 16,
}
local HORSE_ARCHER_SLOT = 11
-- The walking state's stance test of archers, crossbowmen, Arab archers (owner from the
-- stack: ecx) and of slingers and fire throwers (owner in ebp): cmp [owner*4 + ids], reg.
local RANGED_WALK_CHECKS = {
  { pattern = "75 0F 8B 4C 24 10 39 ? 8D ? ? ? ? 75", offset = 6, count = 3 },
  { pattern = "66 39 ? ? ? ? ? 75 ? 39 ? AD ? ? ? ? 75", offset = 9, count = 2 },
}
local RANGED_WALK_CHECK_COUNT = 5
-- After the first of those tests (the archer's): the walking state's own "shoot at what is in
-- range" - fixedRng, UnitsState, acquireShootTarget(unit), shootTargetedUnit, TribesState,
-- giveTribeAnInstruction(group, what, target, uid, 0).
local WALK_SHOT = {
  rng = { at = 0x1F, bytes = { 0x8B, 0x86 }, field = 0x384 },
  unitsState = { at = 0x30, bytes = { 0xB9 } },
  acquire = 0x35,
  target = { at = 0x4C, bytes = { 0x0F, 0xBF, 0x88 }, field = 0x344 },
  tribeState = { at = 0x73, bytes = { 0xB9 } },
  instruction = 0x78,
}
-- The ranged units a recruit stance makes stop and shoot on the way (horse archers shoot
-- while riding instead).
local SHOOTS_ON_THE_WAY = { 22, 23, 70, 72, 76 }

---------------------------------------------------------------------------------------
-- The recruit portraits
---------------------------------------------------------------------------------------

-- MenuItem layout (0x50 bytes).
local ITEM_SIZE = 0x50
local ITEM_TYPE = 0x00
local ITEM_ACTION = 0x14
local ITEM_PARAM = 0x18
local ITEM_X = 0x04
local ITEM_Y = 0x08
local ITEM_RENDER = 0x1C
local TYPE_GROUP = 0x01000000
local TYPE_MEMBER = 0x02000000
local TYPE_EVERY_FRAME = 0x00
local TYPE_BLOCK = 0x64
local TYPE_LAST = 0x66
local MOUSE_LEFT_CLICK = 0x34            -- set for the frame in which the left button went down

-- Each building's portrait group is found by its first member: (x, y, unit type). The
-- member before it is the group header.
local BUILDINGS = {
  { name = "barracks", x = 86, y = 433, unit = 24 },
  { name = "mercenary post", x = 15, y = 442, unit = 70 },
  { name = "engineer's guild", x = 260, y = 491, unit = 30 },
  { name = "cathedral", x = 260, y = 481, unit = 37 },
  { name = "tunneler's guild", x = 260, y = 486, unit = 5 },
}

-- What each unit's number key sends in its building: the command that makes the next map
-- click place that unit's rally point.
local RALLY_COMMANDS = {
  [22] = 0x14C, [23] = 0x14D, [24] = 0x14E, [26] = 0x14F, [25] = 0x150, [27] = 0x151, [28] = 0x152,
  [70] = 0x168, [74] = 0x169, [71] = 0x16A, [73] = 0x16B, [72] = 0x16C, [76] = 0x16D, [75] = 0x16E,
  [30] = 0x16F, [29] = 0x170, [5] = 0x171, [37] = 0x172,
}

local UNIT_TYPE_COUNT = 80

-- Tooltips: one line of text in the panel's own style (the colour and size of "Available
-- peasants"), at the left of the panel. The game writes a unit's name and gold cost on the
-- top line of the barracks panel (y 424), so the tooltip goes above it, on the
-- crenellations; in the guilds and the cathedral the cost is at y 415, above the parchment,
-- drawn on the map layer, and the tooltip goes under it, 10 px up, drawn the same way; the
-- mercenary post shows its cost at the bottom, so its tooltip uses the free top line.
local TIP_X = 20
local TIP_LINE = 18
local TIP_Y_BARRACKS = 424 - TIP_LINE
local TIP_Y_GUILDS = 415 + TIP_LINE - 10
local TIP_Y_MERCENARIES = 424
local TIP_FONT = 0x12
local TIP_COLOUR = 0xB8EEFB
local TIPS = require("messages").english

local TIP_ON_MAP_LAYER = { [30] = true, [29] = true, [5] = true, [37] = true }
-- renderCurrentlyDisplayedTextConstructionCost: the hover text, read for the camera offset
-- it adds to text it draws on the map layer.
local AOB_HOVER_TEXT = "8B 15 ? ? ? ? 83 EC 0C 83 7C 24 10 00 53 8B 1D ? ? ? ? 56 8B F1 75 17 83 FB "
  .. "10 75 12 83 FA 01 0F 84 ? ? ? ?"
local HOVER_TEXT_CAMERA_X = { 0x5C, { 0x03, 0x0D } }
local HOVER_TEXT_CAMERA_Y = { 0x62, { 0x03, 0x3D } }
local TIP_Y = {
  [22] = TIP_Y_BARRACKS, [23] = TIP_Y_BARRACKS, [24] = TIP_Y_BARRACKS, [25] = TIP_Y_BARRACKS,
  [26] = TIP_Y_BARRACKS, [27] = TIP_Y_BARRACKS, [28] = TIP_Y_BARRACKS,
  [70] = TIP_Y_MERCENARIES, [71] = TIP_Y_MERCENARIES, [72] = TIP_Y_MERCENARIES,
  [73] = TIP_Y_MERCENARIES, [74] = TIP_Y_MERCENARIES, [75] = TIP_Y_MERCENARIES,
  [76] = TIP_Y_MERCENARIES,
  [30] = TIP_Y_GUILDS, [29] = TIP_Y_GUILDS, [5] = TIP_Y_GUILDS, [37] = TIP_Y_GUILDS,
}

-- Where the buttons go: { x, y, flags } relative to the portrait's top left corner.
-- flags 1 = x counts from the portrait's right edge, 2 = x is the button's right edge,
-- 4 = y counts from the bottom of the rally button (for a stance button under it),
-- 8 = y is the button's bottom edge, counted from the portrait's bottom edge.
-- Chosen so the buttons cover neither text nor the unit: the barracks and mercenary
-- portraits get theirs right of their number badge, the guild and cathedral figures stand
-- free, so their buttons sit beside them. The game takes clicks on the buttons wherever
-- they are drawn.
local TOP_LEFT = { 2, 2, 0 }
local PLACES = {
  -- barracks: 2 px right of the number badge, whose border runs from x to x + 13 (archer
  -- 22, spear 32, mace 21, crossbow 14, pike 19, sword 25, knight 27 px from the left)
  [22] = { rally = { 37, 2, 0 } }, [24] = { rally = { 47, 2, 0 } }, [26] = { rally = { 36, 2, 0 } },
  [23] = { rally = { 29, 2, 0 } }, [25] = { rally = { 34, 2, 0 } }, [27] = { rally = { 40, 2, 0 } },
  [28] = { rally = { 42, 2, 0 }, stance = "barracks" },
  -- mercenary post: 2 px right of the round number badge, which ends at Arab archer 21,
  -- slave 29, slinger 21, assassin 31, horse archer 31, Arab swordsman 25, fire thrower 26
  [70] = { rally = { 23, 2, 0 } }, [71] = { rally = { 31, 2, 0 } }, [72] = { rally = { 23, 2, 0 } },
  [73] = { rally = { 33, 2, 0 } }, [74] = { rally = { 33, 2, 0 } }, [75] = { rally = { 27, 2, 0 } },
  [76] = { rally = { 28, 2, 0 }, stance = "mercenaries" },
  [30] = { rally = { 14, 0, 2 } },                        -- engineer: left of his head
  [29] = { rally = { -1, 0, 2 }, stance = "guilds" },     -- ladderman: left of the ladder
  [5] = { rally = TOP_LEFT, stance = "guilds" },
  [37] = { rally = { 0, 0, 0 }, stance = "guilds" },
}

-- The stance button sits above the building's help button ("?", 19 x 19, at these places
-- of the panel), centred on it with a small gap, but clear of the minimap on the right.
local HELP_BUTTONS = {
  barracks = { 545, 563 }, mercenaries = { 545, 563 }, guilds = { 512, 563 },
}
local HELP_SIZE = 19
local HELP_GAP = 2
local PANEL_RIGHT = 569                   -- the minimap starts at 571

-- Pictures, and the coloured squares used when a picture cannot be read.
local PICTURES = {
  rally = { file = "rally", size = 16, colour = { 235, 200, 40 } },
  normal = { file = "stance_normal", size = 20, colour = { 150, 150, 150 } },
  defensive = { file = "stance_defensive", size = 20, colour = { 60, 110, 210 } },
  aggressive = { file = "stance_aggressive", size = 20, colour = { 200, 50, 40 } },
}

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME, purpose,
        address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return core.readInteger(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose)
  expectBytes(base + offset, { 0xE8 }, purpose)
  return base + offset + 5 + core.readInteger(base + offset + 1)
end

local function guard(base, guards, purpose)
  for offset, bytes in pairs(guards) do
    expectBytes(base + offset, bytes, purpose)
  end
end

local function originalBytes(address, size)
  local bytes = {}
  for index = 0, size - 1 do
    bytes[#bytes + 1] = string.format("0x%02X", core.readByte(address + index) & 0xFF)
  end
  return "db " .. table.concat(bytes, ",")
end

-- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values, original)
  if original ~= nil then
    script = script:gsub("%f[%w_]ORIGINAL%f[^%w_]", original)
  end
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
end

local function jumpTo(address, target, size)
  local code = { 0xE9, core.itob(core.getRelativeAddress(address, target, -5)) }
  for _ = 6, size do
    code[#code + 1] = 0x90
  end
  core.writeCode(address, code)
end

local function setting(config, group, name)
  local section = config[group]
  if type(section) == "table" and section[name] ~= nil then
    return section[name]
  end
  return DEFAULTS[group][name]
end

---------------------------------------------------------------------------------------
-- Pictures
---------------------------------------------------------------------------------------

local function readFile(name)
  for _, folder in ipairs(MODULE_FOLDERS) do
    local file = io.open(folder .. name, "rb")
    if file ~= nil then
      local data = file:read("a")
      file:close()
      return data
    end
  end
  return nil
end

local function square(spec)
  local pixels, size = {}, spec.size
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local border = x == 0 or y == 0 or x == size - 1 or y == size - 1
      local colour = border and { 30, 25, 20 } or spec.colour
      pixels[#pixels + 1] = { colour[1], colour[2], colour[3], 255 }
    end
  end
  return size, size, pixels
end

local function lighten(pixels)
  local result = {}
  for index, p in ipairs(pixels) do
    result[index] = {
      p[1] + (255 - p[1]) // 3, p[2] + (255 - p[2]) // 3, p[3] + (255 - p[3]) // 3, p[4],
    }
  end
  return result
end

local function loadPicture(name)
  local data = readFile("images/" .. name .. ".png")
  if data == nil then
    return nil, "not found"
  end
  local ok, width, height, pixels = pcall(png.decode, data)
  if not ok then
    return nil, (tostring(width):gsub("^.-:%d+: ", ""))
  end
  return { width = width, height = height, pixels = pixels }
end

---Writes a picture in the layout the blit routine reads and returns its address.
local function storePicture(width, height, pixels)
  local count = width * height
  local base = core.allocate(0x14 + count * 5, true)
  local rgb565, rgb555, mask = {}, {}, {}
  for index = 1, count do
    local p = pixels[index]
    local r, g, b = p[1], p[2], p[3]
    local value565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    local value555 = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
    rgb565[index * 2 - 1], rgb565[index * 2] = value565 & 0xFF, value565 >> 8
    rgb555[index * 2 - 1], rgb555[index * 2] = value555 & 0xFF, value555 >> 8
    mask[index] = p[4]
  end
  core.writeInteger(base, width)
  core.writeInteger(base + 4, height)
  core.writeInteger(base + 8, base + 0x14)
  core.writeInteger(base + 0xC, base + 0x14 + count * 2)
  core.writeInteger(base + 0x10, base + 0x14 + count * 4)
  core.writeBytes(base + 0x14, rgb565)
  core.writeBytes(base + 0x14 + count * 2, rgb555)
  core.writeBytes(base + 0x14 + count * 4, mask)
  return base
end

-- The game's sprite fading (one transparency for a whole sprite): `cmp word [ready], 0 /
-- jne / call buildBlendTables`, then the source table, `mov edx, <tables + 32 levels>`.
local AOB_BLEND = "66 83 3D ? ? ? ? 00 75 05 E8 ? ? ? ? 8B C3 C1 E0 09 BA ? ? ? ? 2B D0 83 3D ? ? ? ? 00 8D 88"
local BLEND_READY_OPERAND = 3
local BLEND_BUILD_CALL = 0x0A
local BLEND_TABLES_OPERAND = 0x24        -- lea ecx, [eax + tables]
local BLEND_TOP_OPERAND = 0x15           -- mov edx, tables + 32 * 0x200
local BLEND_LEVEL_SIZE = 0x200

---A picture's alpha mask, `<file>_alpha.png` (white = opaque, black = see-through), if the
---player made one: replaces the picture's own transparency.
local function applyAlphaMask(file, width, height, pixels)
  local mask = loadPicture(file .. "_alpha")
  if mask == nil then
    return pixels
  end
  if mask.width ~= width or mask.height ~= height then
    log(WARNING, string.format("%s: images/%s_alpha.png is not the size of %s.png; ignored",
      MODULE_NAME, file, file))
    return pixels
  end
  local result = {}
  for index, p in ipairs(pixels) do
    local m = mask.pixels[index]
    local alpha = (m[1] + m[2] + m[3]) // 3 * m[4] // 255
    result[index] = { p[1], p[2], p[3], alpha }
  end
  return result
end

---Returns the addresses of a button's normal and hover pictures.
local function buttonPictures(key)
  local spec = PICTURES[key]
  local width, height, pixels
  local picture, problem = loadPicture(spec.file)
  if picture == nil then
    log(WARNING, string.format("%s: images/%s.png: %s; using a coloured square", MODULE_NAME,
      spec.file, problem))
    width, height, pixels = square(spec)
  else
    width, height, pixels = picture.width, picture.height, picture.pixels
    pixels = applyAlphaMask(spec.file, width, height, pixels)
  end
  local normal = storePicture(width, height, pixels)

  local hoverPixels = lighten(pixels)
  local hover = loadPicture(spec.file .. "_hover")
  if hover ~= nil then
    if hover.width == width and hover.height == height then
      hoverPixels = {}
      for index, p in ipairs(hover.pixels) do
        hoverPixels[index] = { p[1], p[2], p[3], pixels[index][4] }
      end
    else
      log(WARNING, string.format("%s: images/%s_hover.png is not the size of %s.png; ignored",
        MODULE_NAME, spec.file, spec.file))
    end
  end
  return normal, storePicture(width, height, hoverPixels)
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function patchHorseArchers(horseArcher, values, rideOn)
  guard(horseArcher, HA_GUARDS, "the horse archer's update")
  local v = {}
  for k, value in pairs(values) do v[k] = value end
  v.RALLY_COUNT = core.readInteger(horseArcher + HA_RALLY_COUNT + 2)
  v.WALK_SHOOT = horseArcher + HA_WALK_SHOOT
  v.CONTINUE = horseArcher + HA_RALLY_CONTINUE
  v.TAIL = horseArcher + HA_TAIL
  v.DO_SHOOTING = readCallTarget(horseArcher, HA_DO_SHOOTING, "the horse archer's shooting")
  v.RESUME = horseArcher + HA_DO_SHOOTING

  -- Walking: point the "not there yet" jump at the shoot-on-the-move code.
  local walking = assemble(templates.horseArcherWalking, v)
  local jumpAt = horseArcher + HA_WALKING_JUMP
  core.writeCode(jumpAt + 2, { core.itob(core.getRelativeAddress(jumpAt, walking, -6)) })

  -- At the rally point, between the 40 tick checks.
  v.REPATH = horseArcher + HA_REPATH
  local atRally = assemble(rideOn and templates.horseArcherKeepRiding or templates.horseArcherAtRallyPoint,
    v, originalBytes(horseArcher + HA_AT_RALLY, HA_AT_RALLY_REPLAYED))
  jumpTo(horseArcher + HA_AT_RALLY, atRally, HA_AT_RALLY_SIZE)

  -- No chasing enemies by stance on the way, for the player's horse archers.
  if rideOn then
    v.RESUME = horseArcher + HA_FREE_TO_REACT + HA_FREE_TO_REACT_SIZE
    local noChase = assemble(templates.horseArcherNoChase, v,
      originalBytes(horseArcher + HA_FREE_TO_REACT, HA_FREE_TO_REACT_SIZE))
    jumpTo(horseArcher + HA_FREE_TO_REACT, noChase, HA_FREE_TO_REACT_SIZE)
    v.RESUME = horseArcher + HA_DO_SHOOTING
  end

  -- Shooting without a chosen shot.
  local shooting = assemble(templates.horseArcherShootingState, v,
    originalBytes(horseArcher + HA_SHOOTING_STATE, HA_SHOOTING_STATE_SIZE))
  jumpTo(horseArcher + HA_SHOOTING_STATE, shooting, HA_SHOOTING_STATE_SIZE)
end

-- The rally state of every recruitable unit's update function copies the unit's base speed
-- into its working speed every tick: mov word [esi + unit.calculatedMovementSpeed], reg.
-- updateUnits works the terrain (slopes, marsh, ...) into that working speed only every 4th
-- or 8th tick, so the copy wiped it out and recruits walked to their rally point at full
-- speed over any ground. There is one such store per update function, 18 in all.
local UNIT_WORKING_SPEED = 0x34A
local RALLY_SPEED_STORES = 18

local function patchRallySpeed(unitBase)
  local target = unitBase + UNIT_WORKING_SPEED
  local bytes = {}
  for _, byte in ipairs(core.itob(target)) do
    bytes[#bytes + 1] = string.format("%02X", byte & 0xFF)
  end
  local pattern = "66 89 ? " .. table.concat(bytes, " ")
  local sites, from = {}, 0x400000
  while #sites < RALLY_SPEED_STORES + 1 do
    local ok, site = pcall(core.scanForAOB, pattern, from, 0x600000)
    if not ok or site == nil or site == 0 then
      break
    end
    local modrm = core.readByte(site + 2) & 0xFF
    if (modrm & 0xC7) == 0x86 then          -- [esi + disp32] with ax/cx/dx/bx...
      sites[#sites + 1] = site
    end
    from = site + 1
  end
  if #sites ~= RALLY_SPEED_STORES then
    log(WARNING, string.format("%s: found %d of the %d rally speed stores; terrain still does not "
      .. "slow recruits on the way to their rally point", MODULE_NAME, #sites, RALLY_SPEED_STORES))
    return
  end
  for _, site in ipairs(sites) do
    core.writeCode(site, { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 })
  end
end

-- findFreeCathedralAssemblyTile, where the monks' rally point is looked up.
local AOB_CATHEDRAL_SEARCH = "83 EC 0C 8B 44 24 10 69 C0 F4 39 00 00 89 4C 24 08 0F B7 88 ? ? ? ? 66 85 "
  .. "C9 ? ? ? ? ? ? 0F BF 90 ? ? ? ?"
local CATHEDRAL_LOOP = 0x50              -- movsx esi, word [table + 3*4 + 2] (7) / add esi, [esp+14] (4)
local CATHEDRAL_LOOP_SIZE = 18           -- / movsx edi, word [table + 3*4] (7)
local CATHEDRAL_FIXED_ENTRY = 3

local function patchCathedralSearch()
  local ok, search = pcall(core.AOBScan, AOB_CATHEDRAL_SEARCH)
  if not ok or search == nil then
    log(WARNING, MODULE_NAME .. ": could not find the monks' rally point search; not fixed")
    return
  end
  local site = search + CATHEDRAL_LOOP
  expectBytes(site, { 0x0F, 0xBF, 0x35 }, "the monks' rally point search")
  expectBytes(site + 7, { 0x03, 0x74, 0x24, 0x14, 0x0F, 0xBF, 0x3D }, "the monks' rally point search")
  local y = core.readInteger(site + 3) - CATHEDRAL_FIXED_ENTRY * 4
  local x = core.readInteger(site + 14) - CATHEDRAL_FIXED_ENTRY * 4
  if x ~= y - 2 then
    log(WARNING, MODULE_NAME .. ": the monks' rally point search is not the one this module knows")
    return
  end
  local stub = assemble(templates.cathedralSearch, {
    OFFSETS_Y = y, OFFSETS_X = x, RESUME = site + CATHEDRAL_LOOP_SIZE,
  })
  jumpTo(site, stub, CATHEDRAL_LOOP_SIZE)
end

local function patchMoveOrders(values)
  local site = scan(AOB_MOVE_ORDER, "where a move order is given") + MOVE_ORDER_OFFSET
  local v = { GO_TO_RALLY_POINT = values.GO_TO_RALLY_POINT, RESUME = site + MOVE_ORDER_SIZE }
  local stub = assemble(templates.moveOrder, v, originalBytes(site, MOVE_ORDER_SIZE))
  jumpTo(site, stub, MOVE_ORDER_SIZE)
end

local function patchFightOnTheWay(horseArcher, stanceRead, values, followChanges, runWhenAggressive)
  local updateSite = scan(AOB_UNIT_UPDATE, "where a unit is updated")
  local site = updateSite + UNIT_UPDATE_HOOK
  expectBytes(horseArcher + HA_RALLY_COUNT, HA_GUARDS[HA_RALLY_COUNT], "the rally counters")
  expectBytes(stanceRead + STANCE_READ_TRIBE_SIZE - 2, { 0x69, 0xC0 }, "the group size")
  local slots = core.allocate(UNIT_TYPE_COUNT, true)
  for unit = 0, UNIT_TYPE_COUNT - 1 do
    core.writeByte(slots + unit, RALLY_SLOTS[unit] or 0xFF)
  end
  local reacts = core.allocate(UNIT_TYPE_COUNT, true)
  for _, unit in ipairs(REACTS_ON_ROUTE) do
    core.writeByte(reacts + unit, 1)
  end
  local shoots = core.allocate(UNIT_TYPE_COUNT, true)
  local idleMasks = core.allocate(UNIT_TYPE_COUNT * 2, true)
  for unit, states in pairs(IDLE_STATES) do
    local mask = 0
    for _, state in ipairs(states) do
      mask = mask | (1 << state)
    end
    core.writeSmallInteger(idleMasks + unit * 2, mask)
  end
  local function field(offset) return UNITS_STATE_TO_UNITS + offset end
  local v = {
    U_STATE = field(UNIT_STATE),
    U_MOVE_STATUS = field(UNIT_MOVE_STATUS),
    U_TYPE = field(UNIT_TYPE),
    U_OWNER = field(UNIT_OWNER),
    U_TRIBE = field(UNIT_TRIBE),
    U_RESUME_X = field(UNIT_RESUME_X),
    U_RESUME_Y = field(UNIT_RESUME_Y),
    U_MOVEMENT_TYPE = field(UNIT_MOVEMENT_TYPE),
    U_SELECTED = field(UNIT_SELECTED),
    U_LOGICAL = field(UNIT_LOGICAL_STATE),
    U_UID = field(UNIT_UID),
    U_FREE_TO_REACT = field(UNIT_FREE_TO_REACT),
    REACTS = reacts,
    SHOOTS = shoots,
    IDLE_MASKS = idleMasks,
    STANCE = values.STANCE,
    U_GO_TO_RALLY_POINT = field(UNIT_GO_TO_RALLY_POINT),
    MARKS = values.MARKS,
    IDLE = core.allocate(MARK_COUNT, true),
    STILL = core.allocate(MARK_COUNT, true),
    STILL_TICKS = STILL_TICKS,
    LAST_POSITIONS = core.allocate(MARK_COUNT * 4, true),
    U_POSITION = field(UNIT_POSITION),
    IDLE_TICKS = IDLE_TICKS,
    U_TARGETING = field(UNIT_TARGETING),
    FOLLOW_UIDS = values.FOLLOW_UIDS,
    U_TRIBE_UID = field(UNIT_TRIBE_UID),
    TRIBE_UIDS = core.readInteger(stanceRead + STANCE_READ_OPERAND) - values.STANCE_OFFSET + TRIBE_UID,
    TRIBE_ACTIVE = core.readInteger(stanceRead + STANCE_READ_OPERAND) - values.STANCE_OFFSET + TRIBE_ACTIVE,
    FOLLOW_ON = core.allocate(4, true),
    MARK_COUNT = MARK_COUNT,
    SLOTS = slots,
    RALLY_COUNTERS = core.readInteger(horseArcher + HA_RALLY_COUNT + 2) - HORSE_ARCHER_SLOT * 4,
    LOCAL_PLAYER = values.LOCAL_PLAYER,
    DIAG = values.DIAG,
    DIAG_ON = values.DIAG_ON,
    GAME_TICKS = values.GAME_TICKS,
    DUMP = values.DUMP,
    DUMP_EVERY = values.DUMP_EVERY,
    TRIBE_SIZE = core.readInteger(stanceRead + STANCE_READ_TRIBE_SIZE),
    TRIBE_STANCES = core.readInteger(stanceRead + STANCE_READ_OPERAND),
    TRIBE_COUNTS = core.readInteger(stanceRead + STANCE_READ_OPERAND) - values.STANCE_OFFSET + TRIBE_COUNT,
    RESUME = site + UNIT_UPDATE_HOOK_SIZE,
  }
  -- The ranged units' "stop and shoot while walking" test, in five update functions.
  local rangedSites = {}
  for _, form in ipairs(RANGED_WALK_CHECKS) do
    local from = 0x400000
    for _ = 1, form.count do
      local ok, found = pcall(core.scanForAOB, form.pattern, from, 0x600000)
      if not ok or found == nil or found == 0 then
        break
      end
      rangedSites[#rangedSites + 1] = found + form.offset
      from = found + 1
    end
  end
  if #rangedSites == RANGED_WALK_CHECK_COUNT then
    local first = rangedSites[1]
    local function operand(spec, purpose)
      expectBytes(first + spec.at, spec.bytes, purpose)
      return core.readInteger(first + spec.at + #spec.bytes)
    end
    local unitsState = operand(WALK_SHOT.unitsState, "the units")
    v.UNITS_STATE = unitsState
    v.U_RNG = operand(WALK_SHOT.rng, "the units' random number") - unitsState
    v.U_SHOOT_TARGET = operand(WALK_SHOT.target, "the shooting target") - unitsState
    if v.U_RNG ~= field(WALK_SHOT.rng.field) or v.U_SHOOT_TARGET ~= field(WALK_SHOT.target.field) then
      error(MODULE_NAME .. ": the ranged units' walking state is not the one this module knows")
    end
    v.TRIBE_STATE = operand(WALK_SHOT.tribeState, "the groups")
    v.ACQUIRE_SHOOT_TARGET = readCallTarget(first, WALK_SHOT.acquire, "the target search")
    v.GIVE_TRIBE_INSTRUCTION = readCallTarget(first, WALK_SHOT.instruction, "the group orders")
    for _, unit in ipairs(SHOOTS_ON_THE_WAY) do
      core.writeByte(shoots + unit, 1)
    end
    for _, site in ipairs(rangedSites) do
      expectBytes(site, { 0x39 }, "the ranged units' walking stance test")
      local stub = assemble(templates.rangedWalkStance,
        { MARKS = v.MARKS, MARK_COUNT = MARK_COUNT, DIAG = values.DIAG, RESUME = site + 7 },
        originalBytes(site, 7))
      jumpTo(site, stub, 7)
    end
  else
    log(WARNING, string.format("%s: found %d of the %d ranged walking stance tests; ranged recruits "
      .. "will not stop to shoot on the way", MODULE_NAME, #rangedSites, RANGED_WALK_CHECK_COUNT))
  end

  if v.UNITS_STATE == nil then
    -- no ranged units' walking state found: the template still needs the names
    v.UNITS_STATE, v.U_RNG, v.U_SHOOT_TARGET, v.TRIBE_STATE = 0, 0, 0, 0
    v.ACQUIRE_SHOOT_TARGET, v.GIVE_TRIBE_INSTRUCTION = site, site
  end
  core.writeByte(v.FOLLOW_ON, followChanges and 1 or 0)
  local stub = assemble(templates.fightOnTheWay, v, originalBytes(site, UNIT_UPDATE_HOOK_SIZE))
  jumpTo(site, stub, UNIT_UPDATE_HOOK_SIZE)

  if runWhenAggressive then
    guard(updateSite, UNIT_UPDATED_GUARDS, "where a unit has been updated")
    local after = updateSite + UNIT_UPDATED_HOOK
    v.CURRENT_UNIT = core.readInteger(after + 1)
    v.U_ANIM_SHEET = field(UNIT_ANIMATION_SHEET)
    v.U_STATE_SPEED = field(UNIT_STATE_SPEED)
    v.RUN_SHEETS = core.allocate(UNIT_TYPE_COUNT * 4, true)
    v.RUN_SPEEDS = core.allocate(UNIT_TYPE_COUNT, true)
    for unit, run in pairs(RUNS) do
      core.writeInteger(v.RUN_SHEETS + unit * 4, run[1])
      core.writeByte(v.RUN_SPEEDS + unit, run[2])
    end
    v.RESUME = after + UNIT_UPDATED_HOOK_SIZE
    jumpTo(after, assemble(templates.runWhenAggressive, v), UNIT_UPDATED_HOOK_SIZE)
  end
end

---A cdecl function with no arguments that runs `callback` in lua (UCP's own detour trick).
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  local reported = false
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok and not reported then
      reported = true
      log(WARNING, string.format("%s: %s failed: %s", MODULE_NAME, purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

local STATE_NAMES = { [0] = "idle0", [1] = "idle", [4] = "shoot", [0x65] = "walk", [0x69] = "rally",
  [0x6A] = "melee", [0x6B] = "attack-building" }

---Writes what the module sees of the player's recruits to ucp3.log (diagnostics setting).
local function makeDump(values, unitBase, tribes)
  local unitsState = unitBase - UNITS_STATE_TO_UNITS
  local lastCounters = ""
  return function()
    local localPlayer = core.readInteger(values.LOCAL_PLAYER)
    local counters = string.format("let through %d, taken out of a shared group %d, stanced %d, "
      .. "told to shoot on the way %d, ranged let through %d, sent back to the rally point %d, "
      .. "stance put back %d, standing at the building %d, running %d",
      core.readInteger(values.DIAG + 4), core.readInteger(values.DIAG + 24), core.readInteger(values.DIAG + 8),
      core.readInteger(values.DIAG + 12), core.readInteger(values.DIAG + 16), core.readInteger(values.DIAG + 20),
      core.readInteger(values.DIAG + 28), core.readInteger(values.DIAG + 32),
      core.readInteger(values.DIAG + 36))
    local lines = {}
    local count = math.min(core.readInteger(unitsState), MARK_COUNT - 1)
    for id = 1, count do
      local u = unitBase + id * 0x490
      if core.readSmallInteger(u + 0x8C) ~= 0 and core.readSmallInteger(u + UNIT_OWNER) == localPlayer then
        local kind = core.readSmallInteger(u + 0x8E)
        if RALLY_COMMANDS[kind] ~= nil then
          local state = core.readSmallInteger(u + UNIT_STATE) & 0xFFFF
          local marks = core.readByte(values.MARKS + id) & 0xFF
          local goTo = core.readSmallInteger(u + UNIT_GO_TO_RALLY_POINT)
          if state == 0x65 or state == 0x69 or marks ~= 0 or goTo ~= 0 then
            local tribe = core.readSmallInteger(u + 0x2D8)
            local stance = tribe > 0
              and core.readSmallInteger(tribes.stances + tribe * tribes.size) or -1
            lines[#lines + 1] = string.format("  unit %d type %d state %s(0x%X) moving %d group %d "
              .. "stance %d marks %d free-to-react %d selected %d target %d", id, kind,
              STATE_NAMES[state] or "?", state, core.readSmallInteger(u + 0xF6), tribe, stance, marks,
              core.readSmallInteger(u + 0x3FC), core.readSmallInteger(u + 0x34),
              core.readSmallInteger(u + 0x39C))
            if #lines >= 25 then
              break
            end
          end
        end
      end
    end
    if #lines == 0 and counters == lastCounters then
      return
    end
    lastCounters = counters
    log(INFO, string.format("%s diagnostics: tick %d, game mode 0x%X, player %d (network id %d), "
      .. "recruit stance %d | %s", MODULE_NAME, core.readInteger(values.GAME_TICKS),
      core.readInteger(values.GAME_MODE), localPlayer,
      core.readInteger(values.NETWORK_IDS + localPlayer * 4), core.readByte(values.STANCE) & 0xFF, counters))
    for _, line in ipairs(lines) do
      log(INFO, line)
    end
  end
end

local function patchNewGroups(newGroup, values, unitBase, tribes, stanceRead)
  guard(newGroup, NEW_GROUP_GUARDS, "the new group code")
  local v = {}
  for k, value in pairs(values) do v[k] = value end
  v.SKIRMISH_MODE = SKIRMISH_MODE
  v.UNIT_GROUP = unitBase + 0x2D8
  v.TRIBES = tribes
  v.TRIBE_SIZE = core.readInteger(stanceRead + STANCE_READ_TRIBE_SIZE)
  v.TRIBE_STANCES = core.readInteger(stanceRead + STANCE_READ_OPERAND)
  v.TRIBE_UIDS = tribes + TRIBE_UID
  v.TRIBE_ACTIVE = tribes + TRIBE_ACTIVE
  v.UNIT_TRIBE_UID = unitBase + UNIT_TRIBE_UID
  v.UID = unitBase + UNIT_UID
  v.REMOVE_FROM_GROUP = scan(AOB_REMOVE_FROM_GROUP, "the code that takes a unit out of a group")

  v.RESUME = newGroup + NEW_GROUP_ENTRY_SIZE
  local entry = assemble(templates.newGroupEntry, v)

  v.RESUME = newGroup + NEW_GROUP_STANCE_HOOK + NEW_GROUP_STANCE_SIZE
  local stance = assemble(templates.newGroupStance, v)

  v.RESUME = newGroup + NEW_GROUP_PLAYER_CHECK + NEW_GROUP_PLAYER_CHECK_SIZE
  local player = assemble(templates.newGroupPlayer, v,
    originalBytes(newGroup + NEW_GROUP_PLAYER_CHECK, NEW_GROUP_PLAYER_CHECK_SIZE))
  jumpTo(newGroup + NEW_GROUP_PLAYER_CHECK, player, NEW_GROUP_PLAYER_CHECK_SIZE)

  jumpTo(newGroup, entry, NEW_GROUP_ENTRY_SIZE)
  jumpTo(newGroup + NEW_GROUP_STANCE_HOOK, stance, NEW_GROUP_STANCE_SIZE)
end

---Finds every recruit portrait, the group header it belongs to, and the first item of its
---menu block (an every-frame item, which the game runs before the portraits).
local function findPortraits()
  local found = {}
  for _, building in ipairs(BUILDINGS) do
    local pattern = {}
    for _, value in ipairs({ TYPE_MEMBER | 3, building.x, building.y, 0, 0 }) do
      for _, byte in ipairs(core.itob(value)) do
        pattern[#pattern + 1] = string.format("%02X", byte & 0xFF)
      end
    end
    pattern[#pattern + 1] = "? ? ? ?"
    for _, byte in ipairs(core.itob(building.unit)) do
      pattern[#pattern + 1] = string.format("%02X", byte & 0xFF)
    end
    local member = scan(table.concat(pattern, " "), "the " .. building.name .. " portraits")
    local header = member - ITEM_SIZE
    if core.readInteger(header + ITEM_TYPE) ~= TYPE_GROUP then
      error(MODULE_NAME .. ": the " .. building.name .. " portraits are not the ones this module knows")
    end
    local first, limit = header, 40
    while core.readInteger(first - ITEM_SIZE + ITEM_TYPE) ~= TYPE_BLOCK and limit > 0 do
      first = first - ITEM_SIZE
      limit = limit - 1
    end
    if limit == 0 or core.readInteger(first + ITEM_TYPE) ~= TYPE_EVERY_FRAME then
      error(MODULE_NAME .. ": the " .. building.name .. " menu is not the one this module knows")
    end
    local group = { building = building, header = header, first = first, members = {} }
    local item = header + ITEM_SIZE
    while (core.readInteger(item + ITEM_TYPE) & TYPE_MEMBER) ~= 0 do
      local unit = core.readInteger(item + ITEM_PARAM)
      if RALLY_COMMANDS[unit] == nil or PLACES[unit] == nil then
        error(string.format("%s: unexpected unit type %d among the %s portraits", MODULE_NAME,
          unit, building.name))
      end
      group.members[#group.members + 1] = item
      item = item + ITEM_SIZE
    end
    found[#found + 1] = group
  end
  return found
end

-- writeCodeInteger: the static table lies in the exe image, which may be write protected.
local function setField(item, offset, value)
  if core.readInteger(item + offset) ~= value then
    core.writeCodeInteger(item + offset, value)
  end
end

---The building menu may have been copied elsewhere (by the ui module); wrap the portraits and
---the blocks' first items in whatever item list it uses now.
local function wrapLiveMenu(menu, wrappers)
  local items = core.readInteger(menu)
  if items == 0 then
    return
  end
  local item, limit, first = items, 4000, nil
  while core.readInteger(item + ITEM_TYPE) ~= TYPE_LAST and limit > 0 do
    local kind = core.readInteger(item + ITEM_TYPE)
    if kind == TYPE_BLOCK then
      first = item + ITEM_SIZE
    elseif (kind & TYPE_MEMBER) ~= 0 and PLACES[core.readInteger(item + ITEM_PARAM)] ~= nil then
      local render = core.readInteger(item + ITEM_RENDER)
      if render == wrappers.render or wrappers.originalRenders[render] then
        setField(item, ITEM_RENDER, wrappers.render)
        if first ~= nil and core.readInteger(first + ITEM_TYPE) == TYPE_EVERY_FRAME then
          if core.readInteger(first + ITEM_ACTION) == wrappers.originalFrame then
            setField(first, ITEM_ACTION, wrappers.frame)
          end
        end
      end
    end
    item = item + ITEM_SIZE
    limit = limit - 1
  end
end

local function writePlace(address, place)
  core.writeInteger(address, place[1])
  core.writeInteger(address + 4, place[2])
  core.writeInteger(address + 8, place[3])
end

local function installButtons(values, rallyOn, stanceOn)
  local groups = findPortraits()

  local rally, rallyHover = buttonPictures("rally")
  local stancePictures = {}
  local stanceWidth, stanceHeight = 0, 0
  for index, key in ipairs({ "normal", "defensive", "aggressive" }) do
    local normal, hover = buttonPictures(key)
    stancePictures[index] = { normal, hover }
    stanceWidth = math.max(stanceWidth, core.readInteger(normal))
    stanceHeight = math.max(stanceHeight, core.readInteger(normal + 4))
  end

  local tables = {
    commands = core.allocate(UNIT_TYPE_COUNT * 4, true),
    renders = core.allocate(UNIT_TYPE_COUNT * 4, true),
    places = core.allocate(UNIT_TYPE_COUNT * 24, true),
    rallyRects = core.allocate(UNIT_TYPE_COUNT * 16, true),
    stanceRects = core.allocate(UNIT_TYPE_COUNT * 16, true),
    rallyStamps = core.allocate(UNIT_TYPE_COUNT * 4, true),
    stanceStamps = core.allocate(UNIT_TYPE_COUNT * 4, true),
    stanceHosts = core.allocate(UNIT_TYPE_COUNT, true),
    stanceImages = core.allocate(6 * 4, true),
    itemPlaces = core.allocate(UNIT_TYPE_COUNT * 8, true),
    tips = core.allocate(#TIPS * 4, true),
    tipPlaces = core.allocate(UNIT_TYPE_COUNT * 8, true),
    tipLayers = core.allocate(UNIT_TYPE_COUNT, true),
    tip = core.allocate(4, true),
    scratch = core.allocate(64, true),
    frame = core.allocate(4, true),
    originalFrame = core.allocate(4, true),
  }

  local wrappers = { originalRenders = {} }
  for _, group in ipairs(groups) do
    local render = core.readInteger(group.header + ITEM_RENDER)
    local frameAction = core.readInteger(group.first + ITEM_ACTION)
    if wrappers.originalFrame == nil then
      wrappers.originalFrame = frameAction
    elseif wrappers.originalFrame ~= frameAction then
      error(MODULE_NAME .. ": the recruiting buildings' menus are not the ones this module knows")
    end
    wrappers.originalRenders[render] = true
    for _, member in ipairs(group.members) do
      local unit = core.readInteger(member + ITEM_PARAM)
      local place = PLACES[unit]
      core.writeInteger(tables.commands + unit * 4, RALLY_COMMANDS[unit])
      core.writeInteger(tables.renders + unit * 4, render)
      writePlace(tables.places + unit * 24, place.rally)
      core.writeInteger(tables.itemPlaces + unit * 8, core.readInteger(member + ITEM_X))
      core.writeInteger(tables.itemPlaces + unit * 8 + 4, core.readInteger(member + ITEM_Y))
      core.writeInteger(tables.tipPlaces + unit * 8, TIP_X)
      core.writeInteger(tables.tipPlaces + unit * 8 + 4, TIP_Y[unit])
      core.writeByte(tables.tipLayers + unit, TIP_ON_MAP_LAYER[unit] and 1 or 0)
      if place.stance ~= nil then
        -- above the help button, as an offset from this portrait's place in the panel
        local help = HELP_BUTTONS[place.stance]
        local x = math.min(help[1] + (HELP_SIZE - stanceWidth) // 2, PANEL_RIGHT - stanceWidth)
        local y = help[2] - HELP_GAP - stanceHeight
        writePlace(tables.places + unit * 24 + 12, {
          x - core.readInteger(member + ITEM_X), y - core.readInteger(member + ITEM_Y), 0 })
        if stanceOn then
          core.writeByte(tables.stanceHosts + unit, 1)
        end
      end
    end
  end
  core.writeInteger(tables.originalFrame, wrappers.originalFrame)

  for index, pictures in ipairs(stancePictures) do
    core.writeInteger(tables.stanceImages + (index - 1) * 4, pictures[1])
    core.writeInteger(tables.stanceImages + (index + 2) * 4, pictures[2])
  end
  core.writeByte(values.RALLY_ON, rallyOn and 1 or 0)

  local v = {}
  for k, value in pairs(values) do v[k] = value end
  v.SCRATCH = tables.scratch
  local blend = scan(AOB_BLEND, "the game's sprite fading")
  v.BLEND_READY = core.readInteger(blend + BLEND_READY_OPERAND)
  v.BUILD_BLEND = readCallTarget(blend, BLEND_BUILD_CALL, "the blend tables")
  v.BLEND_TABLES = core.readInteger(blend + BLEND_TABLES_OPERAND)
  if core.readInteger(blend + BLEND_TOP_OPERAND) ~= v.BLEND_TABLES + 32 * BLEND_LEVEL_SIZE then
    error(MODULE_NAME .. ": the game's blend tables are not the ones this module knows")
  end
  v.BLIT = assemble(templates.blit, v)
  v.DRAW_BUTTON = assemble(templates.drawButton, v)
  v.ORIGINAL_RENDER = tables.renders
  v.ORIGINAL_FRAME_ACTION = tables.originalFrame
  v.PLACES = tables.places
  v.FRAME = tables.frame
  v.RALLY_RECTS = tables.rallyRects
  v.STANCE_RECTS = tables.stanceRects
  v.RALLY_STAMPS = tables.rallyStamps
  v.STANCE_STAMPS = tables.stanceStamps
  v.STANCE_HOSTS = tables.stanceHosts
  v.STANCE_IMAGES = tables.stanceImages
  v.RALLY_IMAGE = rally
  v.RALLY_IMAGE_HOVER = rallyHover
  v.RALLY_COMMANDS = tables.commands
  v.LEFT_CLICK = MOUSE_LEFT_CLICK

  for index, text in ipairs(TIPS) do
    local address = core.allocate(#text + 1, true)
    core.writeString(address, text)
    core.writeInteger(tables.tips + (index - 1) * 4, address)
  end
  -- CR.TEX is loaded at afterInit. Reuse the text owner rather than a private encoder.
  hooks.registerHookCallback("afterInit", function()
    local owner = modules.textResourceModifier
    local language = owner:GetLanguage():lower()
    local texts = require("messages")[language] or TIPS
    local encoded = {}
    for index, text in ipairs(texts) do
      encoded[index] = owner:TransformText(text)
      assert(not encoded[index]:match("^ERROR:"), "smarter-recruits: text encoding unavailable")
    end
    for index, text in ipairs(encoded) do
      local address = core.allocate(#text + 1, true)
      core.writeString(address, text)
      core.writeInteger(tables.tips + (index - 1) * 4, address)
    end
  end)
  local hoverText = scan(AOB_HOVER_TEXT, "the game's hover text")
  local tipValues = {
    TIP_LAYERS = tables.tipLayers,
    CAMERA_X = readOperand(hoverText, HOVER_TEXT_CAMERA_X, "the camera position"),
    CAMERA_Y = readOperand(hoverText, HOVER_TEXT_CAMERA_Y, "the camera position"),
    ITEM_PLACES = tables.itemPlaces,
    TIP_PLACES = tables.tipPlaces,
    FONT = TIP_FONT,
    COLOUR = TIP_COLOUR,
    TEXT_MANAGER = values.TEXT_MANAGER,
    SHADOWED_TEXT = values.SHADOWED_TEXT,
  }
  v.TOOLTIP = assemble(templates.tooltip, tipValues)
  v.TIPS = tables.tips
  v.TIP = tables.tip
  wrappers.render = assemble(templates.renderPortrait, v)
  wrappers.frame = assemble(templates.frameClick, v)

  -- The static item table: covers a menu built after this point. The members' own render
  -- is 0 there (the Menu constructor fills it from the header, but only where it is 0), or
  -- already the header's if the menu has been built.
  for _, group in ipairs(groups) do
    for _, member in ipairs(group.members) do
      setField(member, ITEM_RENDER, wrappers.render)
    end
    setField(group.first, ITEM_ACTION, wrappers.frame)
  end

  -- The menu itself, in case it already uses another copy of the items, and again after
  -- every module has started (the ui module copies menus it adds items to).
  local tableStart = groups[1].header
  local limit = 400
  while core.readInteger(tableStart - ITEM_SIZE + ITEM_TYPE) ~= TYPE_LAST and limit > 0 do
    tableStart = tableStart - ITEM_SIZE
    limit = limit - 1
  end
  local startBytes = {}
  for _, byte in ipairs(core.itob(tableStart)) do
    startBytes[#startBytes + 1] = string.format("%02X", byte & 0xFF)
  end
  local ok, constructorSite = pcall(core.AOBScan, "68 " .. table.concat(startBytes, " ") .. " B9")
  if ok and constructorSite ~= nil then
    local menu = core.readInteger(constructorSite + 6)
    wrapLiveMenu(menu, wrappers)
    hooks.registerHookCallback("afterInit", function()
      wrapLiveMenu(menu, wrappers)
    end)
  else
    log(WARNING, MODULE_NAME .. ": could not find the building menu itself; the buttons rely on "
      .. "its item table")
  end
end

local function enable(self, config)
  config = config or {}
  local shootOnTheWay = setting(config, "horse_archers", "shoot_on_the_way")
  local rideOn = shootOnTheWay and setting(config, "horse_archers", "ride_on")
  local keepNewOrders = setting(config, "rally", "keep_new_orders")
  local rallyButtons = setting(config, "rally", "buttons")
  local stanceButton = setting(config, "stance", "button")
  local fightOnTheWay = setting(config, "rally", "fight_on_the_way")
  local followChanges = setting(config, "rally", "follow_changes")
  local runWhenAggressive = setting(config, "rally", "run_when_aggressive")
  local terrainSpeed = setting(config, "rally", "terrain_speed")
  local monksFix = setting(config, "rally", "monks_fix")
  local startStance = STANCES[setting(config, "stance", "start")] or 0

  local horseArcher = scan(AOB_HORSE_ARCHER, "the horse archer's update")
  local newGroup = scan(AOB_NEW_GROUP, "the new group code")
  local unitBase = core.readInteger(newGroup + NEW_GROUP_OWNER_OPERAND) - UNIT_OWNER
  local tribes = core.readInteger(horseArcher + HA_TRIBES_OPERAND)
  local stanceRead = scan(AOB_STANCE_READ, "where a stance is read")
  local toolbar = scan(AOB_TOOLBAR, "the recruiting buildings' key handler") - TOOLBAR_PATTERN_OFFSET
  local nameBox = scan(AOB_NAME_BOX, "the game's menu drawing")
  local menuItem = scan(AOB_MENU_ITEM, "the menu item handler")
  local drawColourBox = readCallTarget(nameBox, NAME_BOX_DRAW_COLOUR_BOX, "the box drawing")

  expectBytes(horseArcher + HA_STATE_OPERAND - 3, { 0x0F, 0xBF, 0x86 }, "the horse archer's state")
  if core.readInteger(horseArcher + HA_STATE_OPERAND) ~= unitBase + UNIT_STATE then
    error(MODULE_NAME .. ": the unit layout is not the one this module knows")
  end

  local state = core.allocate(16, true)
  local diagnostics = setting(config, "debug", "log")
  core.writeByte(state, stanceButton and startStance or 0)

  local values = {
    STANCE = state,
    RALLY_ON = state + 1,
    GO_TO_RALLY_POINT = unitBase + UNIT_GO_TO_RALLY_POINT,
    OWNER = unitBase + UNIT_OWNER,
    SHOOTING_VARIATION = unitBase + UNIT_SHOOTING_VARIATION,
    GAME_MODE = core.readInteger(newGroup + NEW_GROUP_MODE_OPERAND),
    STANCE_OFFSET = core.readInteger(stanceRead + STANCE_READ_OPERAND) - tribes,
    LOCAL_PLAYER = readOperand(toolbar, TOOLBAR_LOCAL_PLAYER, "the local player"),
    TOOLBAR_BUTTON = toolbar,
    CLICK_SOUND = readOperand(toolbar, TOOLBAR_SOUND_ID, "the click sound"),
    SOUNDS = readOperand(toolbar, TOOLBAR_SOUNDS, "the sound player"),
    PLAY_SOUND = readCallTarget(toolbar, TOOLBAR_PLAY_SOUND, "the sound player"),
    BUTTON_X = readOperand(nameBox, NAME_BOX.itemX, "the item position"),
    BUTTON_Y = readOperand(nameBox, NAME_BOX.itemY, "the item position"),
    BUTTON_W = readOperand(nameBox, NAME_BOX.itemWidth, "the item size"),
    BUTTON_H = readOperand(nameBox, NAME_BOX.itemHeight, "the item size"),
    PENCIL = readOperand(nameBox, NAME_BOX.pencil, "the pencil"),
    TEXT_MANAGER = readOperand(nameBox, NAME_BOX_TEXT_MANAGER, "the text drawing"),
    SHADOWED_TEXT = readCallTarget(nameBox, NAME_BOX_SHADOWED_TEXT, "the text drawing"),
    SETUP_SURFACE = readCallTarget(drawColourBox, DRAW_COLOUR_BOX_SURFACE, "the drawing surface"),
    SETUP_PENCIL = readCallTarget(drawColourBox, DRAW_COLOUR_BOX_CLIP, "the clipping"),
    MOUSE = readOperand(menuItem, MENU_ITEM_MOUSE, "the mouse"),
    IS_INSIDE = readCallTarget(menuItem, MENU_ITEM_IS_INSIDE, "the mouse test"),
    PIXEL_FORMAT = core.readInteger(scan(AOB_PIXEL_FORMAT, "the pixel format") + PIXEL_FORMAT_OPERAND),
    MARKS = core.allocate(MARK_COUNT, true),
    FOLLOW_UIDS = core.allocate(MARK_COUNT * 4, true),
    MARK_COUNT = MARK_COUNT,
    DIAG = core.allocate(48, true),
    DIAG_ON = core.allocate(4, true),
    DUMP_EVERY = DUMP_EVERY,
    GAME_TICKS = core.readInteger(scan(AOB_TICK_COUNTER, "the tick counter") + TICK_COUNTER_OPERAND),
    NETWORK_IDS = core.readInteger(newGroup + NEW_GROUP_PLAYER_CHECK + 3),
  }
  core.writeByte(values.DIAG_ON, diagnostics and 1 or 0)
  values.DUMP = luaFunction("the diagnostics", makeDump(values, unitBase, {
    stances = core.readInteger(stanceRead + STANCE_READ_OPERAND),
    size = core.readInteger(stanceRead + STANCE_READ_TRIBE_SIZE),
  }))

  if shootOnTheWay then
    patchHorseArchers(horseArcher, values, rideOn)
  end
  if keepNewOrders then
    patchMoveOrders(values)
  end
  if terrainSpeed then
    patchRallySpeed(unitBase)
  end
  if monksFix then
    patchCathedralSearch()
  end
  if stanceButton and fightOnTheWay then
    patchFightOnTheWay(horseArcher, stanceRead, values, followChanges, runWhenAggressive)
  end
  if stanceButton then
    patchNewGroups(newGroup, values, unitBase, tribes, stanceRead)
  end
  if rallyButtons or stanceButton then
    installButtons(values, rallyButtons, stanceButton)
  end
end

return {
  enable = enable,
  disable = function(self, config) end,
}
