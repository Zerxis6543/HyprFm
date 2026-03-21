export interface ItemDefinition {
  item_id:    string
  label:      string
  weight:     number
  stackable:  boolean
  usable:     boolean
  max_stack:  number
  category:   string
  prop_model: string
}

export interface InventorySlot {
  id: number
  owner_id: string
  owner_type: string
  item_id: string
  quantity: number
  metadata: string
  slot_index: number
}

export type EquipSlotKey =
  | 'backpack' | 'body_armour' | 'phone'
  | 'parachute'
  | 'weapon_primary' | 'weapon_secondary'
  | 'hotkey_1' | 'hotkey_2' | 'hotkey_3'
  | 'hotkey_4' | 'hotkey_5'

export interface EquipSlot {
  key: EquipSlotKey
  label: string
  slot: InventorySlot | null
}

export type ActiveTab = 'inventories' | 'utility'

// Returns the WebP image path for an item — images live in web/public/items/
export function itemIcon(item_id: string): string {
  return `./items/${item_id}.webp`
}

export const ITEM_RARITY: Record<string, { label: string; color: string }> = {
  bandage:       { label: 'COMMON',   color: '#888' },
  medkit:        { label: 'UNCOMMON', color: '#4ade80' },
  water_bottle:  { label: 'COMMON',   color: '#888' },
  food_burger:   { label: 'COMMON',   color: '#888' },
  id_card:       { label: 'COMMON',   color: '#888' },
  cash:          { label: 'COMMON',   color: '#888' },
  phone:         { label: 'UNCOMMON', color: '#4ade80' },
  weapon_pistol: { label: 'RARE',     color: '#60a5fa' },
  ammo_pistol:   { label: 'COMMON',   color: '#888' },
  weapon_knife:  { label: 'UNCOMMON', color: '#4ade80' },
  lockpick:      { label: 'UNCOMMON', color: '#4ade80' },
  handcuffs:     { label: 'RARE',     color: '#60a5fa' },
  evidence_bag:  { label: 'COMMON',   color: '#888' },
  radio:         { label: 'UNCOMMON', color: '#4ade80' },
  weed:          { label: 'COMMON',   color: '#888' },
  cocaine:       { label: 'RARE',     color: '#60a5fa' },
}
