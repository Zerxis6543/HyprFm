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
//
// Accounts own Characters. Characters own inventory. Sessions are ephemeral.
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
// One row per unique player. Never hard-deleted — only soft-banned.
// steam_hex is the canonical cross-system identity.
#[spacetimedb::table(accessor = account, public)]
#[derive(Clone, Debug)]
pub struct Account {
    #[primary_key]
    pub steam_hex:       String,

    /// Display name as of last connect. Cosmetic only — never used for auth.
    pub display_name:    String,

    pub created_at:      Timestamp,
    pub last_seen:       Timestamp,

    pub is_banned:       bool,
    pub ban_reason:      String,

    /// Maximum characters this account may have. Default 3.
    /// Can be raised per-account for VIP tiers via set_account_max_characters.
    pub max_characters:  u32,
}

// ── CHARACTER ─────────────────────────────────────────────────────────────────
// Vital game state. Written frequently — kept narrow to minimise write cost.
// Multiple Characters can share one Account (steam_hex).
// The u64 PK is the canonical owner identity for all inventory operations.
#[spacetimedb::table(accessor = character, public)]
#[derive(Clone, Debug)]
pub struct Character {
    #[primary_key]
    #[auto_inc]
    pub id:         u64,

    /// FK → Account.steam_hex.
    #[index(btree)]
    pub steam_hex:  String,

    /// 0-based slot within the account (0, 1, 2).
    /// Unique per (steam_hex, slot_index) — enforced in create_character reducer.
    pub slot_index: u32,

    /// In-game character name. Display only.
    pub name:       String,

    /// "male" | "female"
    pub gender:     String,

    // ── Last known position (written on disconnect + checkpoint interval) ──────
    pub pos_x:      f32,
    pub pos_y:      f32,
    pub pos_z:      f32,
    pub heading:    f32,

    // ── Vitals ─────────────────────────────────────────────────────────────────
    pub health:     u32,   // GTA scale 100–200. 200 = full.
    pub hunger:     u32,   // 0–100.
    pub thirst:     u32,   // 0–100.

    // ── Economy ────────────────────────────────────────────────────────────────
    pub money_cash: i64,
    pub money_bank: i64,

    // ── Job ────────────────────────────────────────────────────────────────────
    pub job:        String,
    pub job_grade:  u32,

    // ── Lifecycle ──────────────────────────────────────────────────────────────
    /// Soft-delete. Inventory slots are retained 7 days for rollback.
    pub is_deleted: bool,

    pub created_at: Timestamp,
    pub updated_at: Timestamp,
}

// ── CHARACTER APPEARANCE ──────────────────────────────────────────────────────
// Separated from Character to keep the hot-path write row narrow.
// Written only at creation and barber/clothing shop visits.
#[spacetimedb::table(accessor = character_appearance, public)]
#[derive(Clone, Debug)]
pub struct CharacterAppearance {
    #[primary_key]
    pub character_id:    u64,

    /// JSON blob of GTA ped component/prop variations.
    /// Schema is client-defined — server treats it as opaque bytes.
    pub components_json: String,

    /// Tattoos, accessories, face overlays — same opaque JSON pattern.
    pub overlays_json:   String,

    pub updated_at:      Timestamp,
}

// ── CHARACTER SESSION ─────────────────────────────────────────────────────────
// Ephemeral connection state. Deleted on clean disconnect.
// On dirty disconnect (crash) the row is left behind — Reaper cleans it.
// The sidecar reads THIS table for server_id ↔ (steam_hex, character_id) routing.
#[spacetimedb::table(accessor = char_session, public)]
#[derive(Clone, Debug)]
pub struct CharSession {
    #[primary_key]
    pub steam_hex:     String,

    pub character_id:  u64,

    /// FiveM server_id. Volatile — reassigned each connect.
    #[index(btree)]
    pub server_id:     u32,

    /// GTA network entity ID of the player's ped.
    pub net_id:        u32,

    pub connected_at:  Timestamp,

    /// True once the client has received its first inventory payload.
    /// Sidecar will not route slot deltas until this is set.
    pub inventory_ack: bool,
}

// ── DISCONNECT LOG ────────────────────────────────────────────────────────────
// Written atomically with CharSession deletion.
// If this row exists but CharSession does NOT, the player crashed — reconcile on next connect.
// Reaper purges entries older than its threshold.
#[spacetimedb::table(accessor = disconnect_log, public)]
#[derive(Clone, Debug)]
pub struct DisconnectLog {
    #[primary_key]
    pub steam_hex:       String,

    pub character_id:    u64,
    pub last_server_id:  u32,
    pub last_pos_x:      f32,
    pub last_pos_y:      f32,
    pub last_pos_z:      f32,
    pub last_health:     u32,

    /// true = clean disconnect reducer ran. false = dirty (crash, detected by Reaper).
    pub clean:           bool,
    pub logged_at:       Timestamp,
}

// ── INVENTORY ─────────────────────────────────────────────────────────────────

/// Master item catalog — seeded once on sidecar startup.
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

/// One row per stack of items in any inventory.
///
/// owner_id / owner_type pairs:
///   "42" / "player"           → character id 42's pocket slots
///   "42_equip_weapon_primary" / "equip"   → character 42's equip slot
///   "backpack_slot_99" / "stash"          → backpack contents
///   "ABC 123" / "vehicle_trunk"           → vehicle trunk
///   "ABC 123" / "vehicle_glovebox"        → vehicle glovebox
///   "ground_17234..." / "stash"           → world drop
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
// Keyed by owner_id (character_id string) for per-character carry weight.
// Legacy rows keyed by steam_hex are migrated on first access.
#[spacetimedb::table(accessor = player_config, public)]
#[derive(Clone, Debug)]
pub struct PlayerConfig {
    #[primary_key]
    pub steam_hex:        String,   // overloaded: also used for character_id string
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