--[[
  The assembly this module puts into the game, one script per piece. Every name in capitals
  is a constant init.lua passes in (an address read out of the game, or one of the module's
  own tables). ORIGINAL is replaced by the game instruction a hook overwrote, as `db` bytes.

  Register state at the hooks is the game's own; the comments say what each register holds.
]]

local templates = {}

-- UpdateHorseArcher, state 0x69 (walking to the rally point), the "not there yet" branch.
-- The game only bumps a counter here. Bump it, then run what state 0x65 (an ordinary move
-- order) does while walking: every 100 ticks look for an enemy in range and shoot on the
-- move. esi = unit offset, ebx = unit id, edi = owner offset.
templates.horseArcherWalking = [[
add dword [edi+RALLY_COUNT],1
jmp WALK_SHOOT
]]

-- UpdateHorseArcher, state 0x69, arrived. The game looks for enemies every 40 ticks and
-- does nothing in between, so a shot that has started freezes half drawn. In between,
-- carry on with the shot that is running (the call returns at once when there is none).
templates.horseArcherAtRallyPoint = [[
ORIGINAL
test edx,edx
jne wait_here
jmp CONTINUE
wait_here:
add dword [edi+RALLY_COUNT],1
push ebx
call DO_SHOOTING
add esp,4
jmp TAIL
]]

-- The same place, when the player's horse archers keep riding to the rally point: ebp = the
-- owner. For the player's horse archers the 40th tick goes straight to looking up the rally
-- point again (the game would stop there to shoot whenever an enemy is close, and so never
-- follow a rally point that moved), and every other tick runs the shoot-from-the-saddle
-- check of an ordinary march. Other players' horse archers keep the behaviour above.
templates.horseArcherKeepRiding = [[
ORIGINAL
cmp ebp,[LOCAL_PLAYER]
jne not_ours
test edx,edx
jne shoot_from_saddle
jmp REPATH
shoot_from_saddle:
add dword [edi+RALLY_COUNT],1
jmp WALK_SHOOT
not_ours:
test edx,edx
jne wait_here
jmp CONTINUE
wait_here:
add dword [edi+RALLY_COUNT],1
push ebx
call DO_SHOOTING
add esp,4
jmp TAIL
]]

-- UpdateHorseArcher, state 0x69, where it marks the unit free to react to enemies (unit
-- +0x3FC), which lets its stance send it after them. Not for the player's horse archers on
-- their way to the rally point: they shoot from the saddle and ride on. ebp = the owner.
templates.horseArcherNoChase = [[
cmp ebp,[LOCAL_PLAYER]
je skip
ORIGINAL
skip:
jmp RESUME
]]

-- findFreeCathedralAssemblyTile, at the top of its loop over the tiles around the monks'
-- rally point. edx = how many tiles have been tried. The game reads one fixed entry of the
-- table of offsets (the fourth) instead of entry edx, so it tries the same tile 49 times; if
-- that one is taken or out of reach, the monk walks to the cathedral's door instead. Read
-- entry edx, as the other rally point searches do. Replaces the two loads and the add.
templates.cathedralSearch = [[
movsx esi,word [OFFSETS_Y+edx*4]
add esi,[esp+0x14]
movsx edi,word [OFFSETS_X+edx*4]
jmp RESUME
]]

-- UpdateHorseArcher, state 4 (shooting). The rally point branch puts a horse archer into
-- this state without choosing which shot to play, and the shooting routine returns at once
-- for "no shot", so the unit stood there for ever. Start the first shot when none is set.
templates.horseArcherShootingState = [[
ORIGINAL
cmp word [esi+SHOOTING_VARIATION],0
jne shoot
mov word [esi+SHOOTING_VARIATION],4
shoot:
jmp RESUME
]]

-- TribesState::giveTribeMoveInstruction, where a unit is given its move order. A recruit
-- still carries "go to the rally point" until its first idle tick; drop it, or the unit
-- walks to the rally point as soon as it reaches the place it was sent to.
templates.moveOrder = [[
ORIGINAL
mov word [esi+GO_TO_RALLY_POINT],0
jmp RESUME
]]

