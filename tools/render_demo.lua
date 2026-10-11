-- Render the actual UI with sample titles, without reading anyone's windows.
-- Run in Hammerspoon: dofile('/path/to/mac-alt-tab-switcher/tools/render_demo.lua')
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tools/render_demo.lua$')
local switcher = dofile(root .. '/MacAltTab.spoon/init.lua')
switcher.results = {
  {app='Finder', title='Projects', bundle='com.apple.finder'},
  {app='Safari', title='Hammerspoon documentation', bundle='com.apple.Safari'},
  {app='Terminal', title='mac-alt-tab-switcher', bundle='com.apple.Terminal'},
  {app='Notes', title='Weekend plans', bundle='com.apple.Notes'},
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
