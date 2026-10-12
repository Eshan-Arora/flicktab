-- Hold Command throughout: Tab, type, Tab/Shift-Tab, release Command.
-- No network, subprocesses, saved queries, or saved window titles.
local M = {
  name = 'FlickTab', version = '0.1.0', author = 'Eshan Arora',
  homepage = 'https://github.com/Eshan-Arora/flicktab',
  active = false, enabled = false, consumed = {},
}
local types = hs.eventtap.event.types
local keys = hs.keycodes.map
local log = hs.logger.new('FlickTab', 'warning')

-- Control Center exposes its temporary panels to Accessibility as standard
-- windows, but their window IDs disappear as soon as the panel is dismissed.
-- They are system UI, not destinations a Command-Tab switcher can focus.
local excludedBundleIDs = { ['com.apple.controlcenter'] = true }
local firefoxBundleID = 'org.mozilla.firefox'

-- With full-screen-api.macos-native-full-screen disabled, Firefox exposes a
-- website-fullscreen window as AXUnknown rather than AXStandardWindow. Accept
-- only the screen-filling Firefox instance; Firefox also exposes smaller
-- internal AXUnknown windows that should not appear in the switcher.
function M.isFirefoxLegacyFullscreen(win, app)
  if not win or not app or app:bundleID() ~= firefoxBundleID
    or win:subrole() ~= 'AXUnknown' then return false end
  local screen = win:screen()
  if not screen then return false end
  local frame, fullFrame = win:frame(), screen:fullFrame()
  return fullFrame.area > 0 and frame:intersect(fullFrame).area >= fullFrame.area * 0.95
end

function M.isSwitchableWindow(win, app)
  if not win then return false end
  app = app or win:application()
  return app ~= nil and not excludedBundleIDs[app:bundleID()]
    and win:id() ~= nil
    and (win:isStandard() or M.isFirefoxLegacyFullscreen(win, app))
end

