use spacetimedb::{ReducerContext, Table};
use crate::tables::{ItemDefinition, InventorySlot};
use crate::tables::{item_definition, inventory_slot};
use stdb_core::InstructionQueue;
use stdb_core::instruction::instruction_queue;
use serde_json::json;
use stdb_core::opcodes;

// ── ADMIN: seed item definitions ─────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn seed_item(
    ctx: &ReducerContext,
    item_id:   String,
    label:     String,
    weight:    f32,
    stackable: bool,
    usable:    bool,
    max_stack: u32,
) {
    if ctx.db.item_definition().item_id().find(&item_id).is_some() {
        return; // already exists
    }
    ctx.db.item_definition().insert(ItemDefinition {
        item_id,
        label,
        weight,
        stackable,
        usable,
        max_stack,
    });
}

// ── ADD ITEM ──────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn add_item(
    ctx: &ReducerContext,
    owner_id:   String,
    owner_type: String,
    item_id:    String,
    quantity:   u32,
    metadata:   String,
) {
    let def = match ctx.db.item_definition().item_id().find(&item_id) {
        Some(d) => d,
        None => {
            log::warn!("[inventory] add_item: unknown item {}", item_id);
            return;
        }
    };

    if def.stackable {
        // Find existing stack
        let existing = ctx.db.inventory_slot().iter()
            .find(|s| s.owner_id == owner_id && s.item_id == item_id);

        if let Some(mut slot) = existing {
            let new_qty = (slot.quantity + quantity).min(def.max_stack);
            slot.quantity = new_qty;
            ctx.db.inventory_slot().id().update(slot);
            log::info!("[inventory] Stacked {}x {} for {}", quantity, item_id, owner_id);
            return;
        }
    }

    // Find next free slot index
    let used_slots: Vec<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_id)
        .map(|s| s.slot_index)
        .collect();
    let slot_index = (0u32..).find(|i| !used_slots.contains(i)).unwrap_or(0);

    ctx.db.inventory_slot().insert(InventorySlot {
        id: 0,
        owner_id:   owner_id.clone(),
        owner_type,
        item_id:    item_id.clone(),
        quantity,
        metadata,
        slot_index,
    });

    log::info!("[inventory] Added {}x {} to {}", quantity, item_id, owner_id);
}

// ── REMOVE ITEM ───────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn remove_item(
    ctx: &ReducerContext,
    owner_id: String,
    item_id:  String,
    quantity: u32,
) {
    let slot = ctx.db.inventory_slot().iter()
        .find(|s| s.owner_id == owner_id && s.item_id == item_id);

    let mut slot = match slot {
        Some(s) => s,
        None => {
            log::warn!("[inventory] remove_item: {} not in {}'s inventory", item_id, owner_id);
            return;
        }
    };

    if slot.quantity < quantity {
        log::warn!("[inventory] remove_item: not enough {} (has {}, needs {})", item_id, slot.quantity, quantity);
        return;
    }

    if slot.quantity == quantity {
        ctx.db.inventory_slot().id().delete(slot.id);
    } else {
        slot.quantity -= quantity;
        ctx.db.inventory_slot().id().update(slot);
    }

    log::info!("[inventory] Removed {}x {} from {}", quantity, item_id, owner_id);
}

// ── MOVE ITEM (drag between slots) ────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn move_item(
    ctx: &ReducerContext,
    slot_id:        u64,
    new_slot_index: u32,
) {
    let identity = ctx.sender();
    let owner_id = identity.to_hex().to_string();

    let mut slot = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => {
            log::warn!("[inventory] move_item: slot {} not found", slot_id);
            return;
        }
    };

    // Security: only owner can move their items
    if slot.owner_id != owner_id {
        log::warn!("[inventory] move_item: {} tried to move slot owned by {}", owner_id, slot.owner_id);
        return;
    }

    slot.slot_index = new_slot_index;
    ctx.db.inventory_slot().id().update(slot);
}

