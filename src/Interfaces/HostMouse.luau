--[=[
	@class HostMouse

	GuiObject 또는 UserInputService 호스트에 대한 마우스 상태를 추적합니다.
]=]

local Maid = require("../../roblox_packages/Maid")
local Signal = require("../../roblox_packages/Signal")

local UserInputService = game:GetService("UserInputService")

local ContextMouseIcon = require(script.Parent.ContextMouseIcon)

type Host = UserInputService | GuiObject

local HostMouse = {}
HostMouse.__index = HostMouse



export type HostMouse<UserInputManager = any> = setmetatable<{
	IsDestroyed: boolean,
	Destroying: Signal.Signal,
	Maid: Maid.Maid,
	Host: Host,
	Moved: Signal.Signal,
	UserInputManager: UserInputManager,
	BoundMouseIcons: {ContextMouseIcon.ContextMouseIcon},
	X: number,
	Y: number,
}, typeof(HostMouse)>

--[=[
	HostMouse 를 생성합니다.

	@param userInputManager UserInputManager
	@param host Host
	@return HostMouse
]=]
function HostMouse.new(userInputManager: any, host: Host)
	local self = setmetatable({}, HostMouse)
	self.IsDestroyed = false
	self.Destroying = Signal.new()
	self.Maid = Maid.new()

	self.Host = host
	self.Moved = Signal.new()
	self.UserInputManager = userInputManager
	self.BoundMouseIcons = {}

	self:_detectMouseMovement()

	return self
end

function HostMouse:_detectMouseMovement()
	local host = self.Host
	local maid = self.Maid

	if host == UserInputService then
		local lastPos = host:GetMouseLocation()
		self.X, self.Y = lastPos.X, lastPos.Y
	else
		self.X, self.Y = 0, 0
	end

	local function updateMousePos(pos: Vector3)
		local x, y = pos.X, pos.Y
		if self.X ~= x or self.Y ~= y then
			self.X, self.Y = x, y
			self.Moved:Fire(x, y)
		end
	end

	local mousePosConnsByInput = {}

	local connToGetMouseMovement = host.InputChanged:Connect(function(input)
		if mousePosConnsByInput[input] then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		updateMousePos(input.Position)
		mousePosConnsByInput[input] = input:GetPropertyChangedSignal("Position"):Connect(function()
			updateMousePos(input.Position)
		end)
	end)

	maid:GiveTask(connToGetMouseMovement, function()
		for input, conn in mousePosConnsByInput do
			conn:Disconnect()
		end
	end)
end

--[=[
	현재 마우스 좌표를 반환합니다.

	@return Vector2
]=]
function HostMouse:GetPosition(): Vector2
	return Vector2.new(self.X, self.Y)
end

--[=[
	마우스가 지정한 사각형 안에 있는지 확인합니다.

	@param x number
	@param y number
	@param width number
	@param height number
	@return boolean
]=]
function HostMouse:IsInRect(x: number, y: number, width: number, height: number): boolean
	return
		x <= self.X
		and self.X <= x + width
		and y <= self.Y
		and self.Y <= y + height
end

--[=[
	마우스가 특정 GuiObject 내부에 있는지 확인합니다.

	@param frame GuiObject
	@param epsilon number?
	@return boolean
]=]
function HostMouse:IsInFrame(frame: GuiObject, epsilon: number?): boolean
	local absPos, absSize = frame.AbsolutePosition, frame.AbsoluteSize
	local resolvedEpsilon = epsilon or 0

	return self:IsInRect(
		absPos.X - resolvedEpsilon,
		absPos.Y - resolvedEpsilon,
		absSize.X + resolvedEpsilon,
		absSize.Y + resolvedEpsilon
	)
end

--[=[
	현재 호스트에 우선순위 기반 마우스 아이콘을 추가합니다.

	@param icon ContextMouseIcon.ContextMouseIconId
	@param priority number | "Inherit"?
	@return ContextMouseIcon.ContextMouseIcon
]=]
function HostMouse:AddContextMouseIcon(
	icon: ContextMouseIcon.ContextMouseIconId,
	priority: number | "Inherit"?
): ContextMouseIcon.ContextMouseIcon
	return ContextMouseIcon.new(self, icon, priority or "Inherit")
end

--[=[
	HostMouse 를 파괴하고 연결된 리소스를 해제합니다.
]=]
function HostMouse:Destroy()
	self.IsDestroyed = true
	self.Destroying:Fire()

	self.Maid:Destroy()

	task.defer(function()
		table.freeze(self :: any)
	end)
end

return HostMouse
