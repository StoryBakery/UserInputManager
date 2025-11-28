--[=[
	@class ContextMouseIcon

	호스트 마우스에 우선순위 기반 아이콘을 표시하는 객체입니다.
]=]

local TableUtil = require("../../roblox_packages/TableUtil")

local ContextMouseIcon = {}
ContextMouseIcon.__index = ContextMouseIcon
ContextMouseIcon.__type = "ContextMouseIcon"



export type ContextMouseIconId = string | {Plugin: string, Client: string}

type HostMouse<UserInputManager = any> = {
	BoundMouseIcons: {ContextMouseIcon<UserInputManager>},
	UserInputManager: any,
}

export type ContextMouseIcon<UserInputManager = any> = setmetatable<{
	IsDestroyed: boolean,
	Icon: ContextMouseIconId,
	Priority: number,
	ParentMouse: HostMouse<UserInputManager>,
	UserInputManager: UserInputManager,
	CreatedTime: number,
}, typeof(ContextMouseIcon)>

--[=[
	컨텍스트 마우스 아이콘을 생성합니다.

	@param mouse HostMouse
	@param icon ContextMouseIconId
	@param priority number | "Inherit"
	@return ContextMouseIcon
]=]
function ContextMouseIcon.new(
	mouse: HostMouse,
	icon: ContextMouseIconId,
	priority: number | "Inherit"
): ContextMouseIcon

	local self = setmetatable({}, ContextMouseIcon)
	self.IsDestroyed = false
	self.Icon = icon or error("Icon is nil")

	local userInputManager = mouse.UserInputManager
	self.ParentMouse = mouse
	self.UserInputManager = userInputManager
	self.CreatedTime = os.clock()

	local isPriorityInherited = priority == "Inherit"
	if isPriorityInherited then
		self.Priority = userInputManager:GetDefaultPriority()
	else
		self.Priority = priority
	end

	local boundMouseIcons = mouse.BoundMouseIcons

	local index = TableUtil.bisectLeft(boundMouseIcons, self, function(a, b)
		if a.Priority == b.Priority then
			return a.CreatedTime > b.CreatedTime
		else
			return a.Priority > b.Priority
		end
	end)

	table.insert(boundMouseIcons, index, self)
	self.UserInputManager:_updateMouseIcon()

	return self
end

--[=[
	아이콘을 제거하고 우선순위 리스트에서 분리합니다.
]=]
function ContextMouseIcon:Destroy()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	local boundMouseIcons = self.ParentMouse.BoundMouseIcons

	local index = TableUtil.binarySearch(boundMouseIcons, self, function(a, b)
		if a.Priority == b.Priority then
			return a.CreatedTime > b.CreatedTime
		else
			return a.Priority > b.Priority
		end
	end)

	table.remove(boundMouseIcons, index)
	task.defer(function()
		table.freeze(self :: any)
	end)
	self.UserInputManager:_updateMouseIcon()
end

--[=[
	다른 아이콘보다 우선순위가 높은지 비교합니다.

	@param other ContextMouseIcon
	@return boolean
]=]
function ContextMouseIcon:IsPriorityHigherThan(other: ContextMouseIcon): boolean
	return
		self.Priority > other.Priority
		or (
			self.Priority == other.Priority
			and self.CreatedTime > other.CreatedTime
		)
end

--[=[
	아이콘의 우선순위를 반환합니다.

	@return number
]=]
function ContextMouseIcon:GetPriority(): number
	return self.Priority
end

return ContextMouseIcon
