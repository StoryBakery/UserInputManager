
--[=[
	@class ContextAction

	입력 콜백을 표현하는 객체로, 우선순위 및 입력 키 조합을 동적으로 관리합니다.
]=]

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")

local KeyStore = require("../../roblox_packages/KeyStore")
local Maid = require("../../roblox_packages/Maid")
local Signal = require("../../roblox_packages/Signal")
local TableUtil = require("../../roblox_packages/TableUtil")

local ContextAction = {}
ContextAction.__index = ContextAction
ContextAction.__type = "ContextAction"



export type ActionFunction = (
	inputState: InputState,
	inputObject: InputObject
) -> (ContextActionResult?)
export type ContextActionResult = "Sink" | "Pass"
export type InputKey = Enum.KeyCode | Enum.UserInputType
export type CombinedInputKey = {InputKey}
export type InputState = "Begin" | "Change" | "End" | "Cancel"

export type BoundFunctionInfo<UserInputManager = any> = {
	Priority: number,
	CreatedTime: number,
	ActionFunction: ActionFunction,

	InputKey: InputKey,
	CombinedInputKey: CombinedInputKey?,
	CombinedInputKeyLength: number,

	ContextAction: ContextAction<UserInputManager>,
}

export type ContextAction<UserInputManager = any> = setmetatable<{
	UserInputManager: UserInputManager,

	IsDestroyed: boolean,
	Destroying: Signal.Signal,
	Maid: Maid.Maid,

	_id: string,
	CreatedTime: number,

	IsPriorityInherited: boolean,
	Priority: number,
	PriorityChanged: Signal.ChangedSignal<number>,
	PriorityInheritanceChanged: Signal.Signal<boolean>,

	ActionFunction: ActionFunction,
	BoundFunctionInfoListsByCombinedInputKeyStore: KeyStore.KeyStore<BoundFunctionInfo, InputKey>,
}, typeof(ContextAction)>

local function compareBoundFunctionInfo(a: BoundFunctionInfo, b: BoundFunctionInfo): boolean
	local aPriority, bPriority = a.Priority, b.Priority
	if aPriority == bPriority then
		local aLen, bLen = a.CombinedInputKeyLength, b.CombinedInputKeyLength

		if aLen == bLen then
			local aCombinedInputKey = a.CombinedInputKey or {a.InputKey}
			local bCombinedInputKey = b.CombinedInputKey or {b.InputKey}

			for i = 1, aLen do
				local aInputKeyValue = aCombinedInputKey[i].Value
				local bInputKeyValue = bCombinedInputKey[i].Value
				if aInputKeyValue == bInputKeyValue then
					continue
				end

				return aInputKeyValue < bInputKeyValue
			end

			local aCreatedTime, bCreatedTime = a.CreatedTime, b.CreatedTime
			if aCreatedTime == bCreatedTime then
				return a.ContextAction._id > b.ContextAction._id
			end
			return aCreatedTime < bCreatedTime
		end
		return aLen > bLen
	end
	return aPriority > bPriority
end

ContextAction.CompareBoundFunctionInfo = compareBoundFunctionInfo

