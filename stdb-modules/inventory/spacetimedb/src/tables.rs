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
    pub category:  String,
    pub prop_model: String,
}

/// One row per stack of items in an inventory slot
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