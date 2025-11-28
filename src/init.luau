
--[=[
	@class UserInputManager

	UserInputManager 는 여러 호스트의 입력 스트림을 하나로 모아 컨텍스트 액션,
	마우스 아이콘 우선순위, 플러그인 입력을 일관되게 제어합니다.

	## 사용 예시
	```lua
	local UserInputManager = require("../roblox_packages/UserInputManager")

	local manager = UserInputManager.new({
		Host = {UserInputService, someViewportGui},
		Name = "Gameplay",
	})

	manager:BindAction("Jump", function(_, state)
		if state == Enum.UserInputState.Begin then
			print("Jump!")
		end
	end, Enum.KeyCode.Space)
	manager:SetPlugin(plugin)
	```
]=]

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Maid = require("../roblox_packages/Maid")
local Signal = require("../roblox_packages/Signal")
local TableUtil = require("../roblox_packages/TableUtil")

local KeyStore = require("../roblox_packages/KeyStore")

local ContextActionConnectedInputKeyType = script.ContextActionConnectedInputKeyType
local Enums = require(script.Enums)
local ContextActionModule = require(script.Interfaces.ContextAction)
local ContextMouseIconModule = require(script.Interfaces.ContextMouseIcon)
local HostMouseModule = require(script.Interfaces.HostMouse)

local ContextAction = ContextActionModule
local ContextMouseIcon = ContextMouseIconModule
local HostMouse = HostMouseModule

local RenderStepped = RunService.RenderStepped

local player = Players.LocalPlayer

local function registerKeyTypes()
	KeyStore.RegisterKeyType(
		"ContextActionConnectedInputKeyType",
		ContextActionConnectedInputKeyType,
		{
			KeyPathToStringFunctionName = "CombinedInputKeyToString",
		}
	)
end

registerKeyTypes()

local UserInputManager = {}
UserInputManager.__index = UserInputManager
UserInputManager.__type = "UserInputManager"

UserInputManager.Enums = Enums

--#region Types


export type Host = UserInputService | GuiObject

export type HostInfo = {
	Host: Host,
	Maid: Maid.Maid,
	IsMainHost: boolean,
	UserInputManager: UserInputManager,
	Mouse: HostMouse?,
	Removed: Signal.Signal,
}

export type ActionFunction = ContextActionModule.ActionFunction
export type ContextAction = ContextActionModule.ContextAction
export type ContextActionResult = ContextActionModule.ContextActionResult
export type InputKey = ContextActionModule.InputKey
export type CombinedInputKey = ContextActionModule.CombinedInputKey
export type InputState = ContextActionModule.InputState
export type BoundFunctionInfo = ContextActionModule.BoundFunctionInfo

type InputSignal = Signal.SignalBase<
	(input: InputObject, gameProcessedEvent: boolean) -> (),
	(InputObject, boolean)
>

export type UserInputManager = setmetatable<{
	IsDestroyed: boolean,
	Destroying: Signal.Signal,

	Plugin: Plugin?,
	Mouse: Mouse?,

	Name: string,

	IsGlobal: boolean,
	GlobalChanged: Signal.ChangedSignal<boolean>,

	IsShared: boolean,
	SharedChanged: Signal.ChangedSignal<boolean>,

	HostInfos: {[Host]: HostInfo},
	HostAdded: Signal.AddedSignal<Host>,
	HostRemoved: Signal.RemovedSignal<Host>,
	MainHostChanged: Signal.ChangedSignal<Host?>,
	MainHost: Host?,
	PressedInputKeySet: {[InputKey]: boolean},

	DefaultPriority: number,
	DefaultPriorityChanged: Signal.ChangedSignal<number>,

	InputBegan: InputSignal,
	InputChanged: InputSignal,
	InputEnded: InputSignal,

	MouseIconSetter: MouseIconSetter?,

	_boundFunctionInfoListsByInputKey: {[InputKey]: {BoundFunctionInfo}},
}, typeof(UserInputManager)>

export type MouseIconSetter = (
	contextMouseIcon: ContextMouseIconModule.ContextMouseIcon?, 
	mouse: Mouse | PluginMouse?,
	isPlugin: boolean
) -> ()

export type HostMouse = HostMouseModule.HostMouse
export type ContextMouseIcon = ContextMouseIconModule.ContextMouseIcon
type ContextMouseIconId = ContextMouseIconModule.ContextMouseIconId

--#endregion Types