--#region Constructors
--[=[
	ContextAction 객체를 생성합니다. 일반적으로 `UserInputManager:BindAction*`
	메서드를 통해서만 호출됩니다.

	@param userInputManager UserInputManager 액션이 속한 매니저입니다.
	@param actionFunction ActionFunction 실행할 콜백입니다.
	@param priority number | "Inherit" 우선순위 혹은 기본값 상속 여부입니다.
	@param ... InputKey | CombinedInputKey 입력 키 목록입니다.
	@return ContextAction
]=]
function ContextAction.new(
	userInputManager: any,
	actionFunction: ActionFunction,
	priority: number | "Inherit",
	...: InputKey | CombinedInputKey
): ContextAction

	local self = setmetatable({}, ContextAction)
	self.UserInputManager = userInputManager

	self.IsDestroyed = false
	self.Destroying = Signal.new()
	local maid = Maid.new()
	self.Maid = maid

	maid:GiveTask(userInputManager.Destroying:Once(function()
		self:Destroy()
	end))

	self._id = HttpService:GenerateGUID(false)
	self.CreatedTime = os.clock()

	local boundFunctionInfoListsByCombinedInputKeyStore = KeyStore.new({
		Name = "BoundFunctionInfoListsByCombinedInputKeyStore",

		DefaultKeyType = "ContextActionConnectedInputKeyType",
	})
	self.BoundFunctionInfoListsByCombinedInputKeyStore = boundFunctionInfoListsByCombinedInputKeyStore

	self.PriorityChanged = Signal.new()
	self.PriorityInheritanceChanged = Signal.new()

	self:SetPriorityInheritance(priority == "Inherit")

	if not self.IsPriorityInherited then
		self:SetPriority(priority)
	end

	self.ActionFunction = actionFunction
	self._createdDebugTraceback = debug.traceback(nil, 3)

	for i, inputKey in {...} do
		self:AddInputKey(inputKey)
	end

	return self :: any
end
--#endregion Constructors

--#region Methods

do
	local CANCEL_INPUT_OBJECT = {
		Delta = Vector3.zero,
		KeyCode = Enum.KeyCode.Unknown,
		Position = Vector3.zero,
		UserInputState = Enum.UserInputState.Cancel,
		UserInputType = Enum.UserInputType.None,
	}

	local ACTION_NAME_TO_GET_CANCEL_INPUT_OBJECT = "UserInputManager/Internal/ToGetCancelInputObject"
	pcall(function()
		ContextActionService:BindAction(ACTION_NAME_TO_GET_CANCEL_INPUT_OBJECT, function(_, _, inputObject)
			CANCEL_INPUT_OBJECT = inputObject
		end, false)
		ContextActionService:UnbindAction(ACTION_NAME_TO_GET_CANCEL_INPUT_OBJECT)
	end)

	--[=[
		ContextAction 을 파괴하고 연결된 모든 입력을 해제합니다.
	]=]
	function ContextAction:Destroy()
		if self.IsDestroyed then
			return
		end
		self.IsDestroyed = true
		self.Destroying:Fire()
		self.Maid:Destroy()

		self:ResetInputKeys()

		self.ActionFunction("Cancel", CANCEL_INPUT_OBJECT)

		task.defer(function()
			table.freeze(self :: any)
		end)
	end
end

