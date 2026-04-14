Opcode = {
    Entity = {
        SetCoords  = nil,  -- entity:set_coords  (fixed: 0x1001)
        SetFrozen  = nil,  -- entity:set_frozen  (fixed: 0x1002)
        SetModel   = nil,  -- entity:set_model   (fixed: 0x1003)
        SetHealth  = nil,  -- entity:set_health  (fixed: 0x1004)
        GiveWeapon = nil,  -- entity:give_weapon (fixed: 0x1005)
    },
    Effect = {
        Heal   = nil,  -- effect:heal   (fixed: 0x1006)
        Hunger = nil,  -- effect:hunger (fixed: 0x1007)
        Thirst = nil,  -- effect:thirst (fixed: 0x1008)
    },
    Engine = {
        CallLocalNative = nil,  -- engine:call_local_native (fixed: 0x1009)
    },
}

--- Format an opcode number for logging.
--- @param opcode integer
--- @return string  e.g. "0x1006"
function Opcode.Format(opcode)
    if type(opcode) ~= "number" then return "0x????" end
    return ("0x%04X"):format(opcode)
end