local managerSetsByHost = {} :: {[Host]: {[UserInputManager]: true}}
local getActiveUserInputManagerSetFromHost do
	local isDescendantOfViewportGuiCachesByHost = {} :: {[Host]: boolean}
	setmetatable(isDescendantOfViewportGuiCachesByHost, {__mode = "k"})
	
	--[[
		CoreGui 와 PlayerGui 의 자손인지 확인하는 함수
		CoreGui 는 무조건 있지만 PlayerGui 는 경우에 따라 없을 수 있기에
		다른 쓰레드에서 비동기적으로 찾습니다
	]]
	local isDescendantOfPlayerGui
	function isDescendantOfPlayerGui(instance: Instance)
		return instance:IsDescendantOf(CoreGui)
	end

	task.spawn(function()
		local playerGui = player and player:WaitForChild("PlayerGui", 5)
		if not playerGui then
			return
		end
		
		function isDescendantOfPlayerGui(instance: Instance)
			return instance:IsDescendantOf(playerGui)
				or instance:IsDescendantOf(CoreGui)
		end
	end)

	local function isDescendantOfViewportGui(host: Host): boolean
		local isDescendantOfViewportGui = isDescendantOfViewportGuiCachesByHost[host]
		if isDescendantOfViewportGui ~= nil then
			return isDescendantOfViewportGui
		end

		if host == UserInputService then
			isDescendantOfViewportGui = true
		else
			isDescendantOfViewportGui = isDescendantOfPlayerGui(host)
		end
		isDescendantOfViewportGuiCachesByHost[host] = isDescendantOfViewportGui

		return isDescendantOfViewportGui
	end

	function getActiveUserInputManagerSetFromHost(host: Host): {[UserInputManager]: true}
		if not isDescendantOfViewportGui(host) then
			return managerSetsByHost[host]
		end

		local combined = table.clone(managerSetsByHost[UserInputService])

		for manager in managerSetsByHost[host] do
			combined[manager] = true
		end

		return combined
	end
end

local currentActiveHost: Host?

local globalHostInfosByHost = {} :: {[Host]: GlobalHostInfo}

local globalHostInfoAdded = Signal.new() :: Signal.Signal<Host, GlobalHostInfo>
local globalHostInfoRemoved = Signal.new() :: Signal.Signal<Host, GlobalHostInfo>

type GlobalHostInfo = {
	ConsumerCount: number,
	BoundFunctionInfoListsByInputKey: {[InputKey]: {BoundFunctionInfo}},
	Maid: Maid.Maid,
}

local DEFAULT_GLOBAL_MOUSE_ICON_SETTER: MouseIconSetter = function(
	contextMouseIcon: ContextMouseIcon?, 
	mouse: Mouse?,
	isPlugin: boolean
)
	if not contextMouseIcon then
		if mouse then
			mouse.Icon = ""
		end
		UserInputService.MouseIcon = ""
		return
	end

	local icon = contextMouseIcon.Icon
	local iconString = if typeof(icon) == "string"
		then icon
		else if isPlugin then icon.Plugin else icon.Client

	if mouse then
		mouse.Icon = iconString or ""
	end
	UserInputService.MouseIcon = iconString or ""
end

local globalMouseIconSetter: MouseIconSetter = DEFAULT_GLOBAL_MOUSE_ICON_SETTER

local function getMouseIconSetter(userInputManager: UserInputManager): MouseIconSetter
	return userInputManager.MouseIconSetter or globalMouseIconSetter
end

local function createGlobalHostInfo(host: Host): GlobalHostInfo
	local info = {}
	info.ConsumerCount = 0 -- 해당 info 의 소비자(userinputmanager) 수
	info.BoundFunctionInfoListsByInputKey = {}
	info.Maid = Maid.new()

	info.Maid:GiveTask(function()
		globalHostInfosByHost[host] = nil
		globalHostInfoRemoved:Fire(host, info)
		
		if currentActiveHost == host then
			currentActiveHost = nil
		end
		
		local managerSet = managerSetsByHost[host]
		if not managerSet then
			return
		end
		managerSetsByHost[host] = nil
		
		for manager in managerSet do
			manager:RemoveHost(host)
		end
	end)

	globalHostInfosByHost[host] = info
	globalHostInfoAdded:Fire(host, info)
	
	if host ~= UserInputService then
		local ancestryChangedConn = host.AncestryChanged:Connect(function(_, newAncestry)
			if newAncestry == nil then
				info.Maid:Destroy()
			end
		end)
		info.Maid:GiveTask(ancestryChangedConn)
	end
	
	return info
end


local boundFunctionInfoComparator = ContextAction.CompareBoundFunctionInfo