-- updateUnits, just before it calls the unit's own update function. eax = unit id,
-- ecx = UnitsState + unit offset (unit fields at ecx + 0x614 + field, the U_ names).
-- A recruit of the player walking to its rally point (state 0x69) whose group has a
-- defensive or aggressive stance stays in state 0x69, so it keeps walking and following
-- its rally point as every recruit does. Melee units already look for enemies there by
-- their group's stance (state 0x69 marks them free to react, unit +0x3FC). Ranged units
-- (SHOOTS) get what a patrol's walking state does for them: every 32 ticks
-- acquireShootTarget(unit) and, with a target, giveTribeAnInstruction(group, 0x21, target,
-- its uid, 0), which stops the walk to shoot and keeps the destination in _someX_2/_someY_2
-- to walk on afterwards. Turning the walker into state 0x65 ourselves left units standing
-- (1.0.3): the game's own orders set up more than the state. Once the game has put such a
-- recruit into the walking state 0x65 for a fight, it is still counted towards its rally
-- slot, as state 0x69 does, so the next recruit gets a different tile at the rally point,
-- and melee units (REACTS) are marked free to react each tick, as a patrol route would,
-- so the stance and its range decide whether they go for the next enemy. A recruit
-- standing at the rally point (state 0x69, arrived) with a stance is marked free to react
-- as an idle unit is, whatever its type. So is one that has not left its tile for STILL_TICKS
-- while still "on its way": without a rally point the recruits gather at their building, and
-- those that find no free tile there stand about in that state for good (move status 2);
-- the game never counts them as arrived. Both are put on rally duty, so after dealing with
-- an enemy they go back to waiting there.
-- MARKS per unit id: bit 1 = such a recruit walking (counted), bit 0 = a recruit that is
-- still on rally duty (FOLLOW_UIDS holds its uid). Once on duty, a recruit that has been
-- idle (state 0 or 1, no target, nowhere to go back to) for IDLE_TICKS in a row is put back
-- into state 0x69, which waits at the rally point and walks to it again whenever it moves,
-- as for every vanilla recruit. Idle means one of the unit type's idle states (IDLE_MASKS:
-- bit n = state n; archers rest in 7, 8 and 0xB, most others in 1 to 3) - the targeting mode
-- (unit +0x39C) stays set after a fight, so it says nothing. Units pass through state 0
-- between shots and after a kill; taking them back at once would end every fight after the
-- first blow. Going back is done as the game sends a fresh recruit: goToRallyPoint set and
-- state 0, whose code finds a tile at the rally point and sets the walk up (a bare state
-- change leaves the walk half set up). While on duty, the recruit's own group (one member)
-- keeps the chosen stance. A unit's group is its own only while the group's uid (+0x34)
-- matches the unit's (+0x2E4) and the group is active: a freed group id is handed to other
-- groups, so the id alone can point at someone else's group (with its stance). Units on duty
-- whose group is gone or shared get a new one from addUnitToNewTribe, as fresh recruits do
-- (newGroupEntry/newGroupPlayer). Duty ends when the player selects the unit.
templates.fightOnTheWay = [[
push eax
push edx
push ebx
mov ebx,eax
cmp byte [DIAG_ON],0
je no_dump
mov eax,[GAME_TICKS]
sub eax,[DIAG]
cmp eax,DUMP_EVERY
jb no_dump
mov eax,[GAME_TICKS]
mov [DIAG],eax
pushad
call DUMP
popad
no_dump:
cmp ebx,MARK_COUNT
jae finish
test byte [MARKS+ebx],1
je duty_checked
mov eax,[ecx+U_UID]
cmp eax,[FOLLOW_UIDS+ebx*4]
jne off_duty
cmp word [ecx+U_SELECTED],0
jne off_duty
cmp byte [FOLLOW_ON],0
je off_duty
cmp byte [STANCE],0
je stance_kept
movsx eax,word [ecx+U_TRIBE]
test eax,eax
jle stance_kept
imul eax,eax,TRIBE_SIZE
mov edx,[eax+TRIBE_UIDS]
cmp edx,[ecx+U_TRIBE_UID]
jne stance_kept
cmp word [eax+TRIBE_ACTIVE],0
je stance_kept
cmp word [eax+TRIBE_COUNTS],1
jne stance_kept
movzx edx,byte [STANCE]
cmp word [eax+TRIBE_STANCES],dx
je stance_kept
mov word [eax+TRIBE_STANCES],dx
inc dword [DIAG+28]
stance_kept:
cmp word [ecx+U_LOGICAL],2
jne busy
movsx edx,word [ecx+U_TYPE]
cmp edx,80
jae busy
movzx eax,word [ecx+U_STATE]
cmp eax,16
jae busy
movzx edx,word [IDLE_MASKS+edx*2]
bt edx,eax
jnc busy
inc byte [IDLE+ebx]
cmp byte [IDLE+ebx],IDLE_TICKS
jb duty_checked
mov byte [IDLE+ebx],0
mov word [ecx+U_GO_TO_RALLY_POINT],1
mov word [ecx+U_STATE],0
mov word [ecx+U_RESUME_X],0
mov word [ecx+U_RESUME_Y],0
inc dword [DIAG+20]
jmp finish
busy:
mov byte [IDLE+ebx],0
jmp duty_checked
off_duty:
mov byte [MARKS+ebx],0
duty_checked:
movzx eax,word [ecx+U_STATE]
cmp eax,0x69
je walking_to_rally
cmp eax,0x65
jne unmark
test byte [MARKS+ebx],2
je finish
cmp word [ecx+U_MOVE_STATUS],0
je unmark
movsx edx,word [ecx+U_TYPE]
cmp edx,80
jae finish
cmp byte [REACTS+edx],0
je counted_only
mov word [ecx+U_FREE_TO_REACT],1
counted_only:
movzx edx,byte [SLOTS+edx]
cmp edx,0xFF
je finish
movsx eax,word [ecx+U_OWNER]
imul eax,eax,0x39F4
lea eax,[eax+edx*4]
add dword [eax+RALLY_COUNTERS],1
jmp finish
walking_to_rally:
movsx eax,word [ecx+U_OWNER]
cmp eax,[LOCAL_PLAYER]
jne finish
movsx eax,word [ecx+U_TRIBE]
test eax,eax
jle finish
imul eax,eax,TRIBE_SIZE
cmp word [eax+TRIBE_STANCES],0
je finish
cmp word [ecx+U_MOVE_STATUS],0
jne start_walking
mov word [ecx+U_FREE_TO_REACT],1
or byte [MARKS+ebx],1
mov eax,[ecx+U_UID]
mov [FOLLOW_UIDS+ebx*4],eax
jmp finish
start_walking:
or byte [MARKS+ebx],3
mov eax,[ecx+U_UID]
mov [FOLLOW_UIDS+ebx*4],eax
mov eax,[ecx+U_POSITION]
cmp eax,[LAST_POSITIONS+ebx*4]
je not_moved
mov [LAST_POSITIONS+ebx*4],eax
mov byte [STILL+ebx],0
jmp still_checked
not_moved:
cmp byte [STILL+ebx],STILL_TICKS
jae standing
inc byte [STILL+ebx]
jmp still_checked
standing:
mov word [ecx+U_FREE_TO_REACT],1
inc dword [DIAG+32]
still_checked:
movsx edx,word [ecx+U_TYPE]
cmp edx,80
jae finish
cmp byte [SHOOTS+edx],0
je finish
mov eax,[ecx+U_RNG]
xor eax,[GAME_TICKS]
test al,0x1F
jne finish
push ecx
push ebx
mov ecx,UNITS_STATE
call ACQUIRE_SHOOT_TARGET
pop ecx
test eax,eax
je finish
movsx edx,word [ecx+U_SHOOT_TARGET]
test edx,edx
jle finish
push ecx
push 0
imul eax,edx,0x490
push dword [eax+UNITS_STATE+U_UID]
push edx
push 0x21
movsx eax,word [ecx+U_TRIBE]
push eax
mov ecx,TRIBE_STATE
call GIVE_TRIBE_INSTRUCTION
pop ecx
inc dword [DIAG+12]
jmp finish
unmark:
and byte [MARKS+ebx],0xFD
finish:
pop ebx
pop edx
pop eax
ORIGINAL
jmp RESUME
]]

