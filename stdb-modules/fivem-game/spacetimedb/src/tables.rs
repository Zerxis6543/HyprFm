// G:\FIVEMSTDBPROJECT\stdb-modules\fivem-game\spacetimedb\src\tables.rs
// COMPLETE FILE — replace entire contents

use spacetimedb::{Identity, Timestamp};

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

// ── PLAYER ────────────────────────────────────────────────────────────────────

#[spacetimedb::table(accessor = player, public)]
#[derive(Clone, Debug)]
pub struct Player {
    #[primary_key]
    pub identity:     Identity,
    pub steam_hex:    String,
    pub display_name: String,
    pub money_cash:   i64,
    pub money_bank:   i64,
    pub job:          String,
    pub created_at:   Timestamp,
    pub last_seen:    Timestamp,
}

#[spacetimedb::table(accessor = active_session, public)]
#[derive(Clone, Debug)]
pub struct ActiveSession {
    #[primary_key]
    pub identity:     Identity,
    pub server_id:    u32,
    pub net_id:       u32,
    pub connected_at: Timestamp,
}

#[spacetimedb::table(accessor = spawn_request, public)]
#[derive(Clone, Debug)]
pub struct SpawnRequest {
    #[primary_key]
    #[auto_inc]
    pub id:            u64,
    pub identity:      Identity,
    pub spawn_x:       f32,
    pub spawn_y:       f32,
    pub spawn_z:       f32,
    pub spawn_heading: f32,
    pub model_hash:    u32,
    pub fulfilled:     bool,
}

// ── INVENTORY ─────────────────────────────────────────────────────────────────

/// Master item catalog — seeded once on sidecar startup.
#[spacetimedb::table(accessor = item_definition, public)]
#[derive(Clone, Debug)]
pub struct ItemDefinition {
    #[primary_key]
    pub item_id:        String,
    pub label:          String,
    pub weight:         f32,
    pub stackable:      bool,
    pub usable:         bool,
    pub max_stack:      u32,
    pub category:       String,
    pub prop_model:     String,
    pub mag_capacity:   i32,
    pub stored_capacity: i32,
    pub ammo_type:      String,
}

/// One row per stack of items in any inventory.
/// owner_id  = identity hex (player) | plate (vehicle) | stash_id (stash/prop)
/// owner_type = "player" | "vehicle_glovebox" | "vehicle_trunk" | "stash"
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
    pub metadata:   String,   // JSON: durability, ammo, serial, etc.
    pub slot_index: u32,
}

// ── VEHICLE INVENTORIES ───────────────────────────────────────────────────────

/// Per-vehicle inventory config — one row per plate, created on first access.
/// trunk_type = "rear" | "front" | "none"
#[spacetimedb::table(accessor = vehicle_inventory, public)]
#[derive(Clone, Debug)]
pub struct VehicleInventory {
    #[primary_key]
    pub plate:               String,
    pub model_hash:          u32,
    pub trunk_type:          String,
    pub trunk_slots:         u32,
    pub trunk_max_weight:    f32,
    pub glovebox_max_weight: f32,   // always 10.0
}

// ── STASHES ───────────────────────────────────────────────────────────────────

/// World prop stashes, player stashes, job lockers, etc.
/// stash_id is unique: "dumpster_12345", "player_stash_abc", "pd_evidence_1"
/// owner_id = "" for world/job stashes, identity hex for player-owned stashes.
#[spacetimedb::table(accessor = stash_definition, public)]
#[derive(Clone, Debug)]
pub struct StashDefinition {
    #[primary_key]
    pub stash_id:   String,
    /// "dumpster" | "player_stash" | "job_stash" | "world"
    pub stash_type: String,
    pub label:      String,
    pub max_slots:  u32,
    pub max_weight: f32,
    pub owner_id:   String,
    pub pos_x:      f32,
    pub pos_y:      f32,
    pub pos_z:      f32,
}
