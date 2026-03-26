use spacetimedb::{ReducerContext, Table};
use crate::tables::*;
use serde_json::json;
use stdb_core::opcodes;

// ── CORE ──────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn mark_instruction_consumed(ctx: &ReducerContext, id: u64) {
    if let Some(mut row) = ctx.db.instruction_queue().id().find(id) {
        row.consumed = true;
        ctx.db.instruction_queue().id().update(row);
    }
}

// ── PLAYER ────────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn on_player_connect(
    ctx:          &ReducerContext,
    steam_hex:    String,
    display_name: String,
    server_id:    u32,
    net_id:       u32,
    _heading: f32,
) {
    let identity = ctx.sender();

    if let Some(mut p) = ctx.db.player().identity().find(identity) {
        p.last_seen    = ctx.timestamp;
        p.display_name = display_name;
        ctx.db.player().identity().update(p);
    } else {
        ctx.db.player().insert(Player {
            identity,
            steam_hex,
            display_name,
            money_cash: 5000,
            money_bank: 0,
            job:        "unemployed".to_string(),
            created_at: ctx.timestamp,
            last_seen:  ctx.timestamp,
        });

        // Give starter items to new players
        let owner_id = identity.to_hex().to_string();
        let starters: &[(&str, u32, &str)] = &[
            ("phone",         1,   "{}"),
            ("id_card",       1,   "{}"),
            ("water_bottle",  2,   "{}"),
            ("food_burger",   1,   "{}"),
            ("bandage",       5,   "{}"),
            ("cash",          500, "{}"),
            ("backpack",      1,   "{}"),
            ("weapon_pistol", 1,   "{}"),
            ("ammo_pistol",   50,  "{}"),
            ("parachute",     1,   "{}"),
            ("body_armour",   1,   "{}"),
        ];
        for (item_id, quantity, metadata) in starters {
            if ctx.db.item_definition().item_id().find(&item_id.to_string()).is_some() {
                let used: Vec<u32> = ctx.db.inventory_slot().iter()
                    .filter(|s| s.owner_id == owner_id)
                    .map(|s| s.slot_index)
                    .collect();
                let slot_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);
                ctx.db.inventory_slot().insert(InventorySlot {
                    id: 0,
                    owner_id:   owner_id.clone(),
                    owner_type: "player".to_string(),
                    item_id:    item_id.to_string(),
                    quantity:   *quantity,
                    metadata:   metadata.to_string(),
                    slot_index,
                });
            }
        }
        log::info!("[player] New player {}, gave starter items", identity);
    }

    ctx.db.active_session().identity().delete(identity);
    ctx.db.active_session().insert(ActiveSession {
        identity,
        server_id,
        net_id,
        connected_at: ctx.timestamp,
    });

    log::info!("[player] {} connected (server_id={})", identity, server_id);
}

#[spacetimedb::reducer]
pub fn on_player_disconnect(ctx: &ReducerContext) {
    ctx.db.active_session().identity().delete(ctx.sender());
    log::info!("[player] {} session cleared", ctx.sender());
}

#[spacetimedb::reducer]
pub fn request_spawn(
    ctx:      &ReducerContext,
    spawn_x:  f32,
    spawn_y:  f32,
    spawn_z:  f32,
    _heading: f32,
) {
    let identity = ctx.sender();
    let session  = match ctx.db.active_session().identity().find(identity) {
        Some(s) => s,
        None => { log::warn!("[player] request_spawn: no session for {}", identity); return; }
    };

    if spawn_x < -8000.0 || spawn_x > 8000.0 || spawn_y < -8000.0 || spawn_y > 8000.0 {
        log::warn!("[player] request_spawn: coords out of bounds"); return;
    }

    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0, target_entity_net_id: session.net_id,
        opcode: opcodes::entity::SET_COORDS,
        payload: json!([x, y, z, false, false, true]).to_string(),
        queued_at: ctx.timestamp, consumed: false,
    });
    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0, target_entity_net_id: session.net_id,
        opcode: opcodes::entity::SET_FROZEN,
        payload: json!([false]).to_string(),
        queued_at: ctx.timestamp, consumed: false,
    });

    log::info!("[player] Spawn queued for {} at ({},{},{})", identity, spawn_x, spawn_y, spawn_z);
}

// ── INVENTORY ─────────────────────────────────────────────────────────────────

/// Seed an item definition. Idempotent — skips if item_id already exists.
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

/// Add items to any inventory (player/vehicle/stash) by owner_id.
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

