-- shared/constants.lua
-- ── HyprFM Opcode Registry — Developer Experience Layer ───────────────────────
--
-- This file is the ONLY place a third-party developer needs to understand
-- to use the instruction system. They never see hex numbers.
--
-- Usage:
--   exports['stdb-relay']:InvokeNative(Opcode.Effect.Heal, netId, { 40 })
--   exports['stdb-relay']:InvokeNative(Opcode.Entity.SetHealth, netId, { 200 })
--
-- Structure mirrors opcodes.rs exactly.
-- When adding a new opcode:
--   1. Add it to opcodes.rs (Rust)
--   2. Add it here (Lua) with the identical hex value and doc comment
--   3. Add a handler row to the Dispatcher table in main.lua
-- ─────────────────────────────────────────────────────────────────────────────

Opcode = {}

-- ── 0x1000 Entity domain ─────────────────────────────────────────────────────
-- Operations that mutate a networked game-world entity.
Opcode.Entity = {
    --- Teleport entity to world coordinates.
    --- args: { x, y, z, xAxis, yAxis, clearArea }
    SetCoords  = 0x1001,

    --- Freeze or unfreeze an entity.
    --- args: { frozen }   (true/false)
    SetFrozen  = 0x1002,

    --- Swap the visual model of a ped/object.
    --- args: { model_hash }
    SetModel   = 0x1003,

    --- Set raw health value.
    --- args: { value }   GTA5 scale: 100-200, 200 = full
    SetHealth  = 0x1004,

    --- Give a weapon to a ped.
    --- args: { weapon_hash, ammo }
    GiveWeapon = 0x1005,
}

-- ── 0x2000 Effect domain ─────────────────────────────────────────────────────
-- Client-side gameplay effects applied to a living player character.
-- All effects trigger a client-side animation.
Opcode.Effect = {
    --- Restore player health by a delta amount.
    --- args: { amount }
    Heal   = 0x2001,

    --- Restore player hunger/food status.
    --- args: { amount }
    Hunger = 0x2002,

    --- Restore player thirst/drink status.
    --- args: { amount }
    Thirst = 0x2003,
}

-- ── 0x9000 Engine domain ─────────────────────────────────────────────────────
-- VOLATILE — NOT stored in SpacetimeDB, NOT replayed on reconnect.
-- Use ONLY for cosmetic one-shots: sounds, particles, screen effects.
-- If persistence matters, use Entity or Effect opcodes instead.
Opcode.Engine = {
    --- Transparent proxy for a single cosmetic engine native.
    --- args: { nativeName, arg1, arg2, ... }
    --- Example: { "PLAY_SOUND_FRONTEND", -1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS" }
    CallLocalNative = 0x9001,
}

-- ── Helper utilities ──────────────────────────────────────────────────────────

--- Extract the domain nibble (high 4 bits) from any opcode.
--- @param opcode integer  u16 opcode value
--- @return integer  domain identifier (0x1000, 0x2000, etc.)
function Opcode.GetDomain(opcode)
    return opcode & 0xF000
end

--- Extract the action component (low 12 bits) from any opcode.
--- @param opcode integer  u16 opcode value
--- @return integer  action offset within its domain
function Opcode.GetAction(opcode)
    return opcode & 0x0FFF
end

--- Returns true for ENGINE domain opcodes (volatile, not persisted).
--- @param opcode integer
--- @return boolean
function Opcode.IsVolatile(opcode)
    return Opcode.GetDomain(opcode) == 0x9000
end

--- Format an opcode as its canonical 4-digit hex string for logging.
--- @param opcode integer
--- @return string   e.g. "0x1004"
function Opcode.Format(opcode)
    return ("0x%04X"):format(opcode)
end