do
	local function findBoundFunctionInfoIndexFromList(
		boundFunctionInfo: BoundFunctionInfo,
		boundFunctionInfoList: {BoundFunctionInfo}
	): number
		local index = TableUtil.bisectLeft(
			boundFunctionInfoList,
			boundFunctionInfo,
			compareBoundFunctionInfo
		)

		return index
	end


	function ContextAction:_createBoundFunctionInfo(
		realActionFunction: ActionFunction,
		inputKey: InputKey,
		combinedInputKey: CombinedInputKey?
	): BoundFunctionInfo

		local combinedInputKey = combinedInputKey or {inputKey}

		local boundFunctionInfo = {
			ActionFunction = realActionFunction,
			CreatedTime = self.CreatedTime,
			Priority = self.Priority,

			InputKey = inputKey,
			CombinedInputKey = combinedInputKey,
			CombinedInputKeyLength = #combinedInputKey,

			ContextAction = self,
		}

		return boundFunctionInfo
	end

	function ContextAction:_bindActionFunctionToUserInputManagerByInputKey(
		inputKey: InputKey,
		realActionFunction: ActionFunction?,
		combinedInputKey: CombinedInputKey?
	): BoundFunctionInfo
		local userInputManager = self.UserInputManager
		local boundFunctionInfoListByInputKey = userInputManager._boundFunctionInfoListsByInputKey

		local boundFunctionInfoList = boundFunctionInfoListByInputKey[inputKey]
		local index

		local boundFunctionInfo = self:_createBoundFunctionInfo(
			realActionFunction or self.ActionFunction,
			inputKey,
			combinedInputKey
		)

		if boundFunctionInfoList == nil then
			boundFunctionInfoList = {}
			boundFunctionInfoListByInputKey[inputKey] = boundFunctionInfoList

			index = 1
		else
			index = findBoundFunctionInfoIndexFromList(boundFunctionInfo, boundFunctionInfoList)
		end

		table.insert(boundFunctionInfoList, index, boundFunctionInfo)

		return boundFunctionInfo
	end


	function ContextAction:_removeBoundFunctionInfoFromList(
		boundFunctionInfo: BoundFunctionInfo
	)
		local userInputManager = self.UserInputManager

		local inputKey = boundFunctionInfo.InputKey

		local boundFunctionInfoList = userInputManager._boundFunctionInfoListsByInputKey[inputKey]

		local index = findBoundFunctionInfoIndexFromList(boundFunctionInfo, boundFunctionInfoList)

		if boundFunctionInfoList[index] ~= boundFunctionInfo then
			error("INCORRECT FOUND")
		end

		table.remove(boundFunctionInfoList, index)
	end

	function ContextAction:_connectActionFunctionToUserInputManagerByCombinedInputKey(
		combinedInputKey: CombinedInputKey
	): {BoundFunctionInfo}
		-- input key is a table, should press multiple keys at the same time to begin
		local isBegan = false
		local keyCount = #combinedInputKey
		local userInputManager = self.UserInputManager

		local boundFunctionInfos = {}

		local lastInputKey = combinedInputKey[keyCount]

		local function onLastInputKey(inputState: InputState, inputObject: InputObject)
			if inputState == "Begin" then
				for i, subInput in combinedInputKey do
					if not userInputManager:IsInputKeyPressed(subInput) then
						return "Pass"
					end
				end
				isBegan = true

			elseif inputState == "End" then
				if not isBegan then
					return "Pass"
				end

				isBegan = false

			elseif inputState == "Change" then
				for i = 1, keyCount - 1 do
					local subInput = combinedInputKey[i]
					if not userInputManager:IsInputKeyPressed(subInput) then
						return "Pass"
					end
				end
			end

			return self.ActionFunction(inputState, inputObject)
		end

		table.insert(
			boundFunctionInfos,
			self:_bindActionFunctionToUserInputManagerByInputKey(
				lastInputKey,
				onLastInputKey,
				combinedInputKey
			)
		)

		for i = 1, (keyCount - 1) do
			local subInputKey = combinedInputKey[i]
			local function onSubInputKey(inputState, inputObject)
				if inputState ~= "End" then
					return "Pass"
				end

				if not isBegan then
					return "Pass"
				end

				isBegan = false
				return self.ActionFunction("End", inputObject)
			end

			table.insert(
				boundFunctionInfos,
				self:_bindActionFunctionToUserInputManagerByInputKey(
					subInputKey,
					onSubInputKey,
					combinedInputKey
				)
			)
		end

		return boundFunctionInfos
	end
end


--[=[
	입력 키 또는 조합을 새로운 트리거로 추가합니다.

	@param inputKey InputKey | CombinedInputKey
]=]
function ContextAction:AddInputKey(inputKey: InputKey | CombinedInputKey)
	local boundFunctionInfoListsByCombinedInputKeyStore = self.BoundFunctionInfoListsByCombinedInputKeyStore

	local combinedInputKey = if typeof(inputKey) == "table"
		then inputKey
		else {inputKey}

	local isArleadyAdded = boundFunctionInfoListsByCombinedInputKeyStore:FindByKeyPath(combinedInputKey) ~= nil
	if isArleadyAdded then
		error(`{combinedInputKey} already added.`)
	end


	if #combinedInputKey == 1 then
		local boundFunctionInfo =
			self:_bindActionFunctionToUserInputManagerByInputKey(combinedInputKey[1])

		boundFunctionInfoListsByCombinedInputKeyStore:SetByKeyPath(combinedInputKey, {boundFunctionInfo})
	else
		local boundFunctionInfos =
			self:_connectActionFunctionToUserInputManagerByCombinedInputKey(combinedInputKey)

		boundFunctionInfoListsByCombinedInputKeyStore:SetByKeyPath(combinedInputKey, boundFunctionInfos)
	end
