// core/spacetimedb/src/opcodes.rs
//
// ── HyprFm Opcode Vocabulary ─────────────────────────────────────────────────
//
// These constants are the ONLY place engine-specific concepts are named.
// Rust reducers emit these strings into the instruction_queue.
// The Lua adapter (server/main.lua) is the sole translator from opcode → native.
//
// Porting rule: to support a new engine (GTA 6, Unreal, etc.) you add a new
// Lua/engine adapter that maps these same strings to different native calls.
// Zero Rust changes required.
//
// Naming convention: DOMAIN:VERB
//   - ENTITY  → operations on a game world entity (position, health, model)
//   - EFFECT  → gameplay effects applied to a player (heal, hunger, thirst)
//   - WEAPON  → weapon management on a ped

/// Entity manipulation opcodes.
/// Rust emits these; the Lua adapter translates them to engine natives.
pub mod entity {
    /// Move an entity to new world coordinates.
    /// Payload: `{ "x": f32, "y": f32, "z": f32 }`
    pub const SET_COORDS: &str = "ENTITY:SET_COORDS";

    /// Freeze or unfreeze an entity in place.
    /// Payload: `{ "frozen": bool }`
    pub const SET_FROZEN: &str = "ENTITY:SET_FROZEN";

    /// Change the model of an entity (ped character swap etc.).
    /// Payload: `{ "model_hash": u32 }`
    pub const SET_MODEL: &str = "ENTITY:SET_MODEL";

    /// Set the raw health value of an entity.
    /// Payload: `{ "value": u32 }`  (GTA5 scale: 100–200, 200 = full)
    pub const SET_HEALTH: &str = "ENTITY:SET_HEALTH";

    /// Give a weapon to a ped entity.
    /// Payload: `{ "weapon_hash": u32, "ammo": u32 }`
    pub const GIVE_WEAPON: &str = "ENTITY:GIVE_WEAPON";
}

/// Gameplay effect opcodes applied to a player character.
/// The Lua adapter routes these to the client via the appropriate event.
pub mod effect {
    /// Restore health to the target player.
    /// Payload: `{ "amount": u32 }`
    pub const HEAL: &str = "EFFECT:HEAL";

    /// Restore hunger/food status to the target player.
    /// Payload: `{ "amount": u32 }`
    pub const HUNGER: &str = "EFFECT:HUNGER";

    /// Restore thirst/drink status to the target player.
    /// Payload: `{ "amount": u32 }`
    pub const THIRST: &str = "EFFECT:THIRST";
}