-- updateUnits, right after the unit's own update function (replays `mov eax, [current unit]`;
-- esi = UnitsState). A recruit walking to its rally point (MARKS bit 1, state 0x69, moving,
-- not standing about) whose group is aggressive runs instead of walking, if its type can:
-- the walking state 0x65 of those types runs with the animation sheet RUN_SHEETS and
-- stateBasedSpeed RUN_SPEEDS (the step size updateUnits hands to processUnitMove right after
-- this; 0 walks). The rally state sets the walking sheet every tick, so this goes after it.
templates.runWhenAggressive = [[
push ecx
push edx
mov eax,[CURRENT_UNIT]
cmp eax,MARK_COUNT
jae done
test byte [MARKS+eax],2
je done
cmp byte [STILL+eax],STILL_TICKS
jae done
mov ecx,eax
imul ecx,ecx,0x490
add ecx,esi
cmp word [ecx+U_STATE],0x69
jne done
cmp word [ecx+U_MOVE_STATUS],0
je done
movsx edx,word [ecx+U_TRIBE]
test edx,edx
jle done
imul edx,edx,TRIBE_SIZE
cmp word [edx+TRIBE_STANCES],2
jne done
movsx edx,word [ecx+U_TYPE]
cmp edx,80
jae done
cmp byte [RUN_SPEEDS+edx],0
je done
mov eax,[RUN_SHEETS+edx*4]
mov [ecx+U_ANIM_SHEET],eax
movzx edx,byte [RUN_SPEEDS+edx]
mov word [ecx+U_STATE_SPEED],dx
inc dword [DIAG+36]
done:
pop edx
pop ecx
mov eax,[CURRENT_UNIT]
jmp RESUME
]]