-- The base scoring tiers are a Lua port of better-discord-quick-switcher:
-- exact, substring, multi-token, and ordered-subsequence matches. The bounded
-- Damerau-Levenshtein fallback below adds typo and transposition tolerance.
function M.normalizeSearchText(value)
  return value:lower():gsub('[-_#/]+', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
end

local function chars(value)
  local result = {}
  for _, codepoint in utf8.codes(value) do
    result[#result + 1] = utf8.char(codepoint)
  end
  return result
end

-- Optimal String Alignment distance: insertion, deletion, substitution, and an
-- adjacent transposition each cost one edit. The optional limit lets callers
-- skip strings whose length difference already makes a match impossible.
function M.damerauLevenshtein(leftValue, rightValue, limit)
  local left, right = chars(leftValue), chars(rightValue)
  local leftLength, rightLength = #left, #right
  if limit and math.abs(leftLength - rightLength) > limit then return limit + 1 end
  if leftLength == 0 then return rightLength end
  if rightLength == 0 then return leftLength end

  local previousPrevious, previous = nil, {}
  for column = 0, rightLength do previous[column] = column end

  for row = 1, leftLength do
    local current = {[0] = row}
    for column = 1, rightLength do
      local substitutionCost = left[row] == right[column] and 0 or 1
      local distance = math.min(
        previous[column] + 1,
        current[column - 1] + 1,
        previous[column - 1] + substitutionCost
      )
      if previousPrevious and row > 1 and column > 1
        and left[row] == right[column - 1] and left[row - 1] == right[column] then
        distance = math.min(distance, previousPrevious[column - 2] + 1)
      end
      current[column] = distance
    end
    previousPrevious, previous = previous, current
  end
  return previous[rightLength]
end

local function allowedEdits(length)
  if length <= 2 then return 0 end
  if length <= 5 then return 1 end
  if length <= 9 then return 2 end
  return math.min(4, math.floor(length * 0.25))
end

local function words(value)
  local result = {}
  for word in value:gmatch('%S+') do result[#result + 1] = word end
  return result
end

-- Compare query words with distinct candidate words. Bounded edit counts keep
-- short queries from spraying matches everywhere, while still accepting common
-- typos, missing/extra letters, and adjacent transpositions.
function M.typoScore(queryValue, candidateValue)
  local queryWords = words(M.normalizeSearchText(queryValue))
  local candidateWords = words(M.normalizeSearchText(candidateValue))
  if #queryWords == 0 or #queryWords > #candidateWords then return nil end

  local used, similarities, totalDistance = {}, {}, 0
  local lastCandidateIndex, ordered = 0, true
  for queryIndex, queryWord in ipairs(queryWords) do
    local queryLength = utf8.len(queryWord) or #queryWord
    local limit = allowedEdits(queryLength)
    local bestSimilarity, bestIndex, bestDistance
    for candidateIndex, candidateWord in ipairs(candidateWords) do
      if not used[candidateIndex] then
        local candidateLength = utf8.len(candidateWord) or #candidateWord
        if math.abs(queryLength - candidateLength) <= limit then
          local distance = M.damerauLevenshtein(queryWord, candidateWord, limit)
          if distance <= limit then
            local similarity = 1 - distance / math.max(queryLength, candidateLength)
            if not bestSimilarity or similarity > bestSimilarity then
              bestSimilarity, bestIndex, bestDistance = similarity, candidateIndex, distance
            end
          end
        end
      end
    end
    if not bestIndex then return nil end
    used[bestIndex], similarities[queryIndex] = true, bestSimilarity
    totalDistance = totalDistance + bestDistance
    if bestIndex < lastCandidateIndex then ordered = false end
    lastCandidateIndex = bestIndex
  end
  if totalDistance == 0 then return nil end

  local totalSimilarity = 0
  for _, similarity in ipairs(similarities) do totalSimilarity = totalSimilarity + similarity end
  local averageSimilarity = totalSimilarity / #similarities
  return math.min(0.91, 0.62 + averageSimilarity * 0.28 + (ordered and 0.02 or 0))
end

function M.fuzzyScore(queryValue, candidateValue)
  local query = M.normalizeSearchText(queryValue)
  local candidate = M.normalizeSearchText(candidateValue)
  if query == '' then return 1 end
  if candidate == '' then return nil end
  if candidate == query then return 1 end

  local queryLength = utf8.len(query) or #query
  local candidateLength = utf8.len(candidate) or #candidate
  local substringIndex = candidate:find(query, 1, true)
  if substringIndex then
    local boundaryBonus = substringIndex == 1 or candidate:sub(substringIndex - 1, substringIndex - 1) == ' '
    return math.min(0.99, 0.8 + (boundaryBonus and 0.04 or 0)
      + 0.15 * (queryLength / candidateLength))
  end

  local queryTokens, tokenPositions = {}, {}
  for token in query:gmatch('%S+') do queryTokens[#queryTokens + 1] = token end
  local tokensMatch, previousPosition = #queryTokens > 1, 0
  for i, token in ipairs(queryTokens) do
    local position = candidate:find(token, 1, true)
    tokenPositions[i] = position
    if not position then tokensMatch = false end
  end
  if tokensMatch then
    local coverage, ordered = 0, true
    for i, token in ipairs(queryTokens) do
      coverage = coverage + (utf8.len(token) or #token)
      if i > 1 and tokenPositions[i] < previousPosition then ordered = false end
      previousPosition = tokenPositions[i]
    end
    return math.min(0.93, 0.69 + (coverage / candidateLength) * 0.18
      + (ordered and 0.05 or 0))
  end

  local typoScore = M.typoScore(query, candidate)
  local queryChars, candidateChars = chars(query), chars(candidate)
  local queryIndex, firstMatch, lastMatch = 1, nil, nil
  local consecutive, consecutiveBonus, boundaryMatches = 0, 0, 0
  for candidateIndex, candidateChar in ipairs(candidateChars) do
    if queryIndex > #queryChars then break end
    if candidateChar == queryChars[queryIndex] then
      firstMatch = firstMatch or candidateIndex
      consecutive = lastMatch == candidateIndex - 1 and consecutive + 1 or 1
      consecutiveBonus = consecutiveBonus + math.max(0, consecutive - 1)
      if candidateIndex == 1 or candidateChars[candidateIndex - 1] == ' ' then
        boundaryMatches = boundaryMatches + 1
      end
      lastMatch, queryIndex = candidateIndex, queryIndex + 1
    end
  end
  if queryIndex <= #queryChars or not firstMatch then return typoScore end

  local span = lastMatch - firstMatch + 1
  local compactness = #queryChars / span
  local coverage = #queryChars / #candidateChars
  local startBonus = 1 / firstMatch
  local subsequenceScore = math.min(0.84, 0.28 + compactness * 0.28 + coverage * 0.12
    + startBonus * 0.08
    + (math.min(consecutiveBonus, #queryChars) / #queryChars) * 0.05
    + math.min(boundaryMatches, 3) * 0.025)
  return math.max(subsequenceScore, typoScore or 0)
end

-- A small app-name bonus breaks close ties without letting a weak app match
-- beat a clearly stronger title match. Exact score ties preserve recent use.
function M.rank(items, query)
  local q = M.normalizeSearchText(query)
  if q == '' then return items end
  local matches = {}
  for i, item in ipairs(items) do
    local appScore = M.fuzzyScore(q, item.app)
    local titleScore = M.fuzzyScore(q, item.title)
    local combinedScore = M.fuzzyScore(q, item.app .. ' ' .. item.title)
    local score = math.max(
      appScore and math.min(1.03, appScore + 0.03) or 0,
      titleScore or 0,
      combinedScore and combinedScore * 0.94 or 0
    )
    if score > 0 then
      matches[#matches + 1] = { item = item, score = score, order = i }
    end
  end
  table.sort(matches, function(a, b)
    if a.score == b.score then return a.order < b.order end
    return a.score > b.score
  end)
  local result = {}
  for _, match in ipairs(matches) do result[#result + 1] = match.item end
  return result
end

function M.backspace(s)
  local p = utf8.offset(s, -1)
  return p and s:sub(1, p - 1) or ''
end

-- Ghostty exposes every tab as a standard AX window. Tabs in one visual
-- window share a frame, so use a slightly quantized frame as their identity.
function M.frameKey(frame)
  local function quantize(value) return math.floor(value / 8 + 0.5) end
  return table.concat({
    quantize(frame.x), quantize(frame.y), quantize(frame.w), quantize(frame.h),
  }, ':')
end

-- The window filter can retain a closed Ghostty tab after a tab switch, while
-- application:allWindows() exposes the live tab for each visual window.
function M:liveWindowsByFrame(app)
  local windows = {}
  local function add(win)
    if self.isSwitchableWindow(win, app) then
      local frame = self.frameKey(win:frame())
      if windows[frame] == nil then windows[frame] = win end
    end
  end
  -- Prefer the current tab of the main visual window if allWindows() also
  -- happens to contain a stale tab for the same frame.
  add(app:mainWindow())
  for _, win in ipairs(app:allWindows()) do add(win) end
  return windows
end

local function text(value, x, y, w, size, color)
  return { type = 'text', text = value, frame = { x=x, y=y, w=w, h=size+9 },
    textSize = size, textColor = color or {white=0.96}, textFont = '.AppleSystemUIFont',
    textLineBreak = 'truncateTail' }
end

-- Resolve appearance whenever the popup redraws, including each invocation.
local function palette()
  if hs.host.interfaceStyle() == 'Dark' then
    return {
      background={white=0.17,alpha=1}, primary={white=0.84}, secondary={white=0.64},
      divider={white=0.29}, border={white=0.66}, selection={red=0.09,green=0.30,blue=0.23},
      selectedPrimary={white=0.94}, selectedSecondary={red=0.76,green=0.86,blue=0.80},
    }
  end
  return {
    background={white=0.96,alpha=1}, primary={white=0.24}, secondary={white=0.46},
    divider={white=0.84}, border={white=0.25}, selection={red=0.09,green=0.30,blue=0.23},
    selectedPrimary={white=0.94}, selectedSecondary={red=0.76,green=0.86,blue=0.80},
  }
end

function M:render()
  if not self.active then return end
  local colors, screens, live = palette(), hs.screen.allScreens(), {}
  self.canvases = self.canvases or {}
  for _, screen in ipairs(screens) do
    local id, f, rowHeight = screen:id(), screen:frame(), 44
    live[id] = true
    local capacity = math.max(1, math.floor((f.h - 102) / rowHeight))
    local shown = math.max(1, math.min(#self.results, capacity))
    local first = math.max(1, math.min(self.selected - capacity + 1, #self.results - capacity + 1))
    local width, height = math.min(480, f.w - 40), 62 + shown * rowHeight
    local frame = {x=f.x+(f.w-width)/2, y=f.y+(f.h-height)/3, w=width, h=height}
    local canvas = self.canvases[id]
    if not canvas then
      canvas = hs.canvas.new(frame):level('overlay')
        :behavior({'canJoinAllSpaces', 'fullScreenAuxiliary', 'transient', 'ignoresCycle'})
        :clickActivating(false)
      self.canvases[id] = canvas
    else canvas:frame(frame) end
    local elements = {
      { type='rectangle', action='strokeAndFill', roundedRectRadii={xRadius=12,yRadius=12},
        fillColor=colors.background, strokeColor=colors.border, strokeWidth=3,
        frame={x=1.5,y=1.5,w=width-3,h=height-3} },
      text(self.query == '' and 'Search windows…' or self.query,
        18, 13, width-36, 18, self.query == '' and colors.secondary or colors.primary),
      { type='rectangle', action='fill', fillColor=colors.divider,
        frame={x=14,y=43,w=width-28,h=1} },
    }
    for index = first, math.min(#self.results, first + capacity - 1) do
      local item = self.results[index]
      local y = 52 + (index - first) * rowHeight
      local primary = index == self.selected and colors.selectedPrimary or colors.primary
      local secondary = index == self.selected and colors.selectedSecondary or colors.secondary
      if index == self.selected then elements[#elements+1] = {
        type='rectangle', action='fill', roundedRectRadii={xRadius=7,yRadius=7},
        fillColor=colors.selection, frame={x=10,y=y,w=width-20,h=42} } end
      if item.icon then
        elements[#elements+1] = {type='image', image=item.icon, imageScaling='scaleProportionally',
          frame={x=20,y=y+8,w=26,h=26}}
      else
        elements[#elements+1] = text(item.app:sub(1,1), 24, y+10, 24, 17, secondary)
      end
      elements[#elements+1] = text(item.app, 58, y+2, width-78, 15, primary)
      elements[#elements+1] = text(item.title ~= '' and item.title or '(Untitled window)',
        58, y+23, width-78, 11, secondary)
    end
    if #self.results == 0 then
      elements[#elements+1] = text('No matching windows', 20, 65, width-40, 14, colors.secondary)
    end
    canvas:replaceElements(elements):show()
  end
  -- Retire overlays when a monitor is disconnected during a switch.
  for id, canvas in pairs(self.canvases) do
    if not live[id] then canvas:delete(); self.canvases[id] = nil end
  end
end

function M:move(delta)
  if #self.results > 0 then self.selected = ((self.selected - 1 + delta) % #self.results) + 1 end
  self:render()
end

function M:setQuery(query)
  self.query, self.selected = query, 1
  self.results = self.rank(self.items, query)
  self:render()
end

function M:begin(reverse)
  if self.active then self:move(reverse and -1 or 1); return true end
  if hs.eventtap.isSecureInputEnabled() then return false end
  local focused = hs.window.focusedWindow()
  local focusedID = focused and focused:id()
  local items, current, icons, ghosttyFrames, liveGhostty = {}, nil, {}, {}, {}
  for _, win in ipairs(self.filter:getWindows(hs.window.filter.sortByFocusedLast)) do
    local app, id = win:application(), win:id()
    if app and id and self.isSwitchableWindow(win, app) then
      local appName, bundle = app:name() or 'Application', app:bundleID()
      local include, ghostty, pid, frame = true, false, nil, nil
      if appName == 'Ghostty' or bundle == 'com.mitchellh.ghostty' then
        ghostty, pid, frame = true, app:pid(), self.frameKey(win:frame())
        ghosttyFrames[pid] = ghosttyFrames[pid] or {}
        if ghosttyFrames[pid][frame] then include = false
        else
          ghosttyFrames[pid][frame] = true
          if liveGhostty[pid] == nil then
            liveGhostty[pid] = self:liveWindowsByFrame(app)
          end
          local live = liveGhostty[pid][frame]
          if live then win, id = live, live:id() end
        end
      end
      local item = include and {id=id, app=appName, title=win:title() or ''}
      if item and ghostty then
        item.ghostty, item.pid, item.frame = true, pid, frame
      end
      if item and bundle then
        if icons[bundle] == nil then icons[bundle] = hs.image.imageFromAppBundle(bundle) or false end
        item.icon = icons[bundle] or nil
      end
      if item then
        if id == focusedID then current = item else items[#items+1] = item end
      end
    end
  end
  if current then table.insert(items, 1, current) end
  if #items == 0 then return false end
  self.items, self.results, self.query = items, items, ''
  self.selected = reverse and #items or (current and math.min(2, #items) or 1)
  self.active = true
  self:render()
  return true
end

function M:finish(commit)
  if not self.active then return end
  local choice = commit and self.results[self.selected]
  self.active = false
  for _, canvas in pairs(self.canvases or {}) do canvas:delete() end
  self.canvases = nil
  self.items, self.results, self.query = {}, {}, ''
  if choice then
    local win
    if choice.ghostty then
      local app = hs.application.applicationForPID(choice.pid)
      win = app and self:liveWindowsByFrame(app)[choice.frame]
    end
    win = win or hs.window.get(choice.id)
    if self.isSwitchableWindow(win) then
      if win:isMinimized() then win:unminimize() end
      local app = win:application()
      if app and app:isHidden() then app:unhide() end
      win:focus()
    else hs.alert.show('That window has closed') end
  end
end

function M:handle(event)
  local kind, flags = event:getType(), event:getFlags()
  if hs.eventtap.isSecureInputEnabled() then
    self:finish(false)
    self.consumed = {}
    return false
  end
  if kind == types.flagsChanged then
    if self.active and not flags.cmd then self:finish(true) end
    return false
  end
  local key = event:getKeyCode()
  if kind == types.keyUp then
    if self.consumed[key] then self.consumed[key] = nil; return true end
    return false
  end
  if not self.active then
    if key == keys.tab and flags.cmd and not flags.alt and not flags.ctrl then
      if self:begin(flags.shift) then self.consumed[key] = true; return true end
    end
    return false
  end
  if not flags.cmd then self:finish(true); return false end
  self.consumed[key] = true
  if key == keys.escape then self:finish(false)
  elseif key == keys['return'] or key == keys.padenter then self:finish(true)
  elseif key == keys.tab then self:move(flags.shift and -1 or 1)
  elseif key == keys.down then self:move(1)
  elseif key == keys.up then self:move(-1)
  elseif key == keys.delete then self:setQuery(flags.alt and '' or self.backspace(self.query))
  elseif not flags.ctrl and not flags.alt then
    local chars = event:getCharacters(true)
    -- Reject control keys and Apple's private-use function-key characters.
    if chars and chars ~= '' and #self.query < 256 then
      local cp = utf8.codepoint(chars)
      if cp >= 32 and cp ~= 127 and not (cp >= 0xF700 and cp <= 0xF8FF) then
        self:setQuery(self.query .. chars)
      end
    end
  end
  return true
end

function M:setEnabled(enabled)
  self:finish(false)
  self.enabled, self.consumed = enabled, {}
  hs.settings.set('FlickTab.enabled', enabled)
  if enabled and hs.accessibilityState() then self.tap:start() else self.tap:stop() end
  self.menu:setTitle(enabled and (hs.accessibilityState() and '⌘⇥' or '⌘⇥ !') or '⌘⇥ off')
end

function M:start()
  if self.tap then return self end
  self.filter = hs.window.filter.new()
    :setDefaultFilter({allowRoles='AXStandardWindow'})
    :setAppFilter('Firefox', {allowRoles={'AXStandardWindow', 'AXUnknown'}})
  -- Keep the filter observing focus changes, including while the popup is closed.
  self.filter:subscribe(hs.window.filter.windowFocused, function() end)
  self.tap = hs.eventtap.new({types.keyDown, types.keyUp, types.flagsChanged}, function(event)
    local ok, consumed = xpcall(function() return self:handle(event) end, debug.traceback)
    if not ok then
      self:finish(false)
      log.e(consumed)
      hs.alert.show('Window search error; see Hammerspoon Console')
      return false
    end
    return consumed
  end)
  self.menu = hs.menubar.new():setMenu(function() return {
    {title='FlickTab', disabled=true},
    {title=self.enabled and 'Disable (restore macOS Command–Tab)' or 'Enable', fn=function() self:setEnabled(not self.enabled) end},
    {title='Cancel current switch', fn=function() self:finish(false) end},
  } end)
  self:setEnabled(hs.settings.get('FlickTab.enabled') ~= false)
  self.screenWatcher = hs.screen.watcher.new(function()
    if self.active then self:render() end
  end):start()
  self.watchdog = hs.timer.doEvery(0.1, function()
    if self.active then
      if hs.eventtap.isSecureInputEnabled() then self:finish(false)
      elseif not hs.eventtap.checkKeyboardModifiers().cmd then self:finish(true) end
    end
    -- macOS can disable a slow event tap; recover without touching permissions.
    if self.enabled and hs.accessibilityState() and not self.tap:isEnabled()
      and not hs.eventtap.isSecureInputEnabled() then self.tap:start() end
  end)
  return self
end

function M:stop()
  self:finish(false)
  if self.tap then self.tap:stop(); self.tap = nil end
  if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.menu then self.menu:delete(); self.menu = nil end
  if self.filter then self.filter:delete(); self.filter = nil end
  self.enabled, self.consumed = false, {}
  return self
end

return M