local DEFAULT_USER_INPUT_MANAGER_PARAMS = {
	Host = UserInputService :: {Host} | Host?,
	IsGlobal = true :: boolean?,
	IsShared = true :: boolean?,
	Name = "Unknown" :: string?,
}

export type UserInputManagerParams = typeof(DEFAULT_USER_INPUT_MANAGER_PARAMS)

--#region Constructors
--[=[
	UserInputManager 를 생성합니다.

	@param params UserInputManagerParams? 호스트, 이름, 전역 여부를 설정합니다.
	@return UserInputManager
]=]
function UserInputManager.new(params: UserInputManagerParams?): UserInputManager
	local self = setmetatable({}, UserInputManager)
	self.IsDestroyed = false
	self.Destroying = Signal.new()


	local params: UserInputManagerParams = TableUtil.merge(
		DEFAULT_USER_INPUT_MANAGER_PARAMS, 
		params
	)


	self.Name = params.Name

	self.HostInfos = {}
	self.HostAdded = Signal.new()
	self.HostRemoved = Signal.new()
	self.MainHostChanged = Signal.new()

	self.IsGlobal = params.IsGlobal
	self.GlobalChanged = Signal.new()

	self.IsShared = params.IsShared
	self.SharedChanged = Signal.new()

	self.DefaultPriorityChanged = Signal.new()
	self:SetDefaultPriority(0)

	self._boundFunctionInfoListsByInputKey = {}
	self.PressedInputKeySet = {}

	if params.Host then
		if typeof(params.Host) == "table" then
			for _, host in params.Host do
				self:AddHost(host)
			end
		else
			self:AddHost(params.Host)
		end
	end

	self.InputBegan = Signal.new()
	self.InputChanged = Signal.new()
	self.InputEnded = Signal.new()
	

	return self
end
--#endregion Constructors

--#region Methods
--[=[
	UserInputManager 가 보유한 모든 Signal 과 호스트를 파괴합니다.
]=]
function UserInputManager:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true
	self.Destroying:Fire()

	for i, hostInfo: HostInfo in self.HostInfos do
		self:RemoveHost(hostInfo.Host)
	end

	task.defer(function()
		table.freeze(self)
	end)
end

--[=[
	디버깅 및 로깅을 위한 간단한 이름을 반환합니다.
]=]
function UserInputManager:__tostring()
	return self.Name or "Unknown"
end