/// Remove items from any inventory by owner_id.
#[spacetimedb::reducer]
pub fn remove_item(ctx: &ReducerContext, owner_id: String, item_id: String, quantity: u32) {
    let slot = match ctx.db.inventory_slot().iter()
        .find(|s| s.owner_id == owner_id && s.item_id == item_id)
    {
        Some(s) => s,
        None => { log::warn!("[inventory] remove_item: {} not found for {}", item_id, owner_id); return; }
    };

    if slot.quantity < quantity {
        log::warn!("[inventory] remove_item: not enough {}", item_id); return;
    }
    if slot.quantity == quantity {
        ctx.db.inventory_slot().id().delete(slot.id);
    } else {
        let mut s = slot; s.quantity -= quantity;
        ctx.db.inventory_slot().id().update(s);
    }
}

/// Move a slot to a new index. Only the owning player can call this.
#[spacetimedb::reducer]
pub fn move_item(ctx: &ReducerContext, slot_id: u64, new_slot_index: u32) {
    let owner_id = ctx.sender().to_hex().to_string();
    let mut slot = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => { log::warn!("[inventory] move_item: slot {} not found", slot_id); return; }
    };
    if slot.owner_id != owner_id {
        log::warn!("[inventory] move_item: ownership mismatch"); return;
    }
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

