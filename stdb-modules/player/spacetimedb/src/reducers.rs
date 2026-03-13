use spacetimedb::{ReducerContext, Table};
use crate::tables::{Player, ActiveSession};
use crate::tables::{player, active_session};
use stdb_core::InstructionQueue;
use stdb_core::instruction::instruction_queue;
use serde_json::json;

#[spacetimedb::reducer]
pub fn on_player_connect(
    ctx: &ReducerContext,
    steam_hex: String,
    display_name: String,
    server_id: u32,
    net_id: u32,
) {
    let identity = ctx.sender();

    if let Some(mut p) = ctx.db.player().identity().find(identity) {
        p.last_seen = ctx.timestamp;
        p.display_name = display_name;
        ctx.db.player().identity().update(p);
    } else {
        ctx.db.player().insert(Player {
            identity,
            steam_hex,
            display_name,
            money_cash: 5000,
            money_bank: 0,
            job: "unemployed".to_string(),
            created_at: ctx.timestamp,
            last_seen: ctx.timestamp,
        });
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
pub fn request_spawn(
    ctx: &ReducerContext,
    spawn_x: f32,
    spawn_y: f32,
    spawn_z: f32,
    heading: f32,
) {
    let identity = ctx.sender();

    let session = match ctx.db.active_session().identity().find(identity) {
        Some(s) => s,
        None => {
            log::warn!("[player] request_spawn: {} not in active session", identity);
            return;
        }
    };

    if spawn_x < -8000.0 || spawn_x > 8000.0 || spawn_y < -8000.0 || spawn_y > 8000.0 {
        log::warn!("[player] request_spawn: coords out of bounds");
        return;
    }

    // Args array — entity is prepended automatically by the Lua relay
    // SET_ENTITY_COORDS(entity, x, y, z, xAxis, yAxis, clearArea)
    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0,
        target_entity_net_id: session.net_id,
        native_key: "SET_ENTITY_COORDS".to_string(),
        payload: json!([spawn_x, spawn_y, spawn_z, false, false, true]).to_string(),
        queued_at: ctx.timestamp,
        consumed: false,
    });

    // FREEZE_ENTITY_POSITION(entity, toggle)
    ctx.db.instruction_queue().insert(InstructionQueue {
        id: 0,
        target_entity_net_id: session.net_id,
        native_key: "FREEZE_ENTITY_POSITION".to_string(),
        payload: json!([false]).to_string(),
        queued_at: ctx.timestamp,
        consumed: false,
    });

    log::info!("[player] Spawn queued for {} at ({}, {}, {})", identity, spawn_x, spawn_y, spawn_z);
}

#[spacetimedb::reducer]
pub fn on_player_disconnect(ctx: &ReducerContext) {
    ctx.db.active_session().identity().delete(ctx.sender());
    log::info!("[player] {} session cleared", ctx.sender());
}