-- TribesState::addUnitToNewTribe, at its start. The game gives a unit its own group (the
-- thing that holds a stance) only in scenarios. In a skirmish, also let it through for a
-- fresh recruit of the human player when a recruit stance has been chosen.
-- Leaves ZF set to carry on, clear to return 0, for the `je` that follows the hook.
templates.newGroupEntry = [[
cmp dword [GAME_MODE],0
je allow
cmp dword [GAME_MODE],SKIRMISH_MODE
jne deny
cmp byte [STANCE],0
je deny
mov eax,[esp+4]
imul eax,eax,0x490
cmp word [eax+GO_TO_RALLY_POINT],0
jne ours
mov edx,[esp+4]
cmp edx,MARK_COUNT
jae deny
test byte [MARKS+edx],1
je deny
mov edx,[FOLLOW_UIDS+edx*4]
cmp edx,[eax+UID]
jne deny
ours:
movsx eax,word [eax+OWNER]
cmp eax,[LOCAL_PLAYER]
jne deny
allow:
xor eax,eax
jmp RESUME
deny:
or eax,1
jmp RESUME
]]

-- TribesState::addUnitToNewTribe, at `cmp dword [owner*4 + network ids], -1` (ecx = owner,
-- edi = unit offset). The game only makes groups for players whose network id is -1, and a
-- map gives the local player its slot number there instead, so the player's units never
-- got one here. Let the player's fresh recruits through while a recruit stance is chosen.
-- A recruit also keeps the group the peasant it was made from belonged to (one group shared
-- by many units), and the game only makes a group for a unit without one: so a fresh recruit
-- whose group does not have the chosen stance is taken out of it first (TribesState::
-- removeUnitFromTribe(unit, group), thiscall), and gets a group of its own below.
-- Leaves the flags for the `jne` that follows: ZF set = carry on.
templates.newGroupPlayer = [[
ORIGINAL
je done
cmp byte [STANCE],0
je not_ours
cmp ecx,[LOCAL_PLAYER]
jne not_ours
cmp word [edi+GO_TO_RALLY_POINT],0
jne ours
push eax
mov eax,[esp+0x10]
cmp eax,MARK_COUNT
jae duty_no
test byte [MARKS+eax],1
je duty_no
mov eax,[FOLLOW_UIDS+eax*4]
cmp eax,[edi+UID]
jne duty_no
pop eax
jmp ours
duty_no:
pop eax
jmp not_ours
ours:
inc dword [DIAG+4]
push ecx
push edx
push eax
movsx eax,word [edi+UNIT_GROUP]
test eax,eax
jle keep_group
mov edx,eax
imul edx,edx,TRIBE_SIZE
mov ecx,[edx+TRIBE_UIDS]
cmp ecx,[edi+UNIT_TRIBE_UID]
jne keep_group
cmp word [edx+TRIBE_ACTIVE],0
je keep_group
movzx ecx,byte [STANCE]
cmp word [edx+TRIBE_STANCES],cx
je keep_group
push eax
push dword [esp+0x1C]
mov ecx,TRIBES
call REMOVE_FROM_GROUP
inc dword [DIAG+24]
keep_group:
pop eax
pop edx
pop ecx
cmp ecx,ecx
jmp RESUME
not_ours:
test esp,esp
done:
jmp RESUME
]]

