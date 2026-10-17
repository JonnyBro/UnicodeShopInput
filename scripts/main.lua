local TAG = "[UnicodeShopInput]"
local VERSION = "1.5.2"

local COLLAPSED, HIT_TEST_INVISIBLE = 1, 3
local CAPTURE_INCLUDING_INITIAL_MOUSE_DOWN = 2
local SYNC_DELAY = 0.05
local SYNC_MAX_WAIT = 0.15
local QUIET_FRAMES = 2
local LAPTOP_RESCAN_INTERVAL = 0.5

local owner = nil
local session = nil
local frame = 0
local last_pointer_frame = -100
local pointer_notice = false
local start_notice = false
local in_update = false
local failed = false
local construction_started = false

local cached_controller = nil
local library_cache = {}
local laptops = {}
local laptop_scan_time = -math.huge
local LMB_KEY = {KeyName = FName("LeftMouseButton")}
local RMB_KEY = {KeyName = FName("RightMouseButton")}

local function log(message)
	print(TAG .. " " .. message .. "\n")
end

local function valid(object)
	if object == nil then return false end
	local ok, result = pcall(function() return object:IsValid() end)
	return ok and result == true
end

local function same(a, b)
	return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function library(path)
	local value = library_cache[path]
	if valid(value) then return value end
	value = StaticFindObject(path)
	assert(valid(value), "Missing library: " .. path)
	library_cache[path] = value
	return value
end

local function clean(value)
	return value:gsub("%z", ""):gsub("[\r\n]+", " ")
end

local function read_text(box)
	return clean(box:GetText():ToString())
end

local function displayed(widget)
	local child = widget
	for _ = 1, 64 do
		if not valid(child) or not child:IsVisible() then return false end
		local parent = child:GetParent()
		if not valid(parent) then return true end
		if parent:IsA("/Script/UMG.WidgetSwitcher") and not same(parent:GetActiveWidget(), child) then return false end
		child = parent
	end
	return false
end

local function local_controller()
	if valid(cached_controller) then return cached_controller end
	cached_controller = nil
	for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
		if valid(controller) and controller:IsLocalPlayerController() then
			cached_controller = controller
			return controller
		end
	end
end

local function find_host()
	for _, host in ipairs(FindAllOf("ui_UI_C") or {}) do
		if valid(host) and host:IsInViewport() and displayed(host) and valid(host.WidgetTree) and valid(host.borders) then return host, host.WidgetTree, host.borders end
	end
end

