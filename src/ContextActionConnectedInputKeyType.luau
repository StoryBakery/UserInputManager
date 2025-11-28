local KeyType = {}

type InputKey = Enum.UserInputType | Enum.KeyCode

local function getInputKeyName(inputKey: InputKey): string
	return if inputKey.EnumType == Enum.UserInputType
		then inputKey.Name
		else `KeyCode {inputKey.Name}`
end

function KeyType.CombinedInputKeyToString(inputKeyList: {InputKey})
	if #inputKeyList == 1 then
		local inputKey = inputKeyList[1]
		return `InputKey {getInputKeyName(inputKey)}`
	else
		local inputKeyNames = {}
		
		for i, inputKey in inputKeyList do
			table.insert(inputKeyNames, getInputKeyName(inputKey))
		end
		
		return `CombinedInputKey {table.concat(inputKeyNames, " + ")}`
	end
end

return KeyType