-- The walking state of archers, crossbowmen, Arab archers, slingers and fire throwers, at
-- the test that lets their stance stop them to shoot while they walk: on a patrol route,
-- or for a player whose network id is -1 - never the local player. ebx = unit id. Also
-- let it through for the player's recruits on their way to the rally point (MARKS bit 1) or
-- on rally duty (bit 0): after shooting they walk on in this state, and must keep stopping
-- to shoot instead of walking into the enemy.
-- Leaves the flags for the `jne` that follows: ZF set = stance applies.
templates.rangedWalkStance = [[
ORIGINAL
je done
cmp ebx,MARK_COUNT
jae not_ours
test byte [MARKS+ebx],3
je not_ours
inc dword [DIAG+16]
cmp ebx,ebx
jmp RESUME
not_ours:
test esp,esp
done:
jmp RESUME
]]

-- TribesState::addUnitToNewTribe, once the group exists. ecx = the group, edi = unit offset.
-- A fresh recruit of the human player, or one on rally duty, takes the chosen stance.
templates.newGroupStance = [[
cmp byte [STANCE],0
je done
cmp word [edi+GO_TO_RALLY_POINT],0
jne ours
mov edx,[esp+0xC]
cmp edx,MARK_COUNT
jae done
test byte [MARKS+edx],1
je done
mov edx,[FOLLOW_UIDS+edx*4]
cmp edx,[edi+UID]
jne done
ours:
movsx edx,word [edi+OWNER]
cmp edx,[LOCAL_PLAYER]
jne done
movzx edx,byte [STANCE]
mov word [ecx+STANCE_OFFSET],dx
inc dword [DIAG+8]
done:
push eax
mov eax,[esp+0x10]
jmp RESUME
]]

