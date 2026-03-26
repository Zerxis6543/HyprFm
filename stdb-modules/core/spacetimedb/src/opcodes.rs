/// Extract the 4-bit domain nibble (high bits) from any opcode.
#[inline(always)]
pub const fn domain(opcode: u16) -> u16 {
    opcode & 0xF000
}

/// Extract the 12-bit action component (low bits) from any opcode.
#[inline(always)]
pub const fn action(opcode: u16) -> u16 {
    opcode & 0x0FFF
}

// ── Domain sentinels (for range-checks and documentation) ────────────────────

pub mod domains {
    /// 0x1___ — Operations that mutate a game-world entity's persistent state.
    pub const ENTITY: u16 = 0x1000;
    /// 0x2___ — Gameplay effects applied to a living player character.
    pub const EFFECT: u16 = 0x2000;
    /// 0x9___ — Engine meta-instructions; volatile, never replayed on reconnect.
    pub const ENGINE: u16 = 0x9000;
}

// ── 0x1000 Entity domain ─────────────────────────────────────────────────────
//  Targets: any networked game entity (ped, vehicle, object)
//  Routing: some are client-side natives (coords, model), some server-side.
//  The Lua Dispatcher table in main.lua decides routing — not this file.

pub mod entity {
    /// Teleport entity to absolute world coordinates.
    /// Payload: `[x: f32, y: f32, z: f32, xAxis: bool, yAxis: bool, clearArea: bool]`
    pub const SET_COORDS: u16 = 0x1001;

    /// Freeze or unfreeze an entity in world space.
    /// Payload: `[frozen: bool]`
    pub const SET_FROZEN: u16 = 0x1002;

    /// Swap the visual model of a ped or object.
    /// Payload: `[model_hash: u32]`
    pub const SET_MODEL: u16 = 0x1003;

    /// Set raw health value (engine-specific scale).
    /// GTA5: 100–200 range, 200 = full health.
    /// Payload: `[value: u32]`
    pub const SET_HEALTH: u16 = 0x1004;

    /// Give a weapon with initial ammo to a ped entity.
    /// Payload: `[weapon_hash: u32, ammo: u32]`
    pub const GIVE_WEAPON: u16 = 0x1005;
}

// ── 0x2000 Effect domain ─────────────────────────────────────────────────────
//  Targets: a specific player (resolved via netId → serverId in the relay)
//  Routing: always forwarded to the owning client via TriggerClientEvent.
//  The client applies the effect locally with the appropriate animation.

pub mod effect {
    /// Restore player health by a delta amount.
    /// Payload: `[amount: u32]`
    pub const HEAL: u16 = 0x2001;

    /// Restore player hunger/food status.
    /// Payload: `[amount: u32]`
    pub const HUNGER: u16 = 0x2002;

    /// Restore player thirst/drink status.
    /// Payload: `[amount: u32]`
    pub const THIRST: u16 = 0x2003;
}

// ── 0x9000 Engine domain ─────────────────────────────────────────────────────
//  VOLATILE — instructions in this domain are NEVER replayed on reconnect.
//  Use only for one-shot cosmetic effects: sounds, particles, screen effects.
//  If the effect must be re-applied when a player rejoins, use a state-backed
//  opcode in the Entity or Effect domain instead.

pub mod engine {
    /// Transparent proxy for a single cosmetic engine call.
    /// The first payload element is the native's string identifier.
    /// Remaining elements are positional arguments for that native.
    ///
    /// Payload: `[nativeName: String, arg0, arg1, ...]`
    ///
    /// Example (play a UI sound):
    /// `["PLAY_SOUND_FRONTEND", -1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS"]`
    ///
    /// The client maintains a whitelist of allowed native names to prevent
    /// this channel from being weaponised as an arbitrary code execution path.
    pub const CALL_LOCAL_NATIVE: u16 = 0x9001;
}