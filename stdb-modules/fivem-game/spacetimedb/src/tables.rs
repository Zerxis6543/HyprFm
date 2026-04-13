use spacetimedb::Timestamp;

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN RULES
//
// owner_id convention in InventorySlot:
//   player inventory  → format!("{}", character.id)   e.g. "42"
//   equip slot        → "{char_id}_equip_{key}"        e.g. "42_equip_weapon_primary"
//   backpack stash    → "backpack_slot_{bag_slot_id}"
//   vehicle trunk     → plate string                   e.g. "ABC 123"
//   vehicle glovebox  → plate string
//   world stash       → stash_id string                e.g. "ground_17234..."
// ─────────────────────────────────────────────────────────────────────────────

// ── CORE ─────────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = instruction_queue, public)]
#[derive(Clone, Debug)]
pub struct InstructionQueue {
    #[primary_key]
    #[auto_inc]
    pub id:                   u64,
    pub target_entity_net_id: u32,
    pub opcode:               u16,
    pub payload:              String,
    pub queued_at:            Timestamp,
    pub consumed:             bool,
}

// ── ACCOUNT ───────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = account, public)]
#[derive(Clone, Debug)]
pub struct Account {
    #[primary_key]
    pub steam_hex:      String,
    pub display_name:   String,
    pub created_at:     Timestamp,
    pub last_seen:      Timestamp,
    pub is_banned:      bool,
    pub ban_reason:     String,
    pub max_characters: u32,
}

// ── CHARACTER ─────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = character, public)]
#[derive(Clone, Debug)]
pub struct Character {
    #[primary_key]
    #[auto_inc]
    pub id:         u64,
    #[index(btree)]
    pub steam_hex:  String,
    pub slot_index: u32,
    pub name:       String,
    pub gender:     String,
    pub pos_x:      f32,
    pub pos_y:      f32,
    pub pos_z:      f32,
    pub heading:    f32,
    pub health:     u32,
    pub hunger:     u32,
    pub thirst:     u32,
    pub money_cash: i64,
    pub money_bank: i64,
    pub job:        String,
    pub job_grade:  u32,
    pub is_deleted: bool,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
}

// ── CHARACTER APPEARANCE ──────────────────────────────────────────────────────

#[spacetimedb::table(accessor = character_appearance, public)]
#[derive(Clone, Debug)]
pub struct CharacterAppearance {
    #[primary_key]
    pub character_id:    u64,
    pub components_json: String,
    pub overlays_json:   String,
    pub updated_at:      Timestamp,
}

// ── CHARACTER SESSION ─────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = char_session, public)]
#[derive(Clone, Debug)]
pub struct CharSession {
    #[primary_key]
    pub steam_hex:     String,
    pub character_id:  u64,
    #[index(btree)]
    pub server_id:     u32,
    pub net_id:        u32,
    pub connected_at:  Timestamp,
    pub inventory_ack: bool,
}

// ── DISCONNECT LOG ────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = disconnect_log, public)]
#[derive(Clone, Debug)]
pub struct DisconnectLog {
    #[primary_key]
    pub steam_hex:      String,
    pub character_id:   u64,
    pub last_server_id: u32,
    pub last_pos_x:     f32,
    pub last_pos_y:     f32,
    pub last_pos_z:     f32,
    pub last_health:    u32,
    pub clean:          bool,
    pub logged_at:      Timestamp,
}

// ── INVENTORY ─────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = item_definition, public)]
#[derive(Clone, Debug)]
pub struct ItemDefinition {
    #[primary_key]
    pub item_id:         String,
    pub label:           String,
    pub weight:          f32,
    pub stackable:       bool,
    pub usable:          bool,
    pub max_stack:       u32,
    pub category:        String,
    pub prop_model:      String,
    pub mag_capacity:    i32,
    pub stored_capacity: i32,
    pub ammo_type:       String,
}