-- blit(image, x, y), cdecl: copies a picture onto the screen through the game's pencil
-- (which clips it). image: +0 width, +4 height, +8 RGB565 pixels, +0xC RGB555 pixels,
-- +0x10 one alpha byte per pixel: 0 = see-through, 255 = opaque. Pixels in between are
-- mixed with the screen the way the game fades its sprites, with the game's own blend
-- tables (BLEND_TABLES, built by BUILD_BLEND the first time, as the game's sprite drawing
-- does): 33 levels of 0x200 bytes, level L scales a colour by L/32, entry 8 * channel value
-- at +0 blue, +2 green, +4 red, already in place. A pixel of level L (alpha / 8, rounded)
-- is table L of the picture's colour plus table 32 - L of the screen's.
-- SCRATCH +20: the level, +24: the picture's part, +44: green mask, +48: pixel format.
templates.blit = [[
push ebp
push ebx
push esi
push edi
cmp word [BLEND_READY],0
jne blend_ready
call BUILD_BLEND
blend_ready:
mov ecx,PENCIL
call SETUP_SURFACE
mov esi,[esp+0x14]
mov eax,[esp+0x18]
mov edx,[esp+0x1C]
mov ecx,[esi+4]
lea ecx,[edx+ecx-1]
mov ebx,[esi]
lea ebx,[eax+ebx-1]
push 0
push ecx
push ebx
push edx
push eax
mov ecx,PENCIL
call SETUP_PENCIL
test eax,eax
je finished
mov eax,[PENCIL+0x30]
mov edx,[PENCIL+0x38]
cmp eax,edx
jle x_sorted
xchg eax,edx
x_sorted:
mov [SCRATCH],eax
mov [SCRATCH+4],edx
mov eax,[PENCIL+0x34]
mov edx,[PENCIL+0x3C]
cmp eax,edx
jle y_sorted
xchg eax,edx
y_sorted:
mov [SCRATCH+8],eax
mov [SCRATCH+12],edx
mov ebp,[esi+8]
mov dword [SCRATCH+44],0x3F
mov dword [SCRATCH+48],0x565
cmp dword [PIXEL_FORMAT],0x565
je format_known
mov ebp,[esi+0xC]
mov dword [SCRATCH+44],0x1F
mov dword [SCRATCH+48],0x555
format_known:
mov ebx,[SCRATCH+8]
next_row:
cmp ebx,[SCRATCH+12]
jg finished
mov edi,ebx
imul edi,[PENCIL+8]
add edi,[PENCIL+4]
mov eax,ebx
sub eax,[esp+0x1C]
imul eax,[esi]
sub eax,[esp+0x18]
mov [SCRATCH+16],eax
mov ecx,[SCRATCH]
next_pixel:
cmp ecx,[SCRATCH+4]
jg row_done
mov eax,[SCRATCH+16]
add eax,ecx
mov edx,[esi+0x10]
movzx edx,byte [edx+eax]
test edx,edx
je skip_pixel
add edx,4
shr edx,3
test edx,edx
je skip_pixel
cmp edx,32
jae opaque
mov [SCRATCH+20],edx
movzx eax,word [ebp+eax*2]
push ebx
push esi
mov esi,edx
shl esi,9
add esi,BLEND_TABLES
call blend_lookup
mov [SCRATCH+24],eax
movzx eax,word [edi+ecx*2]
mov esi,32
sub esi,[SCRATCH+20]
shl esi,9
add esi,BLEND_TABLES
call blend_lookup
add eax,[SCRATCH+24]
mov [edi+ecx*2],ax
pop esi
pop ebx
jmp skip_pixel
opaque:
movzx edx,word [ebp+eax*2]
mov [edi+ecx*2],dx
skip_pixel:
inc ecx
jmp next_pixel
row_done:
inc ebx
jmp next_row
finished:
pop edi
pop esi
pop ebx
pop ebp
ret
blend_lookup:
mov ebx,eax
and ebx,0x1F
movzx edx,word [esi+ebx*8]
mov ebx,eax
shr ebx,5
and ebx,[SCRATCH+44]
or dx,word [esi+ebx*8+2]
mov ebx,eax
cmp dword [SCRATCH+48],0x565
je red_565
shr ebx,10
and ebx,0x1F
jmp red_known
red_565:
shr ebx,11
red_known:
or dx,word [esi+ebx*8+4]
movzx eax,dx
ret
]]

