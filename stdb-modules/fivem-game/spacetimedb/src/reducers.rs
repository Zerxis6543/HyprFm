use spacetimedb::{ReducerContext, Table};
use crate::tables::*;
use serde_json::json;
use stdb_core::opcodes::{DOMAIN_MIN, DOMAIN_MAX, ALLOCATOR_START, labels};

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_SPAWN_X:        f32 = -269.0;
const DEFAULT_SPAWN_Y:        f32 = -955.0;
const DEFAULT_SPAWN_Z:        f32 =   31.0;
const DEFAULT_HEADING:        f32 =  205.0;
const DEFAULT_MAX_CHARACTERS: u32 = 3;

// ─────────────────────────────────────────────────────────────────────────────
// OWNER ID HELPERS
// ─────────────────────────────────────────────────────────────────────────────

fn char_owner_id(character_id: u64) -> String {
    format!("{}", character_id)
}

// ─────────────────────────────────────────────────────────────────────────────
// LABEL → OPCODE RESOLVER
// Lives here (not in core) because DynamicOpcode is a fivem-game table.
// Third-party crates that depend on stdb-fivem-game import this the same way.
//
// Example:
//   let op = registered_opcode(ctx, labels::effect::HEAL)
//       .ok_or("effect:heal not registered")?;
//   ctx.db.instruction_queue().insert(InstructionQueue { opcode: op, .. });
// ─────────────────────────────────────────────────────────────────────────────

pub fn registered_opcode(ctx: &ReducerContext, label: &str) -> Option<u16> {
    ctx.db.dynamic_opcode().iter()
        .find(|o| o.context == label)
        .map(|o| o.opcode)
}

// ─────────────────────────────────────────────────────────────────────────────
// METADATA HELPER
// ─────────────────────────────────────────────────────────────────────────────

