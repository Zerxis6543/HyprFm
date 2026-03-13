/// Master item definitions — read-only catalog
#[spacetimedb::table(accessor = item_definition, public)]
#[derive(Clone, Debug)]
pub struct ItemDefinition {
    #[primary_key]
    pub item_id:   String,
    pub label:     String,
    pub weight:    f32,
    pub stackable: bool,
    pub usable:    bool,
    pub max_stack: u32,
}

/// One row per stack of items in an inventory slot
#[spacetimedb::table(accessor = inventory_slot, public)]
#[derive(Clone, Debug)]
pub struct InventorySlot {
    #[primary_key]
    #[auto_inc]
    pub id:         u64,
    pub owner_id:   String,   // identity hex, vehicle plate, or stash name
    pub owner_type: String,   // "player", "vehicle", "stash"
    pub item_id:    String,
    pub quantity:   u32,
    pub metadata:   String,   // JSON: durability, ammo, serial, etc
    pub slot_index: u32,
}