-- drawButton(rect, image, hoverImage), cdecl: draws the hover picture while the mouse is
-- over the rect (x, y, w, h), the normal one otherwise.
templates.drawButton = [[
push esi
mov esi,[esp+8]
push dword [esi+12]
push dword [esi+8]
push dword [esi+4]
push dword [esi]
mov ecx,MOUSE
call IS_INSIDE
mov ecx,[esp+0xC]
test eax,eax
je chosen
mov ecx,[esp+0x10]
chosen:
push dword [esi+4]
push dword [esi]
push ecx
call BLIT
add esp,12
pop esi
ret
]]

-- Render function of the recruit portraits, cdecl, param = the portrait's unit type. Draws
-- the portrait the game's way, then its rally point button and, on the building's stance
-- portrait, the stance button. Where a button goes comes from the PLACES table, per unit
-- type and button (rally at +0, stance at +12): x, y relative to the portrait's top left,
-- and flags: 1 = measure x from the portrait's right edge, 2 = x is the button's right edge,
-- 4 = y counts from the bottom of the rally button, 8 = y is the button's bottom edge,
-- counted from the portrait's bottom edge. Remembers each button's rectangle and
-- the frame it was drawn in, for the click handler.
templates.renderPortrait = [[
push ebx
push esi
push edi
push ebp
mov esi,[esp+0x14]
cmp esi,80
jae leave_now
push dword [BUTTON_Y]
push dword [BUTTON_X]
push dword [BUTTON_W]
push dword [BUTTON_H]
push esi
call dword [ORIGINAL_RENDER+esi*4]
add esp,4
mov dword [TIP],-1
mov ebp,esi
imul ebp,ebp,24
add ebp,PLACES
mov edi,RALLY_IMAGE
mov ebx,esi
shl ebx,4
add ebx,RALLY_RECTS
call place_button
cmp byte [RALLY_ON],0
je stance_part
mov eax,[FRAME]
mov [RALLY_STAMPS+esi*4],eax
push RALLY_IMAGE_HOVER
push edi
push ebx
call DRAW_BUTTON
add esp,12
call mouse_over
je stance_part
mov dword [TIP],0
stance_part:
cmp byte [STANCE_HOSTS+esi],0
je tip_part
movzx eax,byte [STANCE]
mov edi,[STANCE_IMAGES+eax*4]
add ebp,12
mov ebx,esi
shl ebx,4
add ebx,STANCE_RECTS
call place_button
mov eax,[FRAME]
mov [STANCE_STAMPS+esi*4],eax
movzx eax,byte [STANCE]
push dword [STANCE_IMAGES+12+eax*4]
push edi
push ebx
call DRAW_BUTTON
add esp,12
call mouse_over
je tip_part
movzx eax,byte [STANCE]
inc eax
mov [TIP],eax
tip_part:
mov eax,[TIP]
cmp eax,0
jl all_done
push dword [TIPS+eax*4]
push esi
push dword [esp+0x14]
push dword [esp+0x14]
call TOOLTIP
add esp,16
all_done:
add esp,16
leave_now:
pop ebp
pop edi
pop esi
pop ebx
ret
mouse_over:
push dword [ebx+12]
push dword [ebx+8]
push dword [ebx+4]
push dword [ebx]
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
ret
place_button:
mov eax,[ebp]
test byte [ebp+8],1
je not_from_right
add eax,[esp+8]
not_from_right:
test byte [ebp+8],2
je not_right_edge
sub eax,[edi]
not_right_edge:
add eax,[esp+12]
mov [ebx],eax
mov eax,[ebp+4]
test byte [ebp+8],4
je not_under_rally
mov edx,esi
shl edx,4
add eax,[RALLY_RECTS+edx+4]
add eax,[RALLY_RECTS+edx+12]
jmp y_known
not_under_rally:
test byte [ebp+8],8
je y_from_top
add eax,[esp+4]
sub eax,[edi+4]
y_from_top:
add eax,[esp+16]
y_known:
mov [ebx+4],eax
mov eax,[edi]
mov [ebx+8],eax
mov eax,[edi+4]
mov [ebx+12],eax
ret
]]