// ── SPLIT STACK ───────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn split_stack(
    ctx: &ReducerContext,
    slot_id: u64,
    amount:  u32,
) {
    let identity = ctx.sender();
    let owner_id = identity.to_hex().to_string();

    let mut original = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => {
            log::warn!("[inventory] split_stack: slot {} not found", slot_id);
            return;
        }
    };

    if original.owner_id != owner_id {
        log::warn!("[inventory] split_stack: {} tried to split slot owned by {}", owner_id, original.owner_id);
        return;
    }

    // Must split at least 1 and leave at least 1 behind
    if amount == 0 || amount >= original.quantity {
        log::warn!(
            "[inventory] split_stack: invalid amount {} for slot {} (quantity {})",
            amount, slot_id, original.quantity
        );
        return;
    }

    // Find a free slot index within the same owner/panel space
    let used_slots: Vec<u32> = ctx.db.inventory_slot().iter()
        .filter(|s| s.owner_id == owner_id && s.owner_type == original.owner_type)
        .map(|s| s.slot_index)
        .collect();
    let new_slot_index = (0u32..).find(|i| !used_slots.contains(i)).unwrap_or(0);

    // Reduce original stack
    original.quantity -= amount;
    ctx.db.inventory_slot().id().update(original.clone());

    // Insert the new split stack
    ctx.db.inventory_slot().insert(InventorySlot {
        id:         0, // auto_inc
        owner_id:   original.owner_id.clone(),
        owner_type: original.owner_type.clone(),
        item_id:    original.item_id.clone(),
        quantity:   amount,
        metadata:   original.metadata.clone(),
        slot_index: new_slot_index,
    });

    log::info!(
        "[inventory] split_stack: slot {} split off {}x {} → new slot at index {}",
        slot_id, amount, original.item_id, new_slot_index
    );
}

// ── MERGE STACKS ──────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn merge_stacks(
    ctx: &ReducerContext,
    src_slot_id: u64,
    dst_slot_id: u64,
) {
    let identity = ctx.sender();
    let owner_id = identity.to_hex().to_string();

    let src = match ctx.db.inventory_slot().id().find(src_slot_id) {
        Some(s) => s,
        None => {
            log::warn!("[inventory] merge_stacks: src slot {} not found", src_slot_id);
            return;
        }
    };
    let mut dst = match ctx.db.inventory_slot().id().find(dst_slot_id) {
        Some(s) => s,
        None => {
            log::warn!("[inventory] merge_stacks: dst slot {} not found", dst_slot_id);
            return;
        }
    };

    if src.owner_id != owner_id || dst.owner_id != owner_id {
        log::warn!("[inventory] merge_stacks: ownership mismatch");
        return;
    }

    if src.item_id != dst.item_id {
        log::warn!("[inventory] merge_stacks: item_id mismatch ({} vs {})", src.item_id, dst.item_id);
        return;
    }

    let def = match ctx.db.item_definition().item_id().find(&dst.item_id) {
        Some(d) => d,
        None => return,
    };

    let total     = src.quantity + dst.quantity;
    let capped    = total.min(def.max_stack);
    let remainder = total - capped;

    dst.quantity = capped;
    ctx.db.inventory_slot().id().update(dst);

    if remainder == 0 {
        ctx.db.inventory_slot().id().delete(src_slot_id);
    } else {
        let mut src_mut = src;
        src_mut.quantity = remainder;
        ctx.db.inventory_slot().id().update(src_mut);
    }

    log::info!("[inventory] merge_stacks: merged slots {} → {}", src_slot_id, dst_slot_id);
}

// ── USE ITEM ──────────────────────────────────────────────────────────────────

#[spacetimedb::reducer]
pub fn use_item(
    ctx: &ReducerContext,
    slot_id:  u64,
    net_id:   u32,
) {
    let identity = ctx.sender();
    let owner_id = identity.to_hex().to_string();

    let slot = match ctx.db.inventory_slot().id().find(slot_id) {
        Some(s) => s,
        None => {
            log::warn!("[inventory] use_item: slot {} not found", slot_id);
            return;
        }
    };

    if slot.owner_id != owner_id {
        log::warn!("[inventory] use_item: ownership mismatch");
        return;
    }

    let def = match ctx.db.item_definition().item_id().find(&slot.item_id) {
        Some(d) => d,
        None => return,
    };

    if !def.usable {
        log::warn!("[inventory] use_item: {} is not usable", slot.item_id);
        return;
    }

    // Item-specific effects via instruction_queue
    match slot.item_id.as_str() {
        "bandage" => {
            ctx.db.instruction_queue().insert(InstructionQueue {
                id:                   0,
                target_entity_net_id: net_id,
                opcode:               opcodes::entity::SET_HEALTH,
                payload:              json!([200]).to_string(),
                queued_at:            ctx.timestamp,
                consumed:             false,
            });
            // consume one bandage
            drop(slot);
            ctx.db.inventory_slot().id().find(slot_id).map(|mut s| {
                if s.quantity <= 1 {
                    ctx.db.inventory_slot().id().delete(slot_id);
                } else {
                    s.quantity -= 1;
                    ctx.db.inventory_slot().id().update(s);
                }
            });
        }
        _ => {
            log::info!("[inventory] use_item: no handler for {}", slot.item_id);
        }
    }
}