use spacetimedb::{Identity, Timestamp};

#[spacetimedb::table(accessor = player, public)]
#[derive(Clone, Debug)]
pub struct Player {
    #[primary_key]
    pub identity: Identity,
    pub steam_hex: String,
    pub display_name: String,
    pub money_cash: i64,
    pub money_bank: i64,
    pub job: String,
    pub created_at: Timestamp,
    pub last_seen: Timestamp,
}

#[spacetimedb::table(accessor = active_session, public)]
#[derive(Clone, Debug)]
pub struct ActiveSession {
    #[primary_key]
    pub identity: Identity,
    pub server_id: u32,
    pub net_id: u32,
    pub connected_at: Timestamp,
}

#[spacetimedb::table(accessor = spawn_request, public)]
#[derive(Clone, Debug)]
pub struct SpawnRequest {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    pub identity: Identity,
    pub spawn_x: f32,
    pub spawn_y: f32,
    pub spawn_z: f32,
    pub spawn_heading: f32,
    pub model_hash: u32,
    pub fulfilled: bool,
}