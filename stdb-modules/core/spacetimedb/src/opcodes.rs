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

// ── Domain sentinels ─────────────────────────────────────────────────────────

pub mod domains {
    pub const ENTITY:  u16 = 0x1000;
    pub const EFFECT:  u16 = 0x2000;
    pub const ENGINE:  u16 = 0x9000;
    pub const DYNAMIC: u16 = 0x4000;
}

// ── 0x1000 Entity domain ─────────────────────────────────────────────────────

pub mod entity {
    pub const SET_COORDS: u16 = 0x1001;
    pub const SET_FROZEN: u16 = 0x1002;
    pub const SET_MODEL:  u16 = 0x1003;
    pub const SET_HEALTH: u16 = 0x1004;
    pub const GIVE_WEAPON: u16 = 0x1005;
}

// ── 0x2000 Effect domain ─────────────────────────────────────────────────────

pub mod effect {
    pub const HEAL:   u16 = 0x2001;
    pub const HUNGER: u16 = 0x2002;
    pub const THIRST: u16 = 0x2003;
}

// ── 0x9000 Engine domain ─────────────────────────────────────────────────────

pub mod engine {
    pub const CALL_LOCAL_NATIVE: u16 = 0x9001;
}

// ── 0x4000–0x7FFF Dynamic domain ─────────────────────────────────────────────

pub mod dynamic {
    pub const DOMAIN_MIN: u16 = 0x4000;
    pub const DOMAIN_MAX: u16 = 0x7FFF;

    #[inline(always)]
    pub const fn is_dynamic(opcode: u16) -> bool {
        opcode >= DOMAIN_MIN && opcode <= DOMAIN_MAX
    }
}

// ── Label → opcode resolver ───────────────────────────────────────────────────
// Third-party reducers call this instead of hardcoding numbers.

pub fn registered_opcode(
    ctx:   &spacetimedb::ReducerContext,
    label: &str,
) -> Option<u16> {
    ctx.db.dynamic_opcode().iter()
        .find(|o| o.context == label)
        .map(|o| o.opcode)
}