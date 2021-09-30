local event = require("event")
local fs = require("filesystem")
local shell = require("shell")
local tty = require("tty")
local unicode = require("unicode")
local tx = require("transforms")
local text = require("text")
local term = require("term")

local BWIDTH = 52
local BHEIGHT = 16


local DISABLE_DRAW = false


local setColor = nil
local setInverseColor = nil
local updateNextView = function() end

local memo = function(fn)
  local oarg = {}
  return function(...)
    for i,v in ipairs(arg) do
      if oarg[i] ~= v then
        return fn(table.unpack(arg))
      end
    end
    return false
  end 
end

local Line = function() return function(x, y, width, padding, is_selected, text, color)
  text = text or ""
  term.setCursor(x, y)
  if is_selected then setInverseColor() end
  if #text > width - 2*padding then
    text = string.rep(" ", padding) .. text:sub(1, width - 2*padding - 1) .. "~" .. string.rep(" ", padding)
  else
    text = string.rep(" ", padding) .. text .. string.rep(" ", width - padding - #text)
  end

  term.write(text)
  if is_selected then setColor() end
end end 

local List = function()
  local children = {}
  local offset = 0
  local last_height = nil 
  return function(x, y, width, height, items, selected_item)
    local size = math.min(#items, height)

    if #children ~= height then
      if #children > height then
        children = {table.unpack(children, 1, height)}
      elseif #children < height then
        for i = #children + 1, height do
          children[i] = Line()
        end
      end
    end
   
   
    if not last_height or last_height ~= height then
      offset = 0
      last_height = height 
    end

    if selected_item then -- rework offset saving
      if selected_item > #children + offset then
        offset = selected_item - #children
      elseif selected_item < offset + 1 then 
        offset = selected_item - 1
      end
    else
      offset = 0  
    end
    


    for i = 1, #children do
      children[i](x+1, y+i-1, width, 1, (i + offset) == selected_item, items[i+offset], OxFFFFFF )
    end
  end  
end

local DirectoryList = function()
  local list = List()
  return function(x, y, width, height, stats, selected_path)
    local items = {}
    local selected_item = nil
    for i = 1,#stats do
      local entry = stats
      items[#items+1] = stats[i].name
      if stats[i].full_path == selected_path then selected_item = i end 
    end    

    list(x, y, width, height, items, selected_item)
  end
end

local es = 0
local function perr(msg) io.stderr:write(msg, "\n") ec = 2 os.exit()  end

setColor = function(c)
  io.write(string.char(0x1b), "[", c or "", "m")
end

setInverseColor = function()
  io.write(string.char(0x1b), "[30;1;47m")
end

local function filter(names)
  return names
end

local function sort(names)
  local function sorter(key)
    table.sort(names, function(a, b)
      return a[key] < b[key]
    end)
  end
  sorter("sort_name")
  return names
end

local function stat(path, name) 
  local info = {}
  info.key = name
  info.path = name:sub(1,1) == "/" and "" or path
  info.full_path = fs.concat(info.path, name)
  info.is_dir = fs.isDirectory(info.full_path)
  info.name = name:gsub("/+$", "")
  info.sort_name = info.name:gsub("^%.", "")
  info.isLink, info.link = fs.isLink(info.full_path)
  info.size = info.isLink and 0 or fs.size(info.full_path)
  info.time = fs.lastModified(info.full_path)
  info.fs = fs.get(info.full_path)
  info.ext = info.name:match("(%.[^.]+)$") or ""
  return info
end

local function loadDir(dir)
  local path = shell.resolve(dir)

  local list, reason = fs.list(path)
  if not list then
    perr(reason)
  else
    local names = { path = path }
    for name in list do
      names[#names + 1] = stat(path, name)
    end
    return names
  end
end 



local per_curr_width = 0.333
local per_next_width = 0.5
--local selected_prev = 2
--local selected = 1
local gaps = 6

local prev = "/"
local cwd = shell.getWorkingDirectory()
local next = "/"

local position_store = {}



--local _prev_selected = 1
local _curr_selected = 1
--local _next_selected = 1

local prev_list = {}
local curr_list = {}
local next_list = {}

local function find_stat(stat_list, full_path)
  for i, entry in ipairs(stat_list) do
    if entry.full_path == full_path then
      return i, entry
    end    
  end
  return nil
end

local PrevDir = DirectoryList()
local CurrDir = DirectoryList()
local NextDir = DirectoryList()

local updateLists = function()
  curr_list = sort(loadDir(cwd))

  if position_store[cwd] == nil and #curr_list > 0 then position_store[cwd] = curr_list[1].full_path end
  _curr_selected = find_stat(curr_list, position_store[cwd])

  if _curr_selected == nil and #curr_list > 0 then
    _curr_selected = 1
    position_store[cwd] = curr_list[1].full_path
  end


  prev = shell.resolve(cwd .. "/..")
  if cwd == "/" then prev_list = {}
  else
    prev_list = sort(loadDir(prev))
    if position_store[prev] == nil and #prev_list > 0 then position_store[prev] = cwd end
  end

  updateNextView()
end

updateNextView = function()
  local found = curr_list[_curr_selected]

  if found and found.is_dir then
    next = found.full_path
    next_list = sort(loadDir(next))
    if position_store[next] == nil and #next_list > 0 then position_store[next] = next_list[1].full_path end
  else 
    next_list = {}
  end
end

local function performLeft()
  cwd = shell.resolve(cwd .. "/..") 
  shell.setWorkingDirectory(cwd)
  

  updateLists()
end

local function performRight()
  local entry = curr_list[_curr_selected]

  if entry.is_dir then
    cwd = entry.full_path
    shell.setWorkingDirectory(entry.full_path)
  end

  updateLists()
end

local function performUp()
  local i = find_stat(curr_list, position_store[cwd])
  if not i then i = 1 end
  --assert(i ~= nil, "performUp: find_stat nil for ".. position_store[cwd])  

  if i ~= 1 then
    _curr_selected = i - 1
    position_store[cwd] = curr_list[_curr_selected].full_path
    updateNextView()
  end
end

local function performDown()
  local i = find_stat(curr_list, position_store[cwd])
  if not i then i = 1 end

  if i ~= #curr_list then
    _curr_selected = i + 1
    position_store[cwd] = curr_list[_curr_selected].full_path
    updateNextView()
  end

end

local function display()
  local width, height, x, y, rx, ry = term.getViewport()
  local list_height = height - 1
  local gpu = term.gpu()
  local x, y = 1, 1
  term.setCursor(x, y)
  --term.clear()
  width = BWIDTH
  height = BHEIGHT
  if DISABLE_DRAW then return true end

  --local cwd = shell.getWorkingDirectory()
  --local cwd_names = loadDir(cwd)

  local max_name_length = 1
  
  for _, entry in ipairs(curr_list) do
    local name = entry.name
    local length = #name
    if max_name_length < length then
      max_name_length = length
    end
  end

  local list_gap = 1
  local list_height = height - 2 * list_gap
  local list_y = 1 + list_gap
  
  local prev_gap = 1 -- before 
  local curr_gap = 2
  local next_gap = 2
  local end_gap = 1

  local curr_width = math.ceil(width * per_curr_width)
  local next_width = math.ceil(width * per_next_width)
  local prev_width = width - end_gap - next_width - next_gap - curr_width - curr_gap - prev_gap


  --max_name_length = math.max(max_name_length, math.ceil(width * main_column))
  -- if max_name_length > 
  --local prd = shell.resolve(cwd .. "/..")
  --if prd ~= "/" then 
  --local prd_names = loadDir(prd)

  local prev_x = 1 + prev_gap
  if prev_width > 6 then
    PrevDir(prev_x, list_y, prev_width, list_height, prev_list, position_store[prev])
  else 
    curr_width = curr_width + prev_width + curr_gap
  end

  local curr_x = prev_x + prev_width + curr_gap
  CurrDir(curr_x, list_y, curr_width, list_height, curr_list, position_store[cwd])

  local next_x = curr_x + curr_width + next_gap
  NextDir(next_x, list_y, next_width, list_height, next_list, position_store[next])

  --[[
  prev_selected = position_store[prev]
  for i = 1, math.min(list_height, #prev_list) do
    local entry = prev_list[i]
    local name = entry.name
    term.setCursor(x, y)
    if prev_selected == y then
      gpu.setBackground(0xFFFFFF)
      gpu.setForeground(0x000000)
    end
    gpu.fill(x, y, prev_length, 1, " ")
    
    local n = name
    if #n > prev_length - 1 then
      n = name:sub(1, prev_length-1) .. "~"
    end

    term.write(n)

    if prev_selected == y then
      gpu.setBackground(0x000000)
      gpu.setForeground(0xFFFFFF)
    end

    y = y + 1
    
  end
 


  local main_offset = width - max_name_length - math.ceil(width * content_column) - gaps + 3 -- do proper gaps 

  x = 1 + main_offset
  y = 1
  curr_selected = position_store[cwd]
  for i = 1, math.min(list_height, #curr_list) do
    local entry = curr_list[i]
    local name = entry.name
    term.setCursor(x, y)
    if curr_selected == y then
      gpu.setBackground(0xFFFFFF)
      gpu.setForeground(0x000000)
    end
    gpu.fill(x, y, max_name_length, 1, " ")
    local n = name
    term.write(n)
    if curr_selected == y then
      gpu.setBackground(0x000000)
      gpu.setForeground(0xFFFFFF)
    end

    y = y + 1
  end

  --local lookup_entry = cwd_names[selected]
  --if not lookup_entry.isDir then return true end

  local content_width = math.ceil(width * content_column) - 2
  local content_offset = width - content_width - 1 -- do proper gaps
  --local names_next = loadDir(lookup_entry.full_path)
  x = content_width + 1
  y = 1
  next_selected = position_store[next]
  for i = 1, math.min(list_height, #next_list) do
    local entry = next_list[i]
    term.setCursor(x, y)
    if next_selected == y then
      setInverseColor()
    end
    local n = entry.name
    if #n > content_width - 2 then
      n =  n:sub(1, content_width-3) .. "~" 
    else 
      n = " " .. n .. string.rep(" ", content_width - #n + 1) 
    end
    term.write(n)
    setColor()
    
    y = y + 1
  end
  ]]--
end



local function prepare_main()
  term.clear()
end

local cwd = shell.getWorkingDirectory()
prepare_main()
local cwd_names = loadDir(cwd)

updateLists()
display()

local keyDownId = event.listen("key_down", function(_, _, char)
  if char == ("j"):byte(1) then
    performDown()
  elseif char == ("k"):byte(1) then
    performUp()
  elseif char == ("h"):byte(1) then
    performLeft()
  elseif char == ("l"):byte(1) then
    performRight()
  end
  display()
end)


local running = true
while running do
  local id = event.pull()
  if id == "interrupted" then
    running = false
    event.cancel(keyDownId)
  end
end