end


--[=[
	특정 입력 키(또는 조합)를 제거합니다.

	@param inputKey InputKey | CombinedInputKey
]=]
function ContextAction:RemoveInputKey(inputKey: InputKey | CombinedInputKey)
	local boundFunctionInfoListsByCombinedInputKeyStore = self.BoundFunctionInfoListsByCombinedInputKeyStore

	local combinedInputKey = if typeof(inputKey) == "table"
		then inputKey
		else {inputKey}

	local boundFunctionInfos = boundFunctionInfoListsByCombinedInputKeyStore:GetByKeyPath(combinedInputKey)

	boundFunctionInfoListsByCombinedInputKeyStore:RemoveByKeyPath(combinedInputKey)
	for i, boundFunctionInfo in boundFunctionInfos do
		self:_removeBoundFunctionInfoFromList(boundFunctionInfo)
	end
end


--[=[
	모든 입력 키 바인딩을 제거합니다.
]=]
function ContextAction:ResetInputKeys()
	local boundFunctionInfoListsByCombinedInputKeyStore =
		self.BoundFunctionInfoListsByCombinedInputKeyStore

	for
		i,
		combinedInputKey
		in boundFunctionInfoListsByCombinedInputKeyStore:GetKeyPaths()
	do
		local boundFunctionInfos =
			boundFunctionInfoListsByCombinedInputKeyStore
			:GetByKeyPath(combinedInputKey)

		for j, boundFunctionInfo in boundFunctionInfos do
			self:_removeBoundFunctionInfoFromList(boundFunctionInfo)
		end
	end

	boundFunctionInfoListsByCombinedInputKeyStore:Reset()
end

--[=[
	입력 키 목록을 일괄 지정합니다.

	@param ... InputKey | CombinedInputKey
]=]
function ContextAction:SetInputKeys(...: InputKey | CombinedInputKey)
	self:ResetInputKeys()

	for i, inputKey in {...} do
		self:AddInputKey(inputKey)
	end
end

--[=[
	ContextAction 의 우선순위를 직접 지정합니다.

	@param priority number
]=]
function ContextAction:SetPriority(priority: number)
	if self.IsPriorityInherited then
		local warnMsg =
			`Attempted to change the priority of ContextAction "{self}" ` ..
			`while priority inheritance is enabled. Priority inheritance has been set to false.`

		warn(warnMsg)
		self:SetPriorityInheritance(false)
	end

	self:_rawSetPriority(priority)
end

function ContextAction:_rawSetPriority(priority: number)
	if self.Priority == priority then
		return
	end

	self.Priority = priority
	self.PriorityChanged:Fire(priority)

	local boundFunctionInfoListsByCombinedInputKeyStore = self.BoundFunctionInfoListsByCombinedInputKeyStore
	local inputKeys = boundFunctionInfoListsByCombinedInputKeyStore:GetKeyPaths()

	self:ResetInputKeys()

	for i, inputKey in inputKeys do
		self:AddInputKey(inputKey)
	end
end

--[=[
	우선순위를 UserInputManager 기본값에서 상속할지 여부를 설정합니다.

	@param isPriorityInherited boolean
]=]
function ContextAction:SetPriorityInheritance(isPriorityInherited: boolean)
	if self.IsPriorityInherited == isPriorityInherited then
		return
	end

	self.IsPriorityInherited = isPriorityInherited
	self.PriorityInheritanceChanged:Fire(isPriorityInherited)

	if isPriorityInherited then
		local userInputManager = self.UserInputManager
		self:_rawSetPriority(userInputManager.DefaultPriority)

		local syncFromUserInputManagerConn =
			userInputManager.DefaultPriorityChanged:Connect(function(priority)
				self:_rawSetPriority(priority)
			end)

		self.PriorityInheritanceChanged:Once(function()
			syncFromUserInputManagerConn:Destroy()
		end)
	end
end

--[=[
	현재 우선순위를 반환합니다.

	@return number
]=]
function ContextAction:GetPriority(): number
	return self.Priority
end

--#endregion Methods

return ContextAction