-- tooltip(x, y, unit, text), cdecl: the button's help text, one line of the panel's own
-- text style. x, y = where the portrait was drawn; the panel's origin is that minus the
-- portrait's place in the menu (ITEM_PLACES), and the text goes to TIP_PLACES for the unit:
-- above or under the unit's name and cost, wherever there is room, on the same layer the
-- game draws that line on (TextManager +0x1C): on the interface (barracks, mercenary post)
-- the layer the menu is drawn on is left as it is, as "Available peasants" does - forcing
-- another one there turned the beige pink; the map, shifted by the camera, where it lies
-- above the panel (guilds, cathedral - TIP_LAYERS 1). The layer is put back afterwards.
templates.tooltip = [[
push esi
push edi
push dword [TEXT_MANAGER+0x1C]
mov esi,[esp+0x18]
mov edi,[esp+0x10]
sub edi,[ITEM_PLACES+esi*8]
add edi,[TIP_PLACES+esi*8]
mov eax,[esp+0x14]
sub eax,[ITEM_PLACES+esi*8+4]
add eax,[TIP_PLACES+esi*8+4]
cmp byte [TIP_LAYERS+esi],0
je layer_chosen
mov dword [TEXT_MANAGER+0x1C],1
add edi,[CAMERA_X]
add eax,[CAMERA_Y]
layer_chosen:
push 0
push 0
push FONT
push 0
push COLOUR
push 0
push eax
push edi
push dword [esp+0x3C]
mov ecx,TEXT_MANAGER
call SHADOWED_TEXT
pop dword [TEXT_MANAGER+0x1C]
pop edi
pop esi
ret
]]

-- Action of the first item of each recruiting building's menu block, cdecl. The game calls
-- it every frame before any other item of the block, so a click on one of the buttons is
-- seen here first: it is handled and taken away from the mouse, so the portrait under the
-- button does not recruit and nothing else sees it. Only buttons drawn in the last frame
-- count. Otherwise the game's own action runs.
templates.frameClick = [[
push ebx
push esi
inc dword [FRAME]
cmp dword [MOUSE+LEFT_CLICK],0
je pass_on
mov esi,[FRAME]
dec esi
xor ebx,ebx
check_type:
cmp ebx,80
jae pass_on
cmp byte [STANCE_HOSTS+ebx],0
je check_rally
cmp [STANCE_STAMPS+ebx*4],esi
jl check_rally
mov eax,ebx
shl eax,4
push dword [STANCE_RECTS+eax+12]
push dword [STANCE_RECTS+eax+8]
push dword [STANCE_RECTS+eax+4]
push dword [STANCE_RECTS+eax]
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je check_rally
movzx eax,byte [STANCE]
inc eax
cmp eax,3
jb stance_set
xor eax,eax
stance_set:
mov [STANCE],al
push CLICK_SOUND
mov ecx,SOUNDS
call PLAY_SOUND
jmp consumed
check_rally:
cmp byte [RALLY_ON],0
je next_type
cmp dword [RALLY_COMMANDS+ebx*4],0
je next_type
cmp [RALLY_STAMPS+ebx*4],esi
jl next_type
mov eax,ebx
shl eax,4
push dword [RALLY_RECTS+eax+12]
push dword [RALLY_RECTS+eax+8]
push dword [RALLY_RECTS+eax+4]
push dword [RALLY_RECTS+eax]
mov ecx,MOUSE
call IS_INSIDE
test eax,eax
je next_type
push dword [RALLY_COMMANDS+ebx*4]
call TOOLBAR_BUTTON
add esp,4
jmp consumed
next_type:
inc ebx
jmp check_type
consumed:
mov dword [MOUSE+LEFT_CLICK],0
pop esi
pop ebx
ret
pass_on:
pop esi
pop ebx
jmp dword [ORIGINAL_FRAME_ACTION]
]]

return templates
