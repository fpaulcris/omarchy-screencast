local VIRTUAL = "__OUTPUT__"
local MODE = "__MODE__"
local WANTED = __WANTED__

local function laptop_mon()
  local mons = hl.get_monitors()
  for _, mon in ipairs(mons) do
    if mon.name:sub(1, 3) == "eDP" then return mon end
  end
  for _, mon in ipairs(mons) do
    if mon.name ~= VIRTUAL and mon.name:sub(1, 8) ~= "HEADLESS" then return mon end
  end
  return mons[1]
end

local function cursor_on(mon, x, y)
  if not mon or not x or not y then return false end
  local scale = mon.scale
  if not scale or scale == 0 then scale = 1 end
  local w = mon.width / scale
  local h = mon.height / scale
  return x >= mon.x and y >= mon.y and x < mon.x + w and y < mon.y + h
end

local function focus_laptop(laptop)
  local active = hl.get_active_monitor()
  if not active or active.name ~= laptop.name then
    hl.dispatch(hl.dsp.focus({ monitor = laptop.name }))
  end
end

local function restore_cursor(x, y, laptop)
  if cursor_on(laptop, x, y) then
    hl.dispatch(hl.dsp.cursor.move({ x = x, y = y }))
  end
end

local function free_id()
  local used = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 then used[ws.id] = true end
  end
  for i = 1, 20 do
    if not used[i] then return i end
  end
  return 21
end

local function park_id(laptop, wanted)
  local below, above = nil, nil
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and not ws.special and ws.monitor and ws.monitor.name == laptop.name and ws.id ~= wanted then
      if ws.id < wanted and (not below or ws.id > below) then below = ws.id end
      if ws.id > wanted and (not above or ws.id < above) then above = ws.id end
    end
  end
  return below or above or free_id()
end

local function owned_by_virtual(ident)
  local ws = hl.get_workspace(tostring(ident))
  return ws and ws.monitor and ws.monitor.name == VIRTUAL
end

local point = hl.get_cursor_pos()
local cursor_x = point and point.x or nil
local cursor_y = point and point.y or nil
local laptop = laptop_mon()
if not laptop then error("no laptop screen") end

if MODE == "focus" then
  focus_laptop(laptop)
  __line = "ok focus"
  return
end

if MODE == "borrow" then
  -- The user opened the cast desktop. Put it on the laptop and show it there.
  local ws = hl.get_workspace(tostring(WANTED))
  if ws and ws.monitor and ws.monitor.name ~= laptop.name then
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(WANTED), monitor = laptop.name }))
  end
  focus_laptop(laptop)
  local now = laptop_mon()
  if not now or not now.active_workspace or now.active_workspace.id ~= WANTED then
    hl.dispatch(hl.dsp.focus({ workspace = tostring(WANTED) }))
  end
  __line = "ok borrow"
  return
end

if MODE == "release" then
  focus_laptop(laptop)
  local virt = hl.get_monitor(VIRTUAL)
  if not virt then
    restore_cursor(cursor_x, cursor_y, laptop)
    __line = "ok release"
    return
  end
  local active_id = virt.active_workspace and virt.active_workspace.id or 0
  local inactive = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL and ws.id ~= active_id then
      inactive[#inactive + 1] = ws.id
    end
  end
  for _, id in ipairs(inactive) do
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = laptop.name }))
  end
  virt = hl.get_monitor(VIRTUAL)
  if virt and virt.active_workspace and virt.active_workspace.id and virt.active_workspace.id > 0 then
    local owner = virt.active_workspace.monitor
    if owner and owner.name == VIRTUAL then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(virt.active_workspace.id), monitor = laptop.name }))
    end
  end
  focus_laptop(laptop)
  restore_cursor(cursor_x, cursor_y, laptop_mon())
  __line = "ok release"
  return
end

local virt = hl.get_monitor(VIRTUAL)
if not virt then error("virtual screen is missing") end

local function has_stray()
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and ws.id ~= WANTED and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL then
      return true
    end
  end
  return false
end

local shown = virt.active_workspace and virt.active_workspace.id or 0
if shown == WANTED and owned_by_virtual(WANTED) and not has_stray() then
  local active = hl.get_active_monitor()
  if not active or active.name ~= laptop.name then
    focus_laptop(laptop)
  end
  __line = "ok same"
  return
end

local stay = laptop.active_workspace and laptop.active_workspace.id or 0
local parked = 0
if stay == WANTED then
  parked = park_id(laptop, WANTED)
  focus_laptop(laptop)
  hl.dispatch(hl.dsp.focus({ workspace = tostring(parked) }))
  laptop = laptop_mon()
  stay = laptop and laptop.active_workspace and laptop.active_workspace.id or 0
  if stay == WANTED then error("could not leave the desktop before moving it") end
end

if not owned_by_virtual(WANTED) then
  local ws = hl.get_workspace(tostring(WANTED))
  if ws then
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(WANTED), monitor = VIRTUAL }))
  else
    hl.dispatch(hl.dsp.focus({ monitor = VIRTUAL }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(WANTED) }))
    focus_laptop(laptop)
    if stay > 0 then
      local stay_ws = hl.get_workspace(tostring(stay))
      if stay_ws and stay_ws.monitor and stay_ws.monitor.name == laptop.name then
        local now = hl.get_monitor(laptop.name)
        if not now or not now.active_workspace or now.active_workspace.id ~= stay then
          hl.dispatch(hl.dsp.focus({ workspace = tostring(stay) }))
        end
      end
    end
  end
end

if not owned_by_virtual(WANTED) then error("desktop did not move onto the virtual screen") end

virt = hl.get_monitor(VIRTUAL)
if not virt or not virt.active_workspace or virt.active_workspace.id ~= WANTED then
  virt = hl.get_monitor(VIRTUAL)
  virt:set_workspace({ workspace = tostring(WANTED) })
end

local leftovers = {}
for _, ws in ipairs(hl.get_workspaces()) do
  if ws.id and ws.id > 0 and ws.id ~= WANTED and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL then
    leftovers[#leftovers + 1] = ws.id
  end
end
for _, id in ipairs(leftovers) do
  hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = laptop.name }))
end

laptop = laptop_mon()
focus_laptop(laptop)
if stay > 0 then
  local stay_ws = hl.get_workspace(tostring(stay))
  if stay_ws and stay_ws.monitor and stay_ws.monitor.name == laptop.name then
    local now = hl.get_monitor(laptop.name)
    if not now or not now.active_workspace or now.active_workspace.id ~= stay then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(stay) }))
    end
  end
end
laptop = laptop_mon()
restore_cursor(cursor_x, cursor_y, laptop)
local vnow = hl.get_monitor(VIRTUAL)
local lnow = laptop_mon()
local focus = hl.get_active_monitor()
__line = "ok park=" .. tostring(parked)
  .. " virtual=" .. tostring(vnow and vnow.active_workspace and vnow.active_workspace.id or 0)
  .. " laptop=" .. tostring(lnow and lnow.active_workspace and lnow.active_workspace.id or 0)
  .. " focus=" .. tostring(focus and focus.name or "")