/// Merge src stack into dst stack. Deletes src if it fully fits, otherwise leaves remainder.
#[spacetimedb::reducer]
pub fn merge_stacks(ctx: &ReducerContext, src_slot_id: u64, dst_slot_id: u64) -> Result<(), String> {
    let src = ctx.db.inventory_slot().id().find(src_slot_id)
        .ok_or_else(|| format!("src slot {} not found", src_slot_id))?;
    let dst = ctx.db.inventory_slot().id().find(dst_slot_id)
        .ok_or_else(|| format!("dst slot {} not found", dst_slot_id))?;
    if src.item_id != dst.item_id {
        return Err("Cannot merge different items".to_string());
    }
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

/// Split qty items from slot into a new slot at the next free index.
#[spacetimedb::reducer]
pub fn split_stack(ctx: &ReducerContext, slot_id: u64, amount: u32) -> Result<(), String> {
    let mut slot = ctx.db.inventory_slot().id().find(slot_id)
        .ok_or_else(|| format!("Slot {} not found", slot_id))?;
    if amount == 0 || amount >= slot.quantity {
        return Err(format!("Invalid split amount {}", amount));
    }
    let used: Vec<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == slot.owner_id)
        .map(|s| s.slot_index)
        .collect();
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

/// Use a consumable/usable item. Only the owning player can call this.
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
            // Restore 40 HP (GTA health 100-200, 200 = full)
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: opcodes::effect::HEAL,
                payload: json!([40]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "medkit" => {
            // Full heal
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: opcodes::effect::HEAL,
                payload: json!([100]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "food_burger" => {
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: opcodes::effect::HUNGER,
                payload: json!([30]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        "water_bottle" => {
            ctx.db.instruction_queue().insert(InstructionQueue {
                id: 0, target_entity_net_id: net_id,
                opcode: opcodes::effect::THIRST,
                payload: json!([30]).to_string(),
                queued_at: ctx.timestamp, consumed: false,
            });
            consume(ctx, slot_id);
        }
        _ => { log::info!("[inventory] use_item: no handler for {}", slot.item_id); }
    }
}

// ── VEHICLE INVENTORIES ───────────────────────────────────────────────────────

/// Register a vehicle's inventory config. Idempotent — skips if plate exists.
/// Called by the relay the first time a player accesses a vehicle's inventory.
#[spacetimedb::reducer]
pub fn create_vehicle_inventory(
    ctx:              &ReducerContext,
    plate:            String,
    model_hash:       u32,
    trunk_type:       String,  // "rear" | "front" | "none"
    trunk_slots:      u32,
    trunk_max_weight: f32,
) {
    if ctx.db.vehicle_inventory().plate().find(&plate).is_some() { return; }
    ctx.db.vehicle_inventory().insert(VehicleInventory {
        plate,
        model_hash,
        trunk_type,
        trunk_slots,
        trunk_max_weight,
        glovebox_max_weight: 10.0,
    });
}

// ── STASHES ───────────────────────────────────────────────────────────────────

/// Register a stash. Idempotent — skips if stash_id exists.
/// owner_id = "" for world/job stashes, identity hex for player-owned.
#[spacetimedb::reducer]
pub fn create_stash(
    ctx:        &ReducerContext,
    stash_id:   String,
    stash_type: String,
    label:      String,
    max_slots:  u32,
    max_weight: f32,
    owner_id:   String,
    pos_x:      f32,
    pos_y:      f32,
    pos_z:      f32,
) {
    if ctx.db.stash_definition().stash_id().find(&stash_id).is_some() { return; }
    ctx.db.stash_definition().insert(StashDefinition {
        stash_id, stash_type, label, max_slots, max_weight, owner_id, pos_x, pos_y, pos_z,
    });
}

/// Delete a player-created stash and all its items.
/// Only the stash owner can call this.
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
        .map(|s| s.id)
        .collect();
    for id in slot_ids { ctx.db.inventory_slot().id().delete(id); }
    ctx.db.stash_definition().stash_id().delete(stash_id);
}

#[spacetimedb::reducer]
pub fn give_item_to_identity(ctx: ReducerContext, identity: Identity, item_id: u32) {
    id: 0,
    target_entity_net_id: net_id,
    opcode:   opcodes::effect::HEAL,   // 0x2001
    payload:  json!([40]).to_string(), // compact array, no string keys
    queued_at: ctx.timestamp,
    consumed: false,
};
    ctx:                &ReducerContext,
    owner_identity_hex: String,   // canonical hex, no "0x" — resolved by sidecar
    item_id:            String,
    quantity:           u32,
    metadata:           String,   // "{}" triggers auto-generation for weapons
    -> Result<(), String> {

    // ── 1. Resolve item definition ────────────────────────────────────────────
    let def = ctx.db.item_definition().item_id().find(&item_id)
        .ok_or_else(|| format!("Unknown item: {}", item_id))?;

    // ── 2. Build weapon metadata if the caller passed "{}" ────────────────────
    // This was previously done with Guid.NewGuid() in C# — domain ID generation
    // belongs in the authoritative layer, not the bridge layer.
    let resolved_metadata = if (metadata == "{}" || metadata.is_empty()) && def.category == "weapon" {
        // Use the reducer timestamp as the unique serial source.
        // Microsecond precision makes collisions practically impossible.
        let serial = format!("WPN-{:08X}", ctx.timestamp.to_micros_since_unix_epoch() as u32);
        format!(
            r#"{{"serial":"{}","mag_ammo":0,"stored_ammo":0,"mag_capacity":{},"stored_capacity":{},"durability":100,"ammo_type":"{}"}}"#,
            serial, def.mag_capacity, def.stored_capacity, def.ammo_type
        )
    } else {
        metadata
    };

    // ── 3. Weight gate ────────────────────────────────────────────────────────
    let current_weight: f32 = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_identity_hex && s.owner_type == "player")
        .map(|s| {
            ctx.db.item_definition().item_id().find(&s.item_id)
                .map(|d| d.weight * s.quantity as f32)
                .unwrap_or(0.0)
        })
        .sum();

    let incoming_weight = def.weight * quantity as f32;
    if current_weight + incoming_weight > 85.0 {
        return Err(format!(
            "WEIGHT_LIMIT|{:.2}|85.00",
            current_weight + incoming_weight
        ));
    }

    // ── 4. Stackable merge ────────────────────────────────────────────────────
    if def.stackable {
        if let Some(mut existing) = ctx.db.inventory_slot().iter()
            .find(|s| s.owner_id == owner_identity_hex && s.item_id == item_id)
        {
            existing.quantity = (existing.quantity + quantity).min(def.max_stack);
            ctx.db.inventory_slot().id().update(existing);
            return Ok(());
        }
    }

    // ── 5. Authoritative next-free-slot finder ────────────────────────────────
    // This runs inside a SpacetimeDB transaction — concurrent calls are
    // serialised by the database, making slot collisions impossible.
    // The C# while-loop had no such guarantee.
    let used: std::collections::HashSet<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_identity_hex && s.owner_type == "player")
        .map(|s| s.slot_index)
        .collect();
    let slot_index = (0u32..).find(|i| !used.contains(i)).unwrap_or(0);

    ctx.db.inventory_slot().insert(InventorySlot {
        id: 0,
        owner_id:   owner_identity_hex,
        owner_type: "player".to_string(),
        item_id,
        quantity,
        metadata:   resolved_metadata,
        slot_index,
    });

    Ok(())
}

// ── DROP ITEM TO GROUND ───────────────────────────────────────────────────────
//
// Replaces the entire drop_item_to_ground case in Program.cs.
// Three algorithms that were in C# now live here:
//   (a) spatial proximity search (within 5m)
//   (b) ground stash creation with a deterministic ID
//   (c) next-free-slot finder for the ground stash
//
// After calling this reducer the sidecar queries for the stash near (x,y)
// to build the response — it never needs to know the stash_id in advance.

#[spacetimedb::reducer]
pub fn drop_item_to_ground(
    ctx:      &ReducerContext,
    slot_id:  u64,
    quantity: u32,
    x:        f32,
    y:        f32,
    z:        f32,
) -> Result<(), String> {

    // ── 1. Verify the slot exists ─────────────────────────────────────────────
    let slot = ctx.db.inventory_slot().id().find(slot_id)
        .ok_or_else(|| format!("Slot {} not found", slot_id))?;

    // ── 2. Spatial search — find an existing ground stash within 5m ──────────
    let search_radius_sq: f32 = 25.0; 
    let nearby_stash = ctx.db.stash_definition().iter()
        .filter(|s| s.stash_type == "ground")
        .filter(|s| {
            let dx = s.pos_x - x;
            let dy = s.pos_y - y;
            dx * dx + dy * dy <= search_radius_sq
        })
        .min_by(|a, b| {
            let da = (a.pos_x - x).powi(2) + (a.pos_y - y).powi(2);
            let db = (b.pos_x - x).powi(2) + (b.pos_y - y).powi(2);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        });

    // ── 3. Resolve or create the ground stash ────────────────────────────────
    let stash_id = match nearby_stash {
        Some(existing) => existing.stash_id,
        None => {
            // Fixed: Updated timestamp method name
            let new_id = format!("ground_{}", ctx.timestamp.to_micros_since_unix_epoch());
            ctx.db.stash_definition().insert(StashDefinition {
                stash_id:   new_id.clone(),
                stash_type: "ground".to_string(),
                label:      "GROUND".to_string(),
                max_slots:  50,
                max_weight: 999.0,
                owner_id:   String::new(),
                pos_x: x, pos_y: y, pos_z: z,
            });
            new_id
        }
    };

    // ── 4. Determine actual quantity to drop ──────────────────────────────────
    let actual_qty = if quantity > 0 && quantity < slot.quantity {
        quantity
    } else {
        slot.quantity
    };

    // ── 5. Find the next free slot index in the ground stash ─────────────────
    let used_indices: std::collections::HashSet<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == stash_id)
        .map(|s| s.slot_index)
        .collect();
    let new_slot_index = (0u32..).find(|i| !used_indices.contains(i)).unwrap_or(0);

    // Capture item_id for logging BEFORE it might get moved in step 6
    let logged_item_id = slot.item_id.clone();

    // ── 6. Transfer full stack or split partial ───────────────────────────────
    if actual_qty == slot.quantity {
        // Fixed: Use stash_id.clone() so stash_id is still available for logging
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
            id:         0,
            // Fixed: Use stash_id.clone() here as well
            owner_id:   stash_id.clone(),
            owner_type: "stash".to_string(),
            item_id:    slot.item_id,
            quantity:   actual_qty,
            metadata:   slot.metadata,
            slot_index: new_slot_index,
        });
    }

    // Now uses the cloned versions to avoid "borrow of moved value" errors
    log::info!(
        "[stash] Dropped {}x {} to ground stash {} at ({:.1},{:.1})",
        actual_qty, logged_item_id, stash_id, x, y
    );

    Ok(())
}