fn build_starter_metadata(ctx: &ReducerContext, def: &ItemDefinition, suffix: u32) -> String {
    if def.category == "weapon" {
        let serial = format!(
            "WPN-{:08X}",
            (ctx.timestamp.to_micros_since_unix_epoch() as u32).wrapping_add(suffix)
        );
        format!(
            r#"{{"serial":"{}","mag_ammo":0,"stored_ammo":0,"mag_capacity":{},"stored_capacity":{},"durability":100,"ammo_type":"{}"}}"#,
            serial, def.mag_capacity, def.stored_capacity, def.ammo_type
        )
    } else {
        "{}".to_string()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE OPCODE SEED HELPER
// Called only from init(). Inserts at a fixed numeric position, bypassing the
// rolling allocator entirely. Idempotent — skips if the row already exists.
// ─────────────────────────────────────────────────────────────────────────────

fn seed_core_opcode(ctx: &ReducerContext, opcode: u16, label: &str) {
    if ctx.db.dynamic_opcode().opcode().find(opcode).is_some() { return; }
    ctx.db.dynamic_opcode().insert(DynamicOpcode {
        opcode,
        context:           label.to_string(),
        owner_steam_hex:   String::new(),
        net_id:            0,
        allocated_at:      ctx.timestamp,
        expires_at_micros: u64::MAX,  // permanent — Reaper never touches this
        is_consumed:       false,
    });
    log::info!("[init] Core opcode seeded: '{}' → 0x{:04X}", label, opcode);
}

// ─────────────────────────────────────────────────────────────────────────────
// MODULE INITIALISATION
// Runs once when the SpacetimeDB module is first published.
// Seeds all core opcodes at fixed positions, then arms the Reaper.
// The allocator cursor starts ABOVE the reserved core range (0x1000–0x100F).
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    // Core opcodes — fixed positions, permanent, never reaped
    seed_core_opcode(ctx, 0x1001, labels::entity::SET_COORDS);
    seed_core_opcode(ctx, 0x1002, labels::entity::SET_FROZEN);
    seed_core_opcode(ctx, 0x1003, labels::entity::SET_MODEL);
    seed_core_opcode(ctx, 0x1004, labels::entity::SET_HEALTH);
    seed_core_opcode(ctx, 0x1005, labels::entity::GIVE_WEAPON);
    seed_core_opcode(ctx, 0x1006, labels::effect::HEAL);
    seed_core_opcode(ctx, 0x1007, labels::effect::HUNGER);
    seed_core_opcode(ctx, 0x1008, labels::effect::THIRST);
    seed_core_opcode(ctx, 0x1009, labels::engine::CALL_LOCAL_NATIVE);

    // Allocator cursor starts above the reserved core range
    if ctx.db.opcode_allocator().id().find(0).is_none() {
        ctx.db.opcode_allocator().insert(OpcodeAllocator {
            id:             0,
            next_candidate: ALLOCATOR_START,
        });
    }

    // 12-hour Reaper schedule
    ctx.db.reaper_schedule().insert(ReaperSchedule {
        scheduled_id: 0,
        scheduled_at: spacetimedb::ScheduleAt::Interval(
            std::time::Duration::from_secs(12 * 3600).into()
        ),
    });

    log::info!("[init] Core opcodes seeded. Allocator starts at 0x{:04X}. Reaper armed.", ALLOCATOR_START);
}

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC OPCODE — ALLOCATE
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn allocate_opcode(
    ctx:             &ReducerContext,
    context:         String,
    owner_steam_hex: String,
    net_id:          u32,
    ttl_seconds:     u64,
) -> Result<(), String> {
    // Idempotent for permanent registrations: if the label already exists as a
    // permanent row, return Ok without allocating a new slot. This makes
    // RegisterOpcode safe to call on every relay restart.
    if let Some(existing) = ctx.db.dynamic_opcode().iter().find(|o| o.context == context) {
        if existing.expires_at_micros == u64::MAX {
            log::info!("[opcode] '{}' already registered at 0x{:04X} — idempotent skip", context, existing.opcode);
            return Ok(());
        }
        return Err(format!("OPCODE_CONTEXT_CONFLICT|context '{}' already active", context));
    }

    let mut alloc = ctx.db.opcode_allocator().id().find(0)
        .ok_or("ALLOCATOR_NOT_SEEDED")?;

    // Defensive: ensure cursor never falls into the reserved core range
    if alloc.next_candidate < ALLOCATOR_START {
        alloc.next_candidate = ALLOCATOR_START;
    }

    let scan_start = alloc.next_candidate;
    let mut candidate = scan_start;

    let opcode = loop {
        if ctx.db.dynamic_opcode().opcode().find(candidate).is_none() {
            alloc.next_candidate = if candidate >= DOMAIN_MAX {
                ALLOCATOR_START   // wrap back to start of dynamic pool, not 0
            } else {
                candidate + 1
            };
            break candidate;
        }
        candidate = if candidate >= DOMAIN_MAX { ALLOCATOR_START } else { candidate + 1 };
        if candidate == scan_start {
            return Err("OPCODE_POOL_EXHAUSTED|all dynamic slots are active".to_string());
        }
    };

    let now_micros = ctx.timestamp.to_micros_since_unix_epoch() as u64;
    let expires_at = if ttl_seconds == 0 {
        u64::MAX  // permanent — Reaper skips this row
    } else {
        now_micros.saturating_add(ttl_seconds * 1_000_000)
    };

    ctx.db.dynamic_opcode().insert(DynamicOpcode {
        opcode,
        context,
        owner_steam_hex,
        net_id,
        allocated_at:      ctx.timestamp,
        expires_at_micros: expires_at,
        is_consumed:       false,
    });

    ctx.db.opcode_allocator().id().update(alloc);

    log::info!(
        "[opcode] Allocated 0x{:04X} ttl={}s permanent={}",
        opcode, ttl_seconds, ttl_seconds == 0
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC OPCODE — CONSUME
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn consume_opcode(ctx: &ReducerContext, opcode: u16) -> Result<(), String> {
    let mut entry = ctx.db.dynamic_opcode().opcode().find(opcode)
        .ok_or("OPCODE_NOT_FOUND")?;

    if entry.is_consumed {
        return Err("OPCODE_ALREADY_CONSUMED".to_string());
    }
    if entry.expires_at_micros == u64::MAX {
        return Err("OPCODE_PERMANENT|registered opcodes cannot be consumed".to_string());
    }

    let now_micros = ctx.timestamp.to_micros_since_unix_epoch() as u64;
    if entry.expires_at_micros <= now_micros {
        ctx.db.dynamic_opcode().opcode().delete(opcode);
        return Err("OPCODE_EXPIRED".to_string());
    }

    entry.is_consumed = true;
    ctx.db.dynamic_opcode().opcode().update(entry);
    log::info!("[opcode] Consumed 0x{:04X}", opcode);
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC OPCODE — RELEASE / DEREGISTER
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn release_opcode(ctx: &ReducerContext, opcode: u16) {
    if let Some(entry) = ctx.db.dynamic_opcode().opcode().find(opcode) {
        if entry.expires_at_micros == u64::MAX {
            log::warn!("[opcode] release_opcode: 0x{:04X} is permanent — use deregister_opcode", opcode);
            return;
        }
    }
    if ctx.db.dynamic_opcode().opcode().find(opcode).is_some() {
        ctx.db.dynamic_opcode().opcode().delete(opcode);
        log::info!("[opcode] Released 0x{:04X}", opcode);
    }
}

#[spacetimedb::reducer]
pub fn deregister_opcode(ctx: &ReducerContext, label: String) {
    if let Some(entry) = ctx.db.dynamic_opcode().iter().find(|o| o.context == label) {
        let opcode = entry.opcode;
        ctx.db.dynamic_opcode().opcode().delete(opcode);
        log::info!("[opcode] Deregistered '{}' 0x{:04X}", label, opcode);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// REAPER SWEEP (12-hour scheduled)
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn opcode_reaper_sweep(ctx: &ReducerContext, _schedule: ReaperSchedule) {
    let now_micros = ctx.timestamp.to_micros_since_unix_epoch() as u64;

    let expired: Vec<DynamicOpcode> = ctx.db.dynamic_opcode().iter()
        .filter(|o| {
            if o.expires_at_micros == u64::MAX { return false; } // skip permanent
            o.expires_at_micros <= now_micros || o.is_consumed
        })
        .collect();

    let count = expired.len();
    for entry in expired {
        let reason = if entry.is_consumed { "consumed" } else { "ttl_expired" };
        log::warn!(
            "[reaper] Recycling 0x{:04X} ctx='{}' reason={} owner={}",
            entry.opcode, entry.context, reason, entry.owner_steam_hex
        );
        ctx.db.dynamic_opcode().opcode().delete(entry.opcode);
    }

    log::info!("[reaper] Sweep complete — recycled {} opcode(s)", count);
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn mark_instruction_consumed(ctx: &ReducerContext, id: u64) {
    if let Some(mut row) = ctx.db.instruction_queue().id().find(id) {
        row.consumed = true;
        ctx.db.instruction_queue().id().update(row);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SESSION LIFECYCLE
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn session_open(
    ctx:          &ReducerContext,
    steam_hex:    String,
    display_name: String,
) -> Result<(), String> {
    if let Some(mut acct) = ctx.db.account().steam_hex().find(&steam_hex) {
        if acct.is_banned {
            return Err(format!("BANNED|{}", acct.ban_reason));
        }
        acct.display_name = display_name;
        acct.last_seen    = ctx.timestamp;
        ctx.db.account().steam_hex().update(acct);
    } else {
        ctx.db.account().insert(Account {
            steam_hex:      steam_hex.clone(),
            display_name,
            created_at:     ctx.timestamp,
            last_seen:      ctx.timestamp,
            is_banned:      false,
            ban_reason:     String::new(),
            max_characters: DEFAULT_MAX_CHARACTERS,
        });
        log::info!("[account] New account: {}", steam_hex);
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn select_character(
    ctx:          &ReducerContext,
    steam_hex:    String,
    character_id: u64,
    server_id:    u32,
    net_id:       u32,
) -> Result<(), String> {
    let character = ctx.db.character().id().find(character_id)
        .ok_or("CHAR_NOT_FOUND")?;
    if character.steam_hex != steam_hex {
        return Err("CHAR_OWNERSHIP|Character does not belong to this account".to_string());
    }
    if character.is_deleted {
        return Err("CHAR_DELETED|Character has been deleted".to_string());
    }
    if let Some(stale) = ctx.db.char_session().steam_hex().find(&steam_hex) {
        log::warn!(
            "[session] Clearing stale session for {} (char_id={}, server_id={})",
            steam_hex, stale.character_id, stale.server_id
        );
        ctx.db.char_session().steam_hex().delete(steam_hex.clone());
    }
    ctx.db.char_session().insert(CharSession {
        steam_hex:     steam_hex.clone(),
        character_id,
        server_id,
        net_id,
        connected_at:  ctx.timestamp,
        inventory_ack: false,
    });
    log::info!(
        "[session] {} selected char_id={} '{}' (slot {})",
        steam_hex, character_id, character.name, character.slot_index
    );
    Ok(())
}

#[spacetimedb::reducer]
pub fn session_inventory_ack(ctx: &ReducerContext, steam_hex: String) -> Result<(), String> {
    let mut session = ctx.db.char_session().steam_hex().find(&steam_hex)
        .ok_or_else(|| format!("No session for {}", steam_hex))?;
    if session.inventory_ack { return Ok(()); }
    let char_id  = session.character_id;
    let owner_id = char_owner_id(char_id);
    let has_items = ctx.db.inventory_slot().iter()
        .any(|s| s.owner_id == owner_id && s.owner_type == "player");
    if !has_items {
        let starters: Vec<StarterKitEntry> = ctx.db.starter_kit_entry().iter().collect();
        for (idx, entry) in starters.iter().enumerate() {
            if let Some(def) = ctx.db.item_definition().item_id().find(&entry.item_id) {
                let used: std::collections::HashSet<u32> = ctx.db.inventory_slot().iter()
                    .filter(|s| s.owner_id == owner_id)
                    .map(|s| s.slot_index)
                    .collect();
                let slot_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);
                let metadata   = build_starter_metadata(ctx, &def, idx as u32);
                ctx.db.inventory_slot().insert(InventorySlot {
                    id: 0,
                    owner_id:   owner_id.clone(),
                    owner_type: "player".to_string(),
                    item_id:    entry.item_id.clone(),
                    quantity:   entry.quantity,
                    metadata,   slot_index,
                });
            }
        }
        log::info!("[session] Starter kit distributed to char_id={}", char_id);
    }
    session.inventory_ack = true;
    ctx.db.char_session().steam_hex().update(session);
    Ok(())
}

#[spacetimedb::reducer]
pub fn session_close(
    ctx:       &ReducerContext,
    steam_hex: String,
    pos_x: f32, pos_y: f32, pos_z: f32, heading: f32,
    health: u32, hunger: u32, thirst: u32,
) -> Result<(), String> {
    if let Some(mut char) = ctx.db.character().iter().find(|c| c.steam_hex == steam_hex) {
        char.pos_x    = pos_x;  char.pos_y  = pos_y;  char.pos_z = pos_z;
        char.heading  = heading; char.health = health;
        char.hunger   = hunger;  char.thirst = thirst;
        char.updated_at = ctx.timestamp;
        ctx.db.character().id().update(char);
    }
    let session = ctx.db.char_session().steam_hex().find(&steam_hex);
    if let Some(s) = &session {
        if ctx.db.disconnect_log().steam_hex().find(&steam_hex).is_some() {
            ctx.db.disconnect_log().steam_hex().delete(steam_hex.clone());
        }
        ctx.db.disconnect_log().insert(DisconnectLog {
            steam_hex:      steam_hex.clone(),
            character_id:   s.character_id,
            last_server_id: s.server_id,
            last_pos_x:     pos_x, last_pos_y: pos_y, last_pos_z: pos_z,
            last_health:    health,
            clean:          true,
            logged_at:      ctx.timestamp,
        });
    }
    ctx.db.char_session().steam_hex().delete(steam_hex.clone());
    log::info!("[session] {} closed cleanly", steam_hex);
    Ok(())
}

#[spacetimedb::reducer]
pub fn checkpoint_vitals(
    ctx:       &ReducerContext,
    steam_hex: String,
    pos_x: f32, pos_y: f32, pos_z: f32, heading: f32,
    health: u32, hunger: u32, thirst: u32,
) {
    if let Some(mut char) = ctx.db.character().iter().find(|c| c.steam_hex == steam_hex) {
        char.pos_x   = pos_x;  char.pos_y  = pos_y;  char.pos_z = pos_z;
        char.heading = heading; char.health = health;
        char.hunger  = hunger;  char.thirst = thirst;
        char.updated_at = ctx.timestamp;
        ctx.db.character().id().update(char);
    }
}

#[spacetimedb::reducer]
pub fn reaper_sweep(ctx: &ReducerContext, stale_threshold_seconds: u64) {
    let now_micros       = ctx.timestamp.to_micros_since_unix_epoch() as u64;
    let threshold_micros = stale_threshold_seconds * 1_000_000;
    let stale: Vec<CharSession> = ctx.db.char_session().iter()
        .filter(|s| {
            let age = now_micros.saturating_sub(s.connected_at.to_micros_since_unix_epoch() as u64);
            age > threshold_micros
        })
        .collect();
    let mut swept = 0u32;
    for s in stale {
        log::warn!("[reaper] Sweeping stale session: {} (server_id={})", s.steam_hex, s.server_id);
        let char_opt = ctx.db.character().id().find(s.character_id);
        if ctx.db.disconnect_log().steam_hex().find(&s.steam_hex).is_some() {
            ctx.db.disconnect_log().steam_hex().delete(s.steam_hex.clone());
        }
        ctx.db.disconnect_log().insert(DisconnectLog {
            steam_hex:      s.steam_hex.clone(),
            character_id:   s.character_id,
            last_server_id: s.server_id,
            last_pos_x:     char_opt.as_ref().map(|c| c.pos_x).unwrap_or(0.0),
            last_pos_y:     char_opt.as_ref().map(|c| c.pos_y).unwrap_or(0.0),
            last_pos_z:     char_opt.as_ref().map(|c| c.pos_z).unwrap_or(0.0),
            last_health:    char_opt.as_ref().map(|c| c.health).unwrap_or(200),
            clean:          false,
            logged_at:      ctx.timestamp,
        });
        ctx.db.char_session().steam_hex().delete(s.steam_hex);
        swept += 1;
    }
    log::info!("[reaper] Session sweep complete — cleared {}", swept);
}

// ─────────────────────────────────────────────────────────────────────────────
// CHARACTER MANAGEMENT
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn create_character(
    ctx:        &ReducerContext,
    steam_hex:  String,
    slot_index: u32,
    name:       String,
    gender:     String,
) -> Result<(), String> {
    let name = name.trim().to_string();
    if name.is_empty() || name.len() > 32 {
        return Err("NAME_INVALID|Character name must be 1-32 characters".to_string());
    }
    let account = ctx.db.account().steam_hex().find(&steam_hex)
        .ok_or("ACCOUNT_NOT_FOUND")?;
    if account.is_banned {
        return Err(format!("BANNED|{}", account.ban_reason));
    }
    let existing_chars: Vec<Character> = ctx.db.character().iter()
        .filter(|c| c.steam_hex == steam_hex && !c.is_deleted)
        .collect();
    let max_chars = account.max_characters.max(DEFAULT_MAX_CHARACTERS);
    if existing_chars.len() as u32 >= max_chars {
        return Err(format!("SLOT_LIMIT|Max {} characters per account", max_chars));
    }
    if existing_chars.iter().any(|c| c.slot_index == slot_index) {
        return Err(format!("SLOT_OCCUPIED|Slot {} is already in use", slot_index));
    }
    let new_char = ctx.db.character().insert(Character {
        id:         0,
        steam_hex:  steam_hex.clone(),
        slot_index,
        name:       name.clone(),
        gender,
        pos_x:      DEFAULT_SPAWN_X,
        pos_y:      DEFAULT_SPAWN_Y,
        pos_z:      DEFAULT_SPAWN_Z,
        heading:    DEFAULT_HEADING,
        health:     200,
        hunger:     100,
        thirst:     100,
        money_cash: 500,
        money_bank: 0,
        job:        "unemployed".to_string(),
        job_grade:  0,
        is_deleted: false,
        created_at: ctx.timestamp,
        updated_at: ctx.timestamp,
    });
    ctx.db.character_appearance().insert(CharacterAppearance {
        character_id:    new_char.id,
        components_json: "{}".to_string(),
        overlays_json:   "{}".to_string(),
        updated_at:      ctx.timestamp,
    });
    log::info!(
        "[character] Created '{}' id={} slot={} for {}",
        name, new_char.id, slot_index, steam_hex
    );
    Ok(())
}

#[spacetimedb::reducer]
pub fn delete_character(
    ctx:          &ReducerContext,
    steam_hex:    String,
    character_id: u64,
) -> Result<(), String> {
    let mut character = ctx.db.character().id().find(character_id)
        .ok_or("CHAR_NOT_FOUND")?;
    if character.steam_hex != steam_hex { return Err("CHAR_OWNERSHIP".to_string()); }
    if character.is_deleted             { return Err("CHAR_ALREADY_DELETED".to_string()); }
    if ctx.db.char_session().iter().any(|s| s.character_id == character_id) {
        return Err("CHAR_ACTIVE|Cannot delete a character that is currently online".to_string());
    }
    character.is_deleted = true;
    character.updated_at = ctx.timestamp;
    ctx.db.character().id().update(character.clone());
    log::info!("[character] Soft-deleted char_id={} '{}' for {}", character_id, character.name, steam_hex);
    Ok(())
}

#[spacetimedb::reducer]
pub fn save_appearance(
    ctx:             &ReducerContext,
    steam_hex:       String,
    character_id:    u64,
    components_json: String,
    overlays_json:   String,
) -> Result<(), String> {
    let character = ctx.db.character().id().find(character_id)
        .ok_or("CHAR_NOT_FOUND")?;
    if character.steam_hex != steam_hex { return Err("CHAR_OWNERSHIP".to_string()); }
    if let Some(mut app) = ctx.db.character_appearance().character_id().find(character_id) {
        app.components_json = components_json;
        app.overlays_json   = overlays_json;
        app.updated_at      = ctx.timestamp;
        ctx.db.character_appearance().character_id().update(app);
    } else {
        ctx.db.character_appearance().insert(CharacterAppearance {
            character_id, components_json, overlays_json, updated_at: ctx.timestamp,
        });
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn set_account_max_characters(ctx: &ReducerContext, steam_hex: String, max: u32) {
    if let Some(mut acct) = ctx.db.account().steam_hex().find(&steam_hex) {
        acct.max_characters = max;
        ctx.db.account().steam_hex().update(acct);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPAWN
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn request_spawn(
    ctx:       &ReducerContext,
    steam_hex: String,
    spawn_x:   f32, spawn_y: f32, spawn_z: f32,
    _heading:  f32,
) {
    let session = match ctx.db.char_session().steam_hex().find(&steam_hex) {
        Some(s) => s,
        None => { log::warn!("[spawn] no session for {}", steam_hex); return; }
    };
    if spawn_x < -8000.0 || spawn_x > 8000.0 || spawn_y < -8000.0 || spawn_y > 8000.0 {
        log::warn!("[spawn] coords out of bounds"); return;
    }

    let Some(set_coords_op) = registered_opcode(ctx, labels::entity::SET_COORDS) else {
        log::warn!("[spawn] '{}' not registered", labels::entity::SET_COORDS); return;
    };
    let Some(set_frozen_op) = registered_opcode(ctx, labels::entity::SET_FROZEN) else {
        log::warn!("[spawn] '{}' not registered", labels::entity::SET_FROZEN); return;
    };

    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0, target_entity_net_id: session.net_id,
        opcode:    set_coords_op,
        payload:   json!([spawn_x, spawn_y, spawn_z, false, false, true]).to_string(),
        queued_at: ctx.timestamp, consumed: false,
    });
    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0, target_entity_net_id: session.net_id,
        opcode:    set_frozen_op,
        payload:   json!([false]).to_string(),
        queued_at: ctx.timestamp, consumed: false,
    });
    log::info!("[spawn] Queued for {} at ({},{},{})", steam_hex, spawn_x, spawn_y, spawn_z);
}

// ─────────────────────────────────────────────────────────────────────────────
// INVENTORY — ITEM MANAGEMENT
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn seed_item(
    ctx: &ReducerContext,
    item_id: String, label: String, weight: f32,
    stackable: bool, usable: bool, max_stack: u32,
    category: String, prop_model: String,
    mag_capacity: i32, stored_capacity: i32, ammo_type: String,
) {
    if ctx.db.item_definition().item_id().find(&item_id).is_some() { return; }
    ctx.db.item_definition().insert(ItemDefinition {
        item_id, label, weight, stackable, usable, max_stack,
        category, prop_model, mag_capacity, stored_capacity, ammo_type,
    });
}

#[spacetimedb::reducer]
pub fn update_item(
    ctx: &ReducerContext,
    item_id: String, label: String, weight: f32,
    stackable: bool, usable: bool, max_stack: u32,
    category: String, prop_model: String,
    mag_capacity: i32, stored_capacity: i32, ammo_type: String,
) {
    if let Some(mut item) = ctx.db.item_definition().item_id().find(&item_id) {
        item.label           = label;
        item.weight          = weight;
        item.stackable       = stackable;
        item.usable          = usable;
        item.max_stack       = max_stack;
        item.category        = category;
        item.prop_model      = prop_model;
        item.mag_capacity    = mag_capacity;
        item.stored_capacity = stored_capacity;
        item.ammo_type       = ammo_type;
        ctx.db.item_definition().item_id().update(item);
    } else {
        ctx.db.item_definition().insert(ItemDefinition {
            item_id, label, weight, stackable, usable,
            max_stack, category, prop_model,
            mag_capacity, stored_capacity, ammo_type,
        });
    }
}

#[spacetimedb::reducer]
pub fn add_item(
    ctx:        &ReducerContext,
    owner_id:   String,
    owner_type: String,
    item_id:    String,
    quantity:   u32,
    metadata:   String,
) {
    let def = match ctx.db.item_definition().item_id().find(&item_id) {
        Some(d) => d,
        None => { log::warn!("[inventory] add_item: unknown item {}", item_id); return; }
    };
    if def.stackable {
        if let Some(mut slot) = ctx.db.inventory_slot().iter()
            .find(|s| s.owner_id == owner_id && s.item_id == item_id)
        {
            slot.quantity = (slot.quantity + quantity).min(def.max_stack);
            ctx.db.inventory_slot().id().update(slot);
            return;
        }
    }
    let used: Vec<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_id).map(|s| s.slot_index).collect();
    let slot_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);
    ctx.db.inventory_slot().insert(InventorySlot {
        id: 0, owner_id, owner_type, item_id, quantity, metadata, slot_index,
    });
}

#[spacetimedb::reducer]
pub fn remove_item(ctx: &ReducerContext, owner_id: String, item_id: String, quantity: u32) {
    let slot = match ctx.db.inventory_slot().iter()
        .find(|s| s.owner_id == owner_id && s.item_id == item_id)
    {
        Some(s) => s,
        None => { log::warn!("[inventory] remove_item: {} not found for {}", item_id, owner_id); return; }
    };
    if slot.quantity < quantity { log::warn!("[inventory] remove_item: not enough {}", item_id); return; }
    if slot.quantity == quantity {
        ctx.db.inventory_slot().id().delete(slot.id);
    } else {
        let mut s = slot; s.quantity -= quantity;
        ctx.db.inventory_slot().id().update(s);
    }
}

#[spacetimedb::reducer]
pub fn give_item_to_character(
    ctx:          &ReducerContext,
    character_id: u64,
    item_id:      String,
    quantity:     u32,
    metadata:     String,
) -> Result<(), String> {
    let owner_id = char_owner_id(character_id);
    let def = ctx.db.item_definition().item_id().find(&item_id)
        .ok_or_else(|| format!("Unknown item: {}", item_id))?;
    let resolved_metadata = if (metadata == "{}" || metadata.is_empty()) && def.category == "weapon" {
        let serial = format!("WPN-{:08X}", ctx.timestamp.to_micros_since_unix_epoch() as u32);
        format!(
            r#"{{"serial":"{}","mag_ammo":0,"stored_ammo":0,"mag_capacity":{},"stored_capacity":{},"durability":100,"ammo_type":"{}"}}"#,
            serial, def.mag_capacity, def.stored_capacity, def.ammo_type
        )
    } else {
        metadata
    };
    let current_weight: f32 = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_id && s.owner_type == "player")
        .map(|s| ctx.db.item_definition().item_id().find(&s.item_id)
            .map(|d| d.weight * s.quantity as f32).unwrap_or(0.0))
        .sum();
    let max_weight: f32 = ctx.db.player_config()
        .steam_hex().find(&owner_id)
        .map(|c| c.max_carry_weight)
        .unwrap_or(85.0);
    let incoming = def.weight * quantity as f32;
    if current_weight + incoming > max_weight {
        return Err(format!("WEIGHT_LIMIT|{:.2}|{:.2}", current_weight + incoming, max_weight));
    }
    if def.stackable {
        if let Some(mut existing) = ctx.db.inventory_slot().iter()
            .find(|s| s.owner_id == owner_id && s.item_id == item_id)
        {
            existing.quantity = (existing.quantity + quantity).min(def.max_stack);
            ctx.db.inventory_slot().id().update(existing);
            return Ok(());
        }
    }
    let used: std::collections::HashSet<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_id && s.owner_type == "player")
        .map(|s| s.slot_index)
        .collect();
    let slot_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);
    ctx.db.inventory_slot().insert(InventorySlot {
        id: 0,
        owner_id,
        owner_type: "player".to_string(),
        item_id,
        quantity,
        metadata: resolved_metadata,
        slot_index,
    });
    Ok(())
}

#[spacetimedb::reducer]
pub fn give_item_to_identity(
    ctx:                &ReducerContext,
    owner_identity_hex: String,
    item_id:            String,
    quantity:           u32,
    metadata:           String,
) -> Result<(), String> {
    let session = ctx.db.char_session().steam_hex().find(&owner_identity_hex)
        .ok_or_else(|| format!("No active session for {}", owner_identity_hex))?;
    give_item_to_character(ctx, session.character_id, item_id, quantity, metadata)
}

#[spacetimedb::reducer]
pub fn move_item(ctx: &ReducerContext, slot_id: u64, new_slot_index: u32) {
    let owner_id = ctx.sender().to_hex().to_string();
    let mut slot = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => { log::warn!("[inventory] move_item: slot {} not found", slot_id); return; }
    };
    if slot.owner_id != owner_id { log::warn!("[inventory] move_item: ownership mismatch"); return; }
    slot.slot_index = new_slot_index;
    ctx.db.inventory_slot().id().update(slot);
}

#[spacetimedb::reducer]
pub fn transfer_item(
    ctx: &ReducerContext,
    slot_id: u64,
    new_owner_id: String,
    new_owner_type: String,
    new_slot_index: u32,
) -> Result<(), String> {
    let slot = ctx.db.inventory_slot().id().find(slot_id)
        .ok_or_else(|| format!("Slot {} not found", slot_id))?;
    ctx.db.inventory_slot().id().update(InventorySlot {
        owner_id:   new_owner_id,
        owner_type: new_owner_type,
        slot_index: new_slot_index,
        ..slot
    });
    Ok(())
}

#[spacetimedb::reducer]
pub fn merge_stacks(ctx: &ReducerContext, src_slot_id: u64, dst_slot_id: u64) -> Result<(), String> {
    let src = ctx.db.inventory_slot().id().find(src_slot_id)
        .ok_or_else(|| format!("src slot {} not found", src_slot_id))?;
    let dst = ctx.db.inventory_slot().id().find(dst_slot_id)
        .ok_or_else(|| format!("dst slot {} not found", dst_slot_id))?;
    if src.item_id != dst.item_id { return Err("Cannot merge different items".to_string()); }
    let def = ctx.db.item_definition().item_id().find(&src.item_id)
        .ok_or_else(|| format!("item def {} not found", src.item_id))?;
    let total = src.quantity + dst.quantity;
    if total <= def.max_stack {
        ctx.db.inventory_slot().id().update(InventorySlot { quantity: total, ..dst });
        ctx.db.inventory_slot().id().delete(src_slot_id);
    } else {
        let overflow = total - def.max_stack;
        ctx.db.inventory_slot().id().update(InventorySlot { quantity: def.max_stack, ..dst });
        ctx.db.inventory_slot().id().update(InventorySlot { quantity: overflow, ..src });
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn split_stack(ctx: &ReducerContext, slot_id: u64, amount: u32) -> Result<(), String> {
    let mut slot = ctx.db.inventory_slot().id().find(slot_id)
        .ok_or_else(|| format!("Slot {} not found", slot_id))?;
    if amount == 0 || amount >= slot.quantity {
        return Err(format!("Invalid split amount {}", amount));
    }
    let used: Vec<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == slot.owner_id)
        .map(|s| s.slot_index).collect();
    let new_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);
    slot.quantity -= amount;
    ctx.db.inventory_slot().id().update(slot.clone());
    ctx.db.inventory_slot().insert(InventorySlot {
        id: 0,
        owner_id:   slot.owner_id,
        owner_type: slot.owner_type,
        item_id:    slot.item_id,
        quantity:   amount,
        metadata:   slot.metadata,
        slot_index: new_index,
    });
    Ok(())
}

#[spacetimedb::reducer]
pub fn use_item(ctx: &ReducerContext, slot_id: u64, net_id: u32) {
    let owner_id = ctx.sender().to_hex().to_string();
    let slot = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => { log::warn!("[inventory] use_item: slot {} not found", slot_id); return; }
    };
    if slot.owner_id != owner_id { log::warn!("[inventory] use_item: ownership mismatch"); return; }
    let def = match ctx.db.item_definition().item_id().find(&slot.item_id) {
        Some(d) => d, None => return,
    };
    if !def.usable { log::warn!("[inventory] use_item: {} not usable", slot.item_id); return; }

    let consume = |ctx: &ReducerContext, slot_id: u64| {
        if let Some(mut s) = ctx.db.inventory_slot().id().find(slot_id) {
            if s.quantity <= 1 { ctx.db.inventory_slot().id().delete(slot_id); }
            else { s.quantity -= 1; ctx.db.inventory_slot().id().update(s); }
        }
    };

    match slot.item_id.as_str() {
        "bandage" => {
            let Some(op) = registered_opcode(ctx, labels::effect::HEAL) else {
                log::warn!("[use_item] '{}' not registered", labels::effect::HEAL); return;
            };
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: op, payload: json!([40]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "medkit" => {
            let Some(op) = registered_opcode(ctx, labels::effect::HEAL) else {
                log::warn!("[use_item] '{}' not registered", labels::effect::HEAL); return;
            };
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: op, payload: json!([100]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "food_burger" => {
            let Some(op) = registered_opcode(ctx, labels::effect::HUNGER) else {
                log::warn!("[use_item] '{}' not registered", labels::effect::HUNGER); return;
            };
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: op, payload: json!([30]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "water_bottle" => {
            let Some(op) = registered_opcode(ctx, labels::effect::THIRST) else {
                log::warn!("[use_item] '{}' not registered", labels::effect::THIRST); return;
            };
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: op, payload: json!([30]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        _ => { log::info!("[inventory] use_item: no handler for {}", slot.item_id); }
    }
}

#[spacetimedb::reducer]
pub fn set_player_max_weight(ctx: &ReducerContext, owner_id: String, max_kg: f32) {
    if let Some(mut cfg) = ctx.db.player_config().steam_hex().find(&owner_id) {
        cfg.max_carry_weight = max_kg;
        ctx.db.player_config().steam_hex().update(cfg);
    } else {
        ctx.db.player_config().insert(PlayerConfig { steam_hex: owner_id, max_carry_weight: max_kg });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VEHICLE INVENTORIES
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn create_vehicle_inventory(
    ctx:              &ReducerContext,
    plate:            String,
    model_hash:       u32,
    trunk_type:       String,
    trunk_slots:      u32,
    trunk_max_weight: f32,
) {
    if ctx.db.vehicle_inventory().plate().find(&plate).is_some() { return; }
    ctx.db.vehicle_inventory().insert(VehicleInventory {
        plate, model_hash, trunk_type, trunk_slots,
        trunk_max_weight, glovebox_max_weight: 10.0,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// STASHES
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn create_stash(
    ctx:        &ReducerContext,
    stash_id:   String,
    stash_type: String,
    label:      String,
    max_slots:  u32,
    max_weight: f32,
    owner_id:   String,
    pos_x:      f32, pos_y: f32, pos_z: f32,
) {
    if ctx.db.stash_definition().stash_id().find(&stash_id).is_some() { return; }
    ctx.db.stash_definition().insert(StashDefinition {
        stash_id, stash_type, label, max_slots, max_weight, owner_id, pos_x, pos_y, pos_z,
    });
}

#[spacetimedb::reducer]
pub fn delete_stash(ctx: &ReducerContext, stash_id: String) {
    let caller = ctx.sender().to_hex().to_string();
    let stash  = match ctx.db.stash_definition().stash_id().find(&stash_id) {
        Some(s) => s,
        None => { log::warn!("[stash] delete_stash: {} not found", stash_id); return; }
    };
    if !stash.owner_id.is_empty() && stash.owner_id != caller {
        log::warn!("[stash] delete_stash: {} not authorised", caller); return;
    }
    let slot_ids: Vec<u64> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == stash_id && s.owner_type == "stash")
        .map(|s| s.id).collect();
    for id in slot_ids { ctx.db.inventory_slot().id().delete(id); }
    ctx.db.stash_definition().stash_id().delete(stash_id);
}

// ─────────────────────────────────────────────────────────────────────────────
// STARTER KIT
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn seed_starter_kit(ctx: &ReducerContext, item_id: String, quantity: u32) {
    if ctx.db.starter_kit_entry().iter().any(|e| e.item_id == item_id) { return; }
    ctx.db.starter_kit_entry().insert(StarterKitEntry { id: 0, item_id, quantity });
}

// ─────────────────────────────────────────────────────────────────────────────
// DROP ITEM TO GROUND
// ─────────────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn drop_item_to_ground(
    ctx:      &ReducerContext,
    slot_id:  u64,
    quantity: u32,
    x: f32, y: f32, z: f32,
) -> Result<(), String> {
    let slot = ctx.db.inventory_slot().id().find(slot_id)
        .ok_or_else(|| format!("Slot {} not found", slot_id))?;
    let search_radius_sq: f32 = 25.0;
    let nearby_stash = ctx.db.stash_definition().iter()
        .filter(|s| s.stash_type == "ground")
        .filter(|s| { let dx = s.pos_x - x; let dy = s.pos_y - y; dx*dx + dy*dy <= search_radius_sq })
        .min_by(|a, b| {
            let da = (a.pos_x-x).powi(2) + (a.pos_y-y).powi(2);
            let db = (b.pos_x-x).powi(2) + (b.pos_y-y).powi(2);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        });
    let stash_id = match nearby_stash {
        Some(existing) => existing.stash_id,
        None => {
            let new_id = format!("ground_{}", ctx.timestamp.to_micros_since_unix_epoch());
            ctx.db.stash_definition().insert(StashDefinition {
                stash_id: new_id.clone(), stash_type: "ground".to_string(),
                label: "GROUND".to_string(), max_slots: 50, max_weight: 999.0,
                owner_id: String::new(), pos_x: x, pos_y: y, pos_z: z,
            });
            new_id
        }
    };
    let actual_qty = if quantity > 0 && quantity < slot.quantity { quantity } else { slot.quantity };
    let used_indices: std::collections::HashSet<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == stash_id).map(|s| s.slot_index).collect();
    let new_slot_index = (0u32..).find(|i| !used_indices.contains(i)).unwrap_or(0);
    let logged_item_id = slot.item_id.clone();
    if actual_qty == slot.quantity {
        ctx.db.inventory_slot().id().update(InventorySlot {
            owner_id:   stash_id.clone(),
            owner_type: "stash".to_string(),
            slot_index: new_slot_index,
            ..slot
        });
    } else {
        let mut remaining = slot.clone();
        remaining.quantity -= actual_qty;
        ctx.db.inventory_slot().id().update(remaining);
        ctx.db.inventory_slot().insert(InventorySlot {
            id: 0, owner_id: stash_id.clone(), owner_type: "stash".to_string(),
            item_id: slot.item_id, quantity: actual_qty,
            metadata: slot.metadata, slot_index: new_slot_index,
        });
    }
    log::info!("[stash] Dropped {}x {} to {} at ({:.1},{:.1})", actual_qty, logged_item_id, stash_id, x, y);
    Ok(())
}

#[spacetimedb::reducer]
pub fn find_or_create_ground_stash(ctx: &ReducerContext, x: f32, y: f32, z: f32) -> Result<(), String> {
    let search_radius_sq: f32 = 25.0;
    let nearby = ctx.db.stash_definition().iter()
        .filter(|s| s.stash_type == "ground")
        .filter(|s| { let dx = s.pos_x - x; let dy = s.pos_y - y; dx*dx + dy*dy <= search_radius_sq })
        .min_by(|a, b| {
            let da = (a.pos_x-x).powi(2) + (a.pos_y-y).powi(2);
            let db = (b.pos_x-x).powi(2) + (b.pos_y-y).powi(2);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        });
    if nearby.is_none() {
        let new_id = format!("ground_{}", ctx.timestamp.to_micros_since_unix_epoch());
        ctx.db.stash_definition().insert(StashDefinition {
            stash_id: new_id.clone(), stash_type: "ground".to_string(),
            label: "GROUND".to_string(), max_slots: 50, max_weight: 999.0,
            owner_id: String::new(), pos_x: x, pos_y: y, pos_z: z,
        });
        log::info!("[stash] Created ground stash {} at ({:.1},{:.1})", new_id, x, y);
    }
    Ok(())
}