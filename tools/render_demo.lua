-- Render the actual UI with sample titles, without reading anyone's windows.
-- Run in Hammerspoon: dofile('/path/to/flicktab/tools/render_demo.lua')
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tools/render_demo.lua$')
local switcher = dofile(root .. '/FlickTab.spoon/init.lua')
switcher.results = {
  {app='Finder', title='Projects', bundle='com.apple.finder'},
  {app='Google Chrome', title='Hammerspoon - Getting Started - Google Chrome', bundle='com.google.Chrome'},
  {app='Google Chrome', title='eshanarora.com - Google Chrome', bundle='com.google.Chrome'},
  {app='Ghostty', title='~/stuff/tools/flicktab', bundle='com.mitchellh.ghostty'},
  {app='Code', title='README.md — FlickTab', bundle='com.microsoft.VSCode'},
}
for _,item in ipairs(switcher.results) do
  item.icon = hs.image.imageFromAppBundle(item.bundle)
end
switcher.active, switcher.query, switcher.selected = true, '', 2
local ok, err = xpcall(function()
  switcher:render()
  local _, canvas = next(switcher.canvases)
  assert(canvas:imageFromCanvas():saveToFile(root .. '/assets/switcher.png'))
end, debug.traceback)
switcher:finish(false)
assert(ok, err)
print('Saved assets/switcher.png using sample windows')
