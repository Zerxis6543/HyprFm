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

pub const DOMAIN_MIN:      u16 = 0x1000;
pub const DOMAIN_MAX:      u16 = 0x8FFF;
pub const ALLOCATOR_START: u16 = 0x1010; // cursor seeds here; skips 0x1000–0x100F

#[inline(always)]
pub fn is_in_range(opcode: u16) -> bool {
    opcode >= DOMAIN_MIN && opcode <= DOMAIN_MAX
}

// ── Core opcode labels ────────────────────────────────────────────────────────

pub mod labels {
    pub mod entity {
        pub const SET_COORDS:  &str = "entity:set_coords";
        pub const SET_FROZEN:  &str = "entity:set_frozen";
        pub const SET_MODEL:   &str = "entity:set_model";
        pub const SET_HEALTH:  &str = "entity:set_health";
        pub const GIVE_WEAPON: &str = "entity:give_weapon";
    }
    pub mod effect {
        pub const HEAL:   &str = "effect:heal";
        pub const HUNGER: &str = "effect:hunger";
        pub const THIRST: &str = "effect:thirst";
    }
    pub mod engine {
        pub const CALL_LOCAL_NATIVE: &str = "engine:call_local_native";
    }
}