--[=[
	현재 활성화된 호스트 중 지정된 입력 키(또는 조합)가 눌렸는지 확인합니다.

	@param ... InputKey | CombinedInputKey 감지할 키 목록입니다.
	@return boolean
]=]
function UserInputManager:IsInputKeyPressed(...: InputKey|CombinedInputKey): boolean
	local inputs = {...}
	assert(#inputs > 0, `There must be at least one input key type specified.`)

	for i, input in {...} do
		if typeof(input) == "table" then
			local tableSuc = true

			-- If the input is a table, must press multiple keys at the same time to begin
			for i, subInput in input do
				if not self.PressedInputKeySet[subInput] then
					tableSuc = false
					break
				end
			end

			if tableSuc then
				return true
			end
		else
			if self.PressedInputKeySet[input] then
				return true
			end
		end
	end
	return false
end

--[=[
	플러그인 컨텍스트에서 동작하도록 Plugin 객체를 연결합니다.

	@param plugin Plugin? UserInputManager 가 참조할 Plugin 인스턴스입니다.
]=]
function UserInputManager:SetPlugin(plugin: Plugin?)
	if self.Plugin == plugin then
		return
	end

	if plugin then
		assert(
			typeof(plugin) == "Instance" and plugin:IsA("Plugin"), 
			`Expected Plugin, got "{typeof(plugin)}".`
		)
		self.Plugin = plugin
		self:_enablePlugin()
	else
		self.Plugin = nil
		self:_disablePlugin()
	end
end

function UserInputManager:_enablePlugin()
	local self = self :: UserInputManager
	local plugin = self.Plugin

	self.Mouse = plugin:GetMouse()
end

function UserInputManager:_disablePlugin()
	local self = self :: UserInputManager

	local player = game:GetService("Players").LocalPlayer
	if player then
		self.Mouse = player:GetMouse()
	end
end

--[=[
	마우스 아이콘 우선순위를 갱신할 콜백을 설정합니다.

	@param setter MouseIconSetter? 컨텍스트 마우스 아이콘을 갱신할 함수입니다.
]=]
function UserInputManager:SetMouseIconSetter(setter: MouseIconSetter?)
	if self.MouseIconSetter == setter then
		return
	end

	self.MouseIconSetter = setter
	self:_updateMouseIcon()
end



do
	local isUpdatingMouse = {
		Plugin = false,
		Client = false,
	}

	local function findContextHighestMouseIconFromHost(host: Host): ContextMouseIcon?
		local highestMouseIcon

		local activeManagerSet = getActiveUserInputManagerSetFromHost(host)
		for userInputManager in activeManagerSet do

			local mouse: HostMouse
			if userInputManager:HasHost(host) then
				mouse = userInputManager:GetMouseOfHost(host)
			else
				mouse = userInputManager:GetMouseOfHost(UserInputService)
			end

			local boundMouseIcons = mouse.BoundMouseIcons
			local highestMouseIconOfCurrentManager = boundMouseIcons[1]

			if highestMouseIconOfCurrentManager then
				local shouldUpdateHighestMouseIcon =
					highestMouseIcon == nil
					or highestMouseIconOfCurrentManager:IsPriorityHigherThan(highestMouseIcon)
				
				if shouldUpdateHighestMouseIcon then
					highestMouseIcon = highestMouseIconOfCurrentManager
				end
			end
		end

		return highestMouseIcon
	end

	local function applyMouseIcon(
		userInputManager: UserInputManager, 
		contextMouseIcon: ContextMouseIcon?, 
		isPlugin: boolean
	)
		local setter = getMouseIconSetter(userInputManager)
		setter(contextMouseIcon, userInputManager.Mouse, isPlugin)
	end

	function UserInputManager:_updateMouseIcon()
		local isPlugin = self.Plugin ~= nil

		local contextSuffix = if isPlugin
			then "Plugin"
			else "Client"

		if isUpdatingMouse[contextSuffix] then
			return
		end

		isUpdatingMouse[contextSuffix] = true
		RenderStepped:Wait()


		if currentActiveHost == nil then
			applyMouseIcon(self, nil, isPlugin)
			isUpdatingMouse[contextSuffix] = false
			return
		end

		local icon = findContextHighestMouseIconFromHost(currentActiveHost)

		applyMouseIcon(self, icon, isPlugin)

		isUpdatingMouse[contextSuffix] = false
	end
end

--[=[
	현재 매니저를 전역/지역 호스트 관리 모드로 전환합니다.

	@param isGlobal boolean true 이면 모든 호스트에서 공유됩니다.
]=]
function UserInputManager:SetGlobal(isGlobal: boolean)
	if self.IsGlobal == isGlobal then
		return
	end

	self.IsGlobal = isGlobal
	self.GlobalChanged:Fire(isGlobal)
end

--[=[
	컨텍스트 액션 우선순위의 기본값을 설정합니다.

	@param priority number 높은 값일수록 나중에 추가된 액션보다 우선입니다.
]=]
function UserInputManager:SetDefaultPriority(priority: number)
	if self.DefaultPriority == priority then
		return
	end

	self.DefaultPriority = priority
	self.DefaultPriorityChanged:Fire(priority)
end

--[=[
	현재 기본 액션 우선순위를 반환합니다.

	@return number
]=]
function UserInputManager:GetDefaultPriority(): number
	return self.DefaultPriority
end

--[=[
	지정된 입력 키 집합과 콜백을 바인딩합니다.

	@param actionFunction ActionFunction 입력 상태를 처리할 함수입니다.
	@param priority number | "Inherit" 우선순위를 지정하거나 기본값을 상속합니다.
	@param ... InputKey | CombinedInputKey 트리거로 사용할 입력입니다.
	@return ContextAction
]=]
function UserInputManager:BindAction(
	actionFunction: ActionFunction,
	priority: number | "Inherit",
	...: InputKey | CombinedInputKey
): ContextAction
	return ContextAction.new(self, actionFunction, priority, ...)
end

--[=[
	입력 시작 시에만 콜백을 호출하는 바인딩을 생성합니다.

	@param actionFunction (inputObject: InputObject) -> ContextActionResult? 입력 시작을 처리할 함수입니다.
	@param priority number | "Inherit" 우선순위를 지정하거나 기본값을 상속합니다.
	@param ... InputKey | CombinedInputKey 트리거로 사용할 입력입니다.
	@return ContextAction
]=]
function UserInputManager:BindActionOnInputBegan(
	actionFunction: (inputObject: InputObject) -> (ContextActionResult?),
	priority: number | "Inherit",
	...: InputKey | CombinedInputKey
): ContextAction
	return ContextAction.new(
		self,
		function(state, inputObject)
			if state == "Begin" then
				return actionFunction(inputObject)
			end

			return "Pass"
		end,
		priority,
		...
	)
end

--[=[
	입력 종료 시에만 콜백을 호출하는 바인딩을 생성합니다.

	@param actionFunction (inputObject: InputObject) -> ContextActionResult? 입력 종료를 처리할 함수입니다.
	@param priority number | "Inherit" 우선순위를 지정하거나 기본값을 상속합니다.
	@param ... InputKey | CombinedInputKey 트리거로 사용할 입력입니다.
	@return ContextAction
]=]
function UserInputManager:BindActionOnInputEnded(
	actionFunction: (inputObject: InputObject) -> (ContextActionResult?),
	priority: number | "Inherit",
	...: InputKey | CombinedInputKey
): ContextAction
	return ContextAction.new(
		self,
		function(state, inputObject)
			if state == "End" then
				return actionFunction(inputObject)
			end

			return "Pass"
		end,
		priority,
		...
	)
end

--[=[
	전역 UserInputManager 가 공유하는 마우스 아이콘 Setter 를 지정합니다.

	@param setter MouseIconSetter? 설정하지 않으면 기본 Setter 를 사용합니다.
]=]
function UserInputManager.SetGlobalMouseIconSetter(setter: MouseIconSetter?)
	globalMouseIconSetter = setter or DEFAULT_GLOBAL_MOUSE_ICON_SETTER

	local processedManagers = {} :: {[UserInputManager]: true}
	for _, managerSet in managerSetsByHost do
		for manager in managerSet do
			if processedManagers[manager] then
				continue
			end

			processedManagers[manager] = true
			manager:_updateMouseIcon()
		end
	end
end


-- Host helper functions
do
	local INPUT_STATES_BY_BOOLEAN = {
		[true] = "Begin",
		[false] = "End",
	}

	local function updateActiveHost(host: Host)
		if currentActiveHost == host then
			return
		end

		currentActiveHost = host

		local managerSet = managerSetsByHost[host]
		local manager = next(managerSet)

		if manager then
			manager:_updateMouseIcon()
		end
	end

	local function getCombinedBoundFunctionInfoListByInputKeyFromManagerSet(
		managerSet: {[UserInputManager]: true},
		inputKey: InputKey
	): {BoundFunctionInfo}

		local combinedBoundFunctionInfoList = {}
		local combinedBoundFunctionCount = 0

		for manager in managerSet do
			local boundFunctionInfoList = manager._boundFunctionInfoListsByInputKey[inputKey]

			if boundFunctionInfoList == nil then
				continue
			end

			local size = #boundFunctionInfoList

			table.move(
				boundFunctionInfoList, 
				1, 
				size, 
				combinedBoundFunctionCount + 1, 
				combinedBoundFunctionInfoList
			)

			combinedBoundFunctionCount += size
		end

		table.sort(combinedBoundFunctionInfoList, boundFunctionInfoComparator)

		return combinedBoundFunctionInfoList
	end

	local function warnOnYieldingPass(contextAction)
	local warnMessage = 
		`After yielding, returning "Pass" will not allow the next action ` ..
		`to continue.\n` ..
		`From UserInputManager "{contextAction.UserInputManager}", ` ..
		`ContextAction {contextAction}.\n` ..
		`{contextAction._createdDebugTraceback}`

		warn(warnMessage)
	end

	local function runBoundFunctionInfo(
		boundFunctionInfo: BoundFunctionInfo,
		inputState: InputState,
		inputObject: InputObject
	)
		local didYield
		local actionResult

		local actionFunctionThread = task.spawn(function()
			actionResult = boundFunctionInfo.ActionFunction(inputState, inputObject)

			local didYieldWithPass = 
				didYield 
				and (actionResult == "Pass" or actionResult == Enum.ContextActionResult.Pass)

			if didYieldWithPass then
				warnOnYieldingPass(boundFunctionInfo.ContextAction)
			end
		end)
		didYield = coroutine.status(actionFunctionThread) == "suspended"

		return didYield, actionResult
	end

	local function runBoundFunctionInfosInOrder(
		boundFunctionInfoList: {BoundFunctionInfo},
		inputState: InputState,
		inputObject: InputObject
	)

		for i, boundFunctionInfo in ipairs(boundFunctionInfoList) do

			local didYield, actionResult = runBoundFunctionInfo(
				boundFunctionInfo, 
				inputState, 
				inputObject
			)

			local shouldStop = 
				didYield
				or (actionResult ~= "Pass" and actionResult ~= Enum.ContextActionResult.Pass) 

			if shouldStop then
				break
			end
		end
	end

	function UserInputManager:_executeBoundActionsByInputKey(
		inputKey: InputKey, 
		inputState: InputState, 
		inputObject: InputObject
	)
		local boundFunctionInfoList = self._boundFunctionInfoListsByInputKey[inputKey]
		if boundFunctionInfoList == nil then
			return
		end

		runBoundFunctionInfosInOrder(boundFunctionInfoList, inputState, inputObject)
	end
	
	-- 반환값은 바뀌었는지 여부
	function UserInputManager:_setInputKeyPressed(
		inputKey: InputKey, 
		isPressed: boolean
	): (boolean)
		local pressedInputKeySet = self.PressedInputKeySet

		if pressedInputKeySet[inputKey] == isPressed then
			return false
		end

		pressedInputKeySet[inputKey] = isPressed

		return true
	end


	local function setInputKeyOfManagersOfHost(
		inputKey: InputKey, 
		isPressed: boolean,
		inputObject: InputObject,
		host: Host,
		gameProcessedEvent: boolean?
	)
		local changedGlobalManagerSet = {} :: {[UserInputManager]: true}
		local inputState = INPUT_STATES_BY_BOOLEAN[isPressed]

		local activeManagerSet = getActiveUserInputManagerSetFromHost(host)
		for manager in activeManagerSet do
			local isPressedChanged = manager:_setInputKeyPressed(inputKey, isPressed)

			if not isPressedChanged then
				continue
			end

			if gameProcessedEvent then
				continue
			end

			if manager.IsGlobal then
				changedGlobalManagerSet[manager] = true
			else
				manager:_executeBoundActionsByInputKey(inputKey, inputState, inputObject, host)
			end
		end

		local changedGlobalBoundFunctionInfo = 
			getCombinedBoundFunctionInfoListByInputKeyFromManagerSet(
				changedGlobalManagerSet, 
				inputKey
			)

		runBoundFunctionInfosInOrder(changedGlobalBoundFunctionInfo, inputState, inputObject)
	end

	local function runBoundFunctionsInfosInOrderOnChanged(
		inputKey: InputKey, 
		inputObject: InputObject,
		host: Host,
		gameProcessedEvent: boolean
	)
		if gameProcessedEvent then
			return
		end

		local pressedGlobalManagerSet = {} :: {[UserInputManager]: true}

		local activeManagerSet = getActiveUserInputManagerSetFromHost(host)

		for manager in managerSetsByHost[host] do
			if manager.Global then
				pressedGlobalManagerSet[manager] = true
			else
				manager:_executeBoundActionsByInputKey(inputKey, "Change", inputObject, host)
			end
		end


		local pressedGlobalBoundFunctionInfo = 
			getCombinedBoundFunctionInfoListByInputKeyFromManagerSet(
				pressedGlobalManagerSet, 
				inputKey
			)

		runBoundFunctionInfosInOrder(pressedGlobalBoundFunctionInfo, "Change", inputObject)
	end

	local function fireUserInputManagersInputSignal(
		signalName: string, 
		host, 
		inputObject, 
		gameProcessedEvent
	)
		for manager in managerSetsByHost[host] do
			manager[signalName]:Fire(inputObject, gameProcessedEvent)
		end
	end

	local function detectInputsOnGlobalHostAdded(host, globalHostInfo: GlobalHostInfo)

		local inputBeganConn = host.InputBegan:Connect(function(
			inputObject, 
			gameProcessedEvent
		)
			updateActiveHost(host)

			local inputKeyFromKeyCode, inputKeyFromInputType = 
				inputObject.KeyCode, inputObject.UserInputType

			fireUserInputManagersInputSignal("InputBegan", host, inputObject, gameProcessedEvent)

			setInputKeyOfManagersOfHost(inputKeyFromKeyCode, true, inputObject, host, gameProcessedEvent)
			setInputKeyOfManagersOfHost(inputKeyFromInputType, true, inputObject, host, gameProcessedEvent)
		end)

		local inputChangedConn = host.InputChanged:Connect(function(
			inputObject,
			gameProcessedEvent
		)
			updateActiveHost(host)

			local inputKeyFromKeyCode, inputKeyFromInputType = 
				inputObject.KeyCode, inputObject.UserInputType

			fireUserInputManagersInputSignal("InputChanged", host, inputObject, gameProcessedEvent)

			runBoundFunctionsInfosInOrderOnChanged(inputKeyFromKeyCode, inputObject, host, gameProcessedEvent)
			runBoundFunctionsInfosInOrderOnChanged(inputKeyFromInputType, inputObject, host, gameProcessedEvent)
		end)

		local inputEndedConn = host.InputEnded:Connect(function(
			inputObject: InputObject, 
			gameProcessedEvent
		)
			updateActiveHost(host)

			local inputKeyFromKeyCode, inputKeyFromInputType = 
				inputObject.KeyCode, inputObject.UserInputType

			fireUserInputManagersInputSignal("InputEnded", host, inputObject, gameProcessedEvent)

			setInputKeyOfManagersOfHost(inputKeyFromKeyCode, false, inputObject, host, gameProcessedEvent)
			setInputKeyOfManagersOfHost(inputKeyFromInputType, false, inputObject, host, gameProcessedEvent)
		end)

		globalHostInfo.Maid:GiveTask(function()
			inputBeganConn:Disconnect()
			inputChangedConn:Disconnect()
			inputEndedConn:Disconnect()
		end)
	end

	globalHostInfoAdded:Connect(detectInputsOnGlobalHostAdded)

	--[=[
		UserInputService 또는 GuiObject 호스트를 등록합니다.

		@param host Host 연결할 호스트입니다.
	]=]
	function UserInputManager:AddHost(host: Host)
		assert(typeof(host) == "Instance", `Instance Expected, got {typeof(host)}.`)
		assert(
			host:IsA("GuiObject") or host == UserInputService,
			`Host must be UserInputService or GuiObject. Host "{host}"'s class is "{host.ClassName}".`
		)

		local hostInfos = self.HostInfos
		if hostInfos[host] then
			warn(`UserInputManager already has a Host "{host}".`)
			return
		end

		local globalHostInfo = globalHostInfosByHost[host] or createGlobalHostInfo(host)
		globalHostInfo.ConsumerCount += 1

		local hostInfo = self:_createHostInfo()
		hostInfos[host] = hostInfo

		-- inserts new UserInputManager into the Host Dictionary for tracking
		if managerSetsByHost[host] == nil then
			managerSetsByHost[host] = {}
		end
		managerSetsByHost[host][self] = true

		--if MainHost is nil, set MainHost
		if self.MainHost == nil then
			self:SetMainHost(host)
		end

		self.HostAdded:Fire(host)
	end

	function UserInputManager:_createHostInfo(host: Host)
		local hostInfo = {} :: HostInfo

		local maid = Maid.new()
		hostInfo.Host = host
		hostInfo.UserInputManager = self
		hostInfo.Maid = maid
		hostInfo.IsMainHost = false
		hostInfo.Removed = Signal.new()

		return hostInfo
	end

		local function decreaseConsumerCountOfGlobalHostFromHost(host: Host)
		local globalHostInfo = globalHostInfosByHost[host]
		if not globalHostInfo then
			return
		end
		
		globalHostInfo.ConsumerCount -= 1

		if globalHostInfo.ConsumerCount == 0 then
			globalHostInfo.Maid:Destroy()
		end
	end

	--[=[
		등록된 호스트를 제거하고 연결된 신호를 해제합니다.

		@param removingHost Host 제거할 호스트입니다.
	]=]
	function UserInputManager:RemoveHost(removingHost: Host)
		local hostInfos = self.HostInfos
		local hostInfo: HostInfo = hostInfos[removingHost]
		if hostInfo == nil then
			return
		end

		hostInfo.Maid:Destroy()
		hostInfo.Removed:Fire()

		hostInfos[removingHost] = nil

		--remove UserInutManager from Host Dictionary
		local managerSet = managerSetsByHost[removingHost]
		if managerSet and managerSet[self] then
			managerSet[self] = nil
		end

		decreaseConsumerCountOfGlobalHostFromHost(removingHost)

		if self.MainHost == removingHost then
			self.MainHost = nil
			
			local isMainHostChanged
			for otherHost in hostInfos do
				isMainHostChanged = true
				self:SetMainHost(otherHost)
				break
			end

			if not isMainHostChanged then
				self.MainHostChanged:Fire(nil)
			end
		end

		self.HostRemoved:Fire(removingHost)
	end
end



--[=[
	등록된 모든 호스트 목록을 반환합니다.

	@return {Host}
]=]
function UserInputManager:GetHosts(): {Host}
	local hosts = {}
	for host in self.HostInfos do
		table.insert(hosts, host)
	end
	return hosts
end

--[=[
	지정한 호스트가 이미 등록되어 있는지 확인합니다.

	@param host Host 확인할 호스트입니다.
	@return boolean
]=]
function UserInputManager:HasHost(host): boolean
	return self.HostInfos[host] ~= nil
end

--[=[
	특정 호스트가 제거될 때 호출되는 시그널을 반환합니다.

	@param host Host 대상 호스트입니다.
	@return Signal.Signal<>
]=]
function UserInputManager:GetHostRemovedSignal(host: Host): Signal.Signal<>
	local hostInfo = self.HostInfos[host]
	if not hostInfo then
		error(`Host "{host}" isn't a valid host of UserInputManager.`)
	end
	return hostInfo.Removed
end

--[=[
	UserInputManager 가 기준으로 삼을 메인 호스트를 설정합니다.

	@param host Host 등록된 호스트여야 합니다.
]=]
function UserInputManager:SetMainHost(host: Host)
	local hostInfos = self.HostInfos
	local hostInfo = hostInfos[host]
	assert(hostInfo ~= nil, `Host "{host}" isn't a valid host of UserInputManager.`)

	local existingMainHost = self.MainHost
	if existingMainHost ~= nil then
		if existingMainHost == host then
			return
		end
		hostInfos[existingMainHost].IsMainHost = false
	end

	self.MainHost = host
	hostInfo.IsMainHost = true
	self.MainHostChanged:Fire(host)
end

--[=[
	현재 메인 호스트를 반환합니다.

	@return Host?
]=]
function UserInputManager:GetMainHost(): Host?
	return self.MainHost
end

--[=[
	특정 호스트에 대응하는 HostMouse 객체를 반환합니다.

	@param host Host 대상 호스트입니다.
	@return HostMouse
]=]
function UserInputManager:GetMouseOfHost(host: Host): HostMouse
	local hostInfo = self.HostInfos[host]
	if hostInfo == nil then
		error(`Host "{host}" isn't valid member of UserInputManager "{self}"`)
	end

	local mouse = hostInfo.Mouse
	if mouse == nil then
		mouse = HostMouse.new(self, host)
		hostInfo.Mouse = mouse
		hostInfo.Maid:GiveTask(mouse)
	end

	return mouse
end

--[=[
	메인 호스트의 HostMouse 를 반환합니다.

	@return HostMouse
]=]
function UserInputManager:GetMouse(): HostMouse
	local mainHost = self:GetMainHost()
	assert(mainHost ~= nil, `UserInputManager doesn't have a valid Host. Couldn't get a Mouse.`)
	return self:GetMouseOfHost(mainHost)
end

--[=[
	현재 활성 호스트(또는 메인 호스트)의 마우스 좌표를 반환합니다.

	@return Vector2
]=]
function UserInputManager:GetMousePosition(): Vector2
	if self.HostInfos[currentActiveHost] then
		return self:GetMouseOfHost(currentActiveHost):GetPosition()
	end

	return self:GetMouse():GetPosition()
end

--[=[
	마우스가 특정 사각형 내부에 있는지 확인합니다.

	@param x number 사각형의 X 위치입니다.
	@param y number 사각형의 Y 위치입니다.
	@param width number 너비입니다.
	@param height number 높이입니다.
	@return boolean
]=]
function UserInputManager:IsMouseInRect(
	x: number,
	y: number,
	width: number,
	height: number
): boolean
	if self.HostInfos[currentActiveHost] then
		return self:GetMouseOfHost(currentActiveHost):IsInRect(x, y, width, height)
	end

	return self:GetMouse():IsInRect(x, y, width, height)
end

--[=[
	마우스가 GuiObject 내부에 있는지 확인합니다.

	@param frame GuiObject 검사할 프레임입니다.
	@param epsilon number? 경계 여유값입니다.
	@return boolean
]=]
function UserInputManager:IsMouseInFrame(frame: GuiObject, epsilon: number?): boolean
	local absPos, absSize = frame.AbsolutePosition, frame.AbsoluteSize
	local resolvedEpsilon = epsilon or 0

	return self:IsMouseInRect(
		absPos.X - resolvedEpsilon,
		absPos.Y - resolvedEpsilon,
		absSize.X + resolvedEpsilon,
		absSize.Y + resolvedEpsilon
	)
end

--#endregion Methods


--#1 Functions

--[=[
	모든 전역 호스트를 정리하고 내부 연결을 초기화합니다.
]=]
function UserInputManager.ClearEveryGlobalHosts()
	for host, hostInfo in globalHostInfosByHost do
		hostInfo.Maid:Destroy()
	end
	
	table.clear(globalHostInfosByHost)
end

UserInputManager.GlobalUserInputManager = UserInputManager.new()

return UserInputManager