// ── FIND OR CREATE GROUND STASH ───────────────────────────────────────────────
//
// Replaces the find_or_create_ground_stash case in Program.cs.
// Used when the player opens their inventory — we need a ground stash to
// display as the secondary panel, even if it is empty.
//
// After calling this reducer the sidecar queries StashDefinition near (x,y)
// to get the stash_id, then queries InventorySlot for its contents.

#[spacetimedb::reducer]
pub fn find_or_create_ground_stash(
    ctx: &ReducerContext,
    x:   f32,
    y:   f32,
    z:   f32,
) -> Result<(), String> {

    let search_radius_sq: f32 = 25.0; // 5m radius

    // ── Spatial search — identical algorithm to drop_item_to_ground ───────────
    // Having one authoritative implementation means both paths always agree
    // on which stash "owns" a given position — previously the two C# copies
    // could disagree if one was called between the other's search and insert.
    let nearby = ctx.db.stash_definition().iter()
        .filter(|s| s.stash_type == "ground")
        .filter(|s| {
            let dx = s.pos_x - x;
            let dy = s.pos_y - y;
            dx * dx + dy * dy <= search_radius_sq
        })
        .min_by(|a, b| {
            let da = (a.pos_x - x).powi(2) + (a.pos_y - y).powi(2);
            let db = (b.pos_x - x).powi(2) + (b.pos_y - y).powi(2);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        });

    if nearby.is_none() {
        // No stash within 5m — create a fresh one
        // Updated method name below
        let new_id = format!("ground_{}", ctx.timestamp.to_micros_since_unix_epoch());
        ctx.db.stash_definition().insert(StashDefinition {
            stash_id:   new_id.clone(),
            stash_type: "ground".to_string(),
            label:      "GROUND".to_string(),
            max_slots:  50,
            max_weight: 999.0,
            owner_id:   String::new(),
            pos_x: x, pos_y: y, pos_z: z,
        });
        log::info!("[stash] Created ground stash {} at ({:.1},{:.1})", new_id, x, y);
    }
    // If a stash already exists nearby, this reducer is a no-op.
    // The sidecar will query to find it after the frame tick.

    Ok(())
}