local function rescan_laptops()
	local now = os.clock()
	if now - laptop_scan_time < LAPTOP_RESCAN_INTERVAL then return false end
	laptop_scan_time = now
	laptops = {}
	for _, laptop in ipairs(FindAllOf("ui_laptop_C") or {}) do
		if valid(laptop) then laptops[#laptops + 1] = laptop end
	end
	return true
end

local function hovered_search()
	for pass = 1, 2 do
		local any_displayed = false
		for _, laptop in ipairs(laptops) do
			if valid(laptop) and displayed(laptop) then
				any_displayed = true
				local box = laptop.EditableTextBox_search
				if valid(box) and displayed(box) and box:GetIsEnabled() and not box.isReadOnly and box:IsHovered() then return laptop, box end
			end
		end

		if pass == 2 or any_displayed or not rescan_laptops() then return end
	end
end

local function owned()
	return owner ~= nil and valid(owner.host) and valid(owner.tree) and valid(owner.panel) and valid(owner.box) and same(owner.host.WidgetTree, owner.tree) and same(owner.box:GetParent(), owner.panel)
end

local function make_proxy(host, tree, panel)
	for index = 0, panel:GetChildrenCount() - 1 do
		local child = panel:GetChildAt(index)
		if valid(child) and child:IsA("/Script/UMG.EditableTextBox") and child:GetFName():ToString():find("UnicodeShopInput_Proxy", 1, true) == 1 then
			return {
				host = host,
				tree = tree,
				panel = panel,
				box = child
			}
		end
	end

	local class = StaticFindObject("/Script/UMG.EditableTextBox")
	assert(valid(class), "EditableTextBox class unavailable")
	construction_started = true
	local box = StaticConstructObject(class, tree, FName("UnicodeShopInput_Proxy"))
	assert(valid(box), "Proxy construction failed")
	box.ClearKeyboardFocusOnCommit = true
	box.RevertTextOnEscape = false
	box.AllowContextMenu = false
	box.SelectAllTextWhenFocused = false
	box:SetRenderOpacity(0.0)
	box:SetVisibility(COLLAPSED)
	local slot = panel:AddChildToCanvas(box)
	assert(valid(slot), "Proxy attachment failed")
	construction_started = false
	return {
		host = host,
		tree = tree,
		panel = panel,
		box = box
	}
end

local function request_finish(reason, discard)
	if session == nil then return end
	if session.phase ~= "draining" then
		session.phase = "draining"
		session.finish_frame = frame
		log("Input finishing: " .. reason)
	end

	session.discard = session.discard or discard
end

local function begin_input(controller, gameplay)
	local laptop, target = hovered_search()
	if not valid(target) then return end
	local host, tree, panel = find_host()
	if not valid(host) then return end
	if not owned() or not same(owner.host, host) then owner = make_proxy(host, tree, panel) end
	local value = read_text(target)
	session = {
		phase = "active",
		controller = controller,
		target = target,
		laptop = laptop,
		last = value,
		candidate = value,
		changed_at = gameplay:GetRealTimeSeconds(controller),
		start_frame = frame,
		saw_focus = false,
		read_only = target.isReadOnly,
		changed_read_only = false,
		changed_mode = false,
		restored = false,
	}

	local box = owner.box
	box:SetText(FText(value))
	box:SetIsReadOnly(false)
	box:SetVisibility(HIT_TEST_INVISIBLE)
	session.changed_read_only = true
	target:SetIsReadOnly(true)
	session.changed_mode = true
	library("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameAndUI(controller, box, false, false)
	session.saw_focus = box:HasKeyboardFocus()
	log("Input started; keyboard_focus=" .. tostring(session.saw_focus))
end

local function sync_text(s)
	if s.candidate == s.last then return end
	s.last = s.candidate
	s.target:SetText(FText(s.last))
	if not s.logged_sync then
		s.logged_sync = true
		log("First text writeback completed")
	end
end

local function restore_read_only(s)
	if s.changed_read_only and valid(s.target) then
		s.changed_read_only = false
		if s.target.isReadOnly then s.target:SetIsReadOnly(s.read_only) end
	end
end

local function finish_input(s, gameplay)
	if frame - s.finish_frame <= QUIET_FRAMES or frame - last_pointer_frame <= QUIET_FRAMES then return end
	if not s.restored then
		if not s.discard and not s.final_synced then
			s.candidate = read_text(owner.box)
			s.final_synced = true
			local changed = s.candidate ~= s.last
			sync_text(s)
			if changed then return end
		end

		restore_read_only(s)
		if s.changed_mode and owner.host:IsInViewport() and not gameplay:IsGamePaused(s.controller) then
			local proxy_focused = owner.box:HasKeyboardFocus()
			if proxy_focused or not owner.host:HasUserFocusedDescendants(s.controller) then
				local ui = library("/Script/UMG.Default__WidgetBlueprintLibrary")
				ui:SetInputMode_GameOnly(s.controller)
				gameplay:SetViewportMouseCaptureMode(s.controller, CAPTURE_INCLUDING_INITIAL_MOUSE_DOWN)
			end
		end

		if owner.box:HasKeyboardFocus() then return end
		s.restored = true
		s.restored_frame = frame
		return
	end

	if frame > s.restored_frame and not owner.box:HasKeyboardFocus() then
		owner.box:SetVisibility(COLLAPSED)
		session = nil
		log("Input parked (HUD retains proxy)")
	end
end

local function update()
	frame = frame + 1
	local clicked = pointer_notice
	local start = start_notice
	pointer_notice, start_notice = false, false
	if clicked then last_pointer_frame = frame end
	if session == nil and not start and not clicked then return end
	if owner ~= nil and not owned() then owner, session = nil, nil end
	local controller = session and session.controller or local_controller()
	if not valid(controller) then
		owner, session = nil, nil
		return
	end

	local gameplay = library("/Script/Engine.Default__GameplayStatics")
	local mouse_down = controller:IsInputKeyDown(LMB_KEY) or controller:IsInputKeyDown(RMB_KEY)
	if mouse_down then last_pointer_frame = frame end
	if session == nil then
		if start then start_notice = true end
		if start_notice and not mouse_down and not clicked then
			start_notice = false
			if not gameplay:IsGamePaused(controller) then begin_input(controller, gameplay) end
		end
		return
	end

	start_notice = false
	local s = session
	if not valid(s.target) or not valid(s.laptop) then
		request_finish("target expired", true)
	elseif not owner.host:IsInViewport() or not displayed(owner.host) or not displayed(s.laptop) or not displayed(s.target) or gameplay:IsGamePaused(controller) then
		request_finish("shop closed or paused", true)
	elseif read_text(s.target) ~= s.last then
		request_finish("original search changed", true)
	end

	if s.phase == "active" then
		local focus = owner.box:HasKeyboardFocus()
		if focus and not s.saw_focus then log("Keyboard focus acquired") end
		s.saw_focus = s.saw_focus or focus
		if clicked then
			request_finish("pointer interaction", false)
		elseif not focus and (s.saw_focus or frame - s.start_frame > 30) then
			request_finish("focus lost", false)
		end
	end

	if s.phase == "draining" then
		if not mouse_down and not clicked then finish_input(s, gameplay) end
		return
	end

	local now = gameplay:GetRealTimeSeconds(controller)
	local value = read_text(owner.box)
	if value ~= s.candidate then s.candidate, s.changed_at = value, now end
	local quiet = now - s.changed_at >= SYNC_DELAY
	local overdue = now - (s.synced_at or 0) >= SYNC_MAX_WAIT
	if not mouse_down and frame - last_pointer_frame > QUIET_FRAMES and (quiet or overdue) then
		if s.candidate ~= s.last then s.synced_at = now end
		sync_text(s)
	end
end

if type(LoopInGameThreadAfterFrames) ~= "function" then
	log("Disabled: requires UE4SS LoopInGameThreadAfterFrames (EngineTick)")
	return
end

local ok, err = pcall(LoopInGameThreadAfterFrames, 1, function()
	if failed or in_update then return end
	in_update = true
	local success, failure = pcall(update)
	if not success then
		if session ~= nil and not session.error_cleanup then
			session.error_cleanup = true
			request_finish("Lua error", true)
		elseif session == nil and not construction_started then
			pointer_notice, start_notice = false, false
			log("Input attempt cancelled; click the search field to retry")
		else
			failed = true
			log("Input suspended after incomplete construction or cleanup")
		end

		log("Update error: " .. tostring(failure))
	end

	in_update = false
end)

if not ok then
	log("Disabled: EngineTick scheduling unavailable: " .. tostring(err))
	return
end

RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function() pointer_notice, start_notice = true, true end)
RegisterKeyBind(Key.RIGHT_MOUSE_BUTTON, function() pointer_notice = true end)

log("Loaded " .. VERSION .. "; scheduler=EngineTick")
