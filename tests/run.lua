-- Run in the Hammerspoon Console: dofile('/path/to/flicktab/tests/run.lua')
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/run.lua$')
local switcher = dofile(root .. '/FlickTab.spoon/init.lua')
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end

check(switcher.fuzzyScore('slakc', 'Slack') ~= nil, 'Transposition should match')
check(switcher.fuzzyScore('slk', 'Slack') ~= nil, 'Abbreviation should match')
check(switcher.fuzzyScore('zzzz', 'Safari') == nil, 'Unrelated words should not match')
check(switcher.fuzzyScore('slack', 'Slack') > switcher.fuzzyScore('slk', 'Slack'), 'Exact match should win')
check(switcher.backspace('café') == 'caf', 'Backspace removes one UTF-8 character')
check(switcher.backspace('') == '', 'Empty backspace is safe')
local items = {{app='Safari', title='Docs'}, {app='Safari', title='Docs'}}
local ranked = switcher.rank(items, 'safari')
check(ranked[1] == items[1] and ranked[2] == items[2], 'Ties preserve recency')

-- Reproduce the app-disappeared race without reading real windows.
local originalFocus = hs.window.focusedWindow
local originalSecure = hs.eventtap.isSecureInputEnabled
local originalScreens = hs.screen.allScreens
local ok, err = xpcall(function()
  hs.window.focusedWindow = function() return nil end
  hs.eventtap.isSecureInputEnabled = function() return false end
  local calls = 0
  local stale = {
    application = function() calls = calls + 1; return calls > 1 and {} or nil end,
    id = function() return 7 end,
    isStandard = function() return true end,
  }
  switcher.filter = {getWindows=function() return {stale} end}
  check(switcher:begin(false) == false, 'Skip a window whose app disappeared')
  switcher.filter = nil

  hs.eventtap.isSecureInputEnabled = function() return true end
  switcher.active, switcher.selected = true, 1
  switcher.results = {{id=123}}
  check(switcher:handle({getType=function() return hs.eventtap.event.types.flagsChanged end,
    getFlags=function() return {} end}) == false, 'Secure Input events pass through')
  check(not switcher.active, 'Secure Input cancels before modifier release can focus a window')

  -- A small synthetic screen catches overflow without depending on monitor setup.
  hs.screen.allScreens = function() return {{id=function() return 'test' end,
    frame=function() return {x=0,y=0,w=800,h=600} end}} end
  switcher.active, switcher.query, switcher.selected, switcher.results = true, '', 100, {}
  for i=1,100 do switcher.results[i]={app='Example',title='Window '..i} end
  switcher:render()
  local canvas = switcher.canvases.test
  check(canvas:frame().h <= 560, 'Window list fits available height')
  local found = false
  for _,element in ipairs(canvas:canvasElements()) do
    if element.text == 'Window 100' then found = true end
  end
  check(found, 'Selected row remains visible at end of a long list')
end, debug.traceback)
switcher:finish(false)
hs.window.focusedWindow = originalFocus
hs.eventtap.isSecureInputEnabled = originalSecure
hs.screen.allScreens = originalScreens
assert(ok, err)
print('FlickTab: '..count..' regression checks passed')
return count