#[spacetimedb::table(accessor = inventory_slot, public)]
#[derive(Clone, Debug)]
pub struct InventorySlot {
    #[primary_key]
    #[auto_inc]
    pub id:         u64,
    pub owner_id:   String,
    pub owner_type: String,
    pub item_id:    String,
    pub quantity:   u32,
    pub metadata:   String,
    pub slot_index: u32,
}

// ── VEHICLE INVENTORIES ───────────────────────────────────────────────────────

#[spacetimedb::table(accessor = vehicle_inventory, public)]
#[derive(Clone, Debug)]
pub struct VehicleInventory {
    #[primary_key]
    pub plate:               String,
    pub model_hash:          u32,
    pub trunk_type:          String,
    pub trunk_slots:         u32,
    pub trunk_max_weight:    f32,
    pub glovebox_max_weight: f32,
}

// ── STASHES ───────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = stash_definition, public)]
#[derive(Clone, Debug)]
pub struct StashDefinition {
    #[primary_key]
    pub stash_id:   String,
    pub stash_type: String,
    pub label:      String,
    pub max_slots:  u32,
    pub max_weight: f32,
    pub owner_id:   String,
    pub pos_x:      f32,
    pub pos_y:      f32,
    pub pos_z:      f32,
}

// ── PLAYER CONFIG ─────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = player_config, public)]
#[derive(Clone, Debug)]
pub struct PlayerConfig {
    #[primary_key]
    pub steam_hex:        String,
    pub max_carry_weight: f32,
}

// ── STARTER KIT ───────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = starter_kit_entry, public)]
#[derive(Clone, Debug)]
pub struct StarterKitEntry {
    #[primary_key]
    #[auto_inc]
    pub id:       u64,
    pub item_id:  String,
    pub quantity: u32,
}

// ── DYNAMIC OPCODE REGISTRY ───────────────────────────────────────────────────
// Lifecycle: allocated → (optionally consumed) → reaped.
// Permanent registrations (ttl_seconds = 0 → expires_at_micros = u64::MAX)
// are never touched by the Reaper — they survive server restarts.
// The C# sidecar mirrors this table in _dynamicOpcodes via delta callbacks.

#[spacetimedb::table(accessor = dynamic_opcode, public)]
#[derive(Clone, Debug)]
pub struct DynamicOpcode {
    #[primary_key]
    pub opcode: u16,

    /// Stable label used as the correlation key. For RegisterOpcode calls this
    /// is the plain label string ("robbery_begin"). For player-session opcodes
    /// it is "<uuid12>:<label>" to guarantee uniqueness.
    pub context: String,

    pub owner_steam_hex: String,
    pub net_id:          u32,

    pub allocated_at: Timestamp,

    /// Unix microseconds at which this opcode expires.
    /// u64::MAX = permanent (registered by RegisterOpcode with ttl_seconds = 0).
    pub expires_at_micros: u64,

    /// Set by consume_opcode. Prevents double-execution on retries.
    /// Reaper sweeps rows where is_consumed = true.
    pub is_consumed: bool,
}

// ── OPCODE ALLOCATOR SINGLETON ────────────────────────────────────────────────
// Single row (id = 0). Tracks the rolling cursor across the dynamic domain.
// Private — never exposed to clients or sidecar.

#[spacetimedb::table(accessor = opcode_allocator, private)]
#[derive(Clone, Debug)]
pub struct OpcodeAllocator {
    #[primary_key]
    pub id:             u8,   // always 0
    pub next_candidate: u16,  // rolling cursor; wraps at DOMAIN_MAX
}

// ── REAPER SCHEDULE ───────────────────────────────────────────────────────────
// SpacetimeDB 2.0 scheduled table. One interval row inserted by init().
// The runtime re-queues it automatically after each firing.

#[spacetimedb::table(name = reaper_schedule, scheduled(opcode_reaper_sweep))]
#[derive(Clone, Debug)]
pub struct ReaperSchedule {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: spacetimedb::ScheduleAt,
}