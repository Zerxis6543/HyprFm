import { create } from 'zustand'
import { ActiveTab, EquipSlot, EquipSlotKey, ItemDefinition, InventorySlot } from './types'

export type SecondaryType = 'ground' | 'glovebox' | 'trunk' | 'stash' | null

export interface SecondaryContext {
  type:      SecondaryType
  label:     string
  id:        string
  maxWeight: number
  maxSlots:  number
  slots:     InventorySlot[]
}

interface InventoryStore {
  isOpen:         boolean
  activeTab:      ActiveTab
  slots:          InventorySlot[]
  itemDefs:       Record<string, ItemDefinition>
  maxWeight:      number
  baseMaxWeight:  number
  maxSlots:       number
  secondary:      SecondaryContext
  equipSlots:     EquipSlot[]
  health:         number
  contextMenu:    { slotId: number; x: number; y: number } | null
  draggingSlot:   InventorySlot | null
  draggingSource: 'pockets' | 'secondary' | null
  weightFlash:    'pockets' | 'secondary' | null

  openInventory:   (slots: InventorySlot[], itemDefs: Record<string, ItemDefinition>, maxWeight: number, secondary?: Partial<SecondaryContext>) => void
  openBackpack:    (bagItemId: string) => void
  closeInventory:  () => void
  updateSlots:     (slots: InventorySlot[]) => void
  updateSecondary: (slots: InventorySlot[]) => void
  setSecondary:    (ctx: Partial<SecondaryContext>) => void
  setTab:          (tab: ActiveTab) => void
  setHealth:       (health: number) => void
  setDragging:     (slot: InventorySlot | null, source: 'pockets' | 'secondary' | null) => void
  moveSlot:        (slotId: number, newIndex: number, sourcePanel?: 'pockets' | 'secondary', targetPanel?: 'pockets' | 'secondary') => void
  equipItem:       (slotId: number, equipKey: EquipSlotKey, sourcePanel: 'pockets' | 'secondary') => void
  unequipItem:     (equipKey: EquipSlotKey, targetPanel: 'pockets' | 'secondary', targetIndex: number) => void
  swapEquip:       (srcKey: EquipSlotKey, dstKey: EquipSlotKey) => void
  splitStack:      (slotId: number, amount: number) => void
  showContext:     (slotId: number, x: number, y: number) => void
  hideContext:     () => void
}

const EMPTY_SECONDARY: SecondaryContext = {
  type: 'ground', label: 'GROUND', id: '', maxWeight: 999, maxSlots: 24, slots: []
}

const DEFAULT_EQUIP_SLOTS: EquipSlot[] = [
  { key: 'backpack',         label: 'BACKPACK',    slot: null },
  { key: 'body_armour',      label: 'BODY ARMOUR', slot: null },
  { key: 'phone',            label: 'PHONE',       slot: null },
  { key: 'parachute',        label: 'PARACHUTE',   slot: null },
  { key: 'weapon_primary',   label: 'WEAPON 1',    slot: null },
  { key: 'weapon_secondary', label: 'WEAPON 2',    slot: null },
  { key: 'hotkey_1',         label: 'HOTKEY 1',    slot: null },
  { key: 'hotkey_2',         label: 'HOTKEY 2',    slot: null },
  { key: 'hotkey_3',         label: 'HOTKEY 3',    slot: null },
  { key: 'hotkey_4',         label: 'HOTKEY 4',    slot: null },
  { key: 'hotkey_5',         label: 'HOTKEY 5',    slot: null },
]

export const useInventoryStore = create<InventoryStore>((set, get) => ({
  isOpen:         false,
  activeTab:      'inventories',
  slots:          [],
  itemDefs:       {},
  maxWeight:      85,
  baseMaxWeight:  85,
  maxSlots:       24,
  secondary:      EMPTY_SECONDARY,
  equipSlots:     DEFAULT_EQUIP_SLOTS,
  health:         100,
  contextMenu:    null,
  draggingSlot:   null,
  draggingSource: null,
  weightFlash:    null,

  openInventory: (slots, itemDefs, maxWeight, secondary) => set({
    isOpen: true, slots, itemDefs,
    maxWeight:     maxWeight ?? 85,
    baseMaxWeight: maxWeight ?? 85,
    secondary: secondary ? { ...EMPTY_SECONDARY, ...secondary } : EMPTY_SECONDARY,
  }),

  closeInventory: () => {
    set({ isOpen: false, contextMenu: null, secondary: EMPTY_SECONDARY, draggingSlot: null, draggingSource: null })
    fetch(`https://${GetParentResourceName()}/close`, { method: 'POST', body: JSON.stringify({}) })
  },

  updateSlots:     (slots) => set({ slots }),
  updateSecondary: (slots) => set(s => ({ secondary: { ...s.secondary, slots } })),
  setSecondary:    (ctx)   => set(s => ({ secondary: { ...s.secondary, ...ctx } })),
  setTab:          (tab)   => set({ activeTab: tab }),
  setHealth:       (h)     => set({ health: h }),
  setDragging:     (slot, source) => set({ draggingSlot: slot, draggingSource: source }),
  openBackpack: (bagItemId) => {
    fetch(`https://${GetParentResourceName()}/openBackpack`, {
      method: 'POST', body: JSON.stringify({ bagItemId })
    })
  },

  moveSlot: (slotId, newIndex, sourcePanel = 'pockets', targetPanel = 'pockets') => {
    const state = get()
    const srcSlots = sourcePanel === 'pockets' ? state.slots : state.secondary.slots
    const tgtSlots = targetPanel === 'pockets' ? state.slots : state.secondary.slots

    const moving = srcSlots.find(s => s.id === slotId)
    if (!moving) return

    // Weight check — only when moving INTO a different panel
    if (sourcePanel !== targetPanel) {
      const movingDef   = state.itemDefs[moving.item_id]
      const movingWeight = movingDef ? movingDef.weight * moving.quantity : 0
      const displaced   = tgtSlots.find(s => s.slot_index === newIndex && s.id !== slotId)
      const displacedDef = displaced ? state.itemDefs[displaced.item_id] : null
      const displacedWeight = (displacedDef && displaced) ? displacedDef.weight * displaced.quantity : 0

      const tgtMaxWeight = targetPanel === 'pockets' ? state.maxWeight : state.secondary.maxWeight
      const tgtCurrentWeight = tgtSlots.reduce((acc, s) => {
        const d = state.itemDefs[s.item_id]
        return acc + (d ? d.weight * s.quantity : 0)
      }, 0)
      // Net weight change in target = moving in - displaced out
      const netChange = movingWeight - displacedWeight
      if (tgtCurrentWeight + netChange > tgtMaxWeight) {
        // Flash the weight bar red to signal rejection
        set(s => {
          const flash = targetPanel === 'pockets'
            ? { weightFlash: 'pockets' as const }
            : { weightFlash: 'secondary' as const }
          return { ...flash }
        })
        setTimeout(() => set({ weightFlash: null }), 600)
        return
      }
    }

    // ── Stack merge: drop onto same item_id ───────────────────────────────────
    const stackTarget = tgtSlots.find(s => s.slot_index === newIndex && s.id !== slotId && s.item_id === moving.item_id)
    const movingDef   = state.itemDefs[moving.item_id]
    if (stackTarget && movingDef?.stackable) {
      const total    = moving.quantity + stackTarget.quantity
      const capped   = Math.min(total, movingDef.max_stack)
      const remainder = total - capped
      const mergedTgt = { ...stackTarget, quantity: capped }
      if (sourcePanel === targetPanel) {
        const updated = srcSlots
          .filter(s => remainder === 0 ? s.id !== slotId : true)
          .map(s => {
            if (s.id === slotId && remainder > 0) return { ...s, quantity: remainder }
            if (s.id === stackTarget.id) return mergedTgt
            return s
          })
        if (sourcePanel === 'pockets') set({ slots: updated })
        else set(s => ({ secondary: { ...s.secondary, slots: updated } }))
      } else {
        const newSrc = remainder === 0
          ? srcSlots.filter(s => s.id !== slotId)
          : srcSlots.map(s => s.id === slotId ? { ...s, quantity: remainder } : s)
        const newTgt = tgtSlots.map(s => s.id === stackTarget.id ? mergedTgt : s)
        if (sourcePanel === 'pockets') set(s => ({ slots: newSrc, secondary: { ...s.secondary, slots: newTgt } }))
        else set(s => ({ slots: newTgt, secondary: { ...s.secondary, slots: newSrc } }))
      }
      fetch(`https://${GetParentResourceName()}/mergeStacks`, {
        method: 'POST', body: JSON.stringify({ srcSlotId: slotId, dstSlotId: stackTarget.id })
      })
      return
    }

    const oldIndex = moving.slot_index

    if (sourcePanel === targetPanel) {
      const displaced = srcSlots.find(s => s.slot_index === newIndex && s.id !== slotId)
      const updated = srcSlots.map(s => {
        if (s.id === slotId) return { ...s, slot_index: newIndex }
        if (displaced && s.id === displaced.id) return { ...s, slot_index: oldIndex }
        return s
      })
      if (sourcePanel === 'pockets') set({ slots: updated })
      else set(s => ({ secondary: { ...s.secondary, slots: updated } }))
      fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId, newSlotIndex: newIndex })
      })
      if (displaced) fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId: displaced.id, newSlotIndex: oldIndex })
      })
    } else {
      const displaced = tgtSlots.find(s => s.slot_index === newIndex)
      let newSrcSlots = srcSlots.filter(s => s.id !== slotId)
      if (displaced) newSrcSlots = [...newSrcSlots, { ...displaced, slot_index: oldIndex }]
      const newTgtSlots = [
        ...tgtSlots.filter(s => !displaced ? s.slot_index !== newIndex : s.id !== displaced.id),
        { ...moving, slot_index: newIndex },
      ]
      if (sourcePanel === 'pockets') {
        set(s => ({ slots: newSrcSlots, secondary: { ...s.secondary, slots: newTgtSlots } }))
      } else {
        set(s => ({ slots: newTgtSlots, secondary: { ...s.secondary, slots: newSrcSlots } }))
      }
      const tgtOwner = targetPanel === 'secondary'
        ? { ownerType: state.secondary.type, ownerId: state.secondary.id }
        : { ownerType: 'player', ownerId: '' }
      fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId, newSlotIndex: newIndex, ...tgtOwner })
      })
      if (displaced) {
        const srcOwner = sourcePanel === 'secondary'
          ? { ownerType: state.secondary.type, ownerId: state.secondary.id }
          : { ownerType: 'player', ownerId: '' }
        fetch(`https://${GetParentResourceName()}/moveItem`, {
          method: 'POST', body: JSON.stringify({ slotId: displaced.id, newSlotIndex: oldIndex, ...srcOwner })
        })
      }
    }
  },

  equipItem: (slotId, equipKey, sourcePanel) => {
    const state = get()
    const srcSlots = sourcePanel === 'pockets' ? state.slots : state.secondary.slots
    const moving   = srcSlots.find(s => s.id === slotId)
    if (!moving) return
    const newSrcSlots   = srcSlots.filter(s => s.id !== slotId)
    const newEquipSlots = state.equipSlots.map(s => s.key === equipKey ? { ...s, slot: moving } : s)
    const BAG_BONUS: Record<string, number> = { backpack: 30, duffel_bag: 50 }
    const bonus = equipKey === 'backpack' ? (BAG_BONUS[moving.item_id] ?? 0) : 0
    const newMaxWeight = bonus > 0 ? state.baseMaxWeight + bonus : state.maxWeight
    if (sourcePanel === 'pockets') set({ slots: newSrcSlots, equipSlots: newEquipSlots, maxWeight: newMaxWeight })
    else set(s => ({ secondary: { ...s.secondary, slots: newSrcSlots }, equipSlots: newEquipSlots, maxWeight: newMaxWeight }))
    fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId, equipKey })
    })
  },

unequipItem: (equipKey, targetPanel, targetIndex) => {
    const state = get()
    const equip = state.equipSlots.find(s => s.key === equipKey)
    if (!equip?.slot) return
    const slot = equip.slot
    const newEquipSlots = state.equipSlots.map(s => s.key === equipKey ? { ...s, slot: null } : s)
    const updatedSlot = { ...slot, slot_index: targetIndex }
    const newMaxWeight = equipKey === 'backpack' ? state.baseMaxWeight : state.maxWeight
    if (targetPanel === 'pockets') {
      set({ equipSlots: newEquipSlots, slots: [...state.slots, updatedSlot], maxWeight: newMaxWeight })
    } else {
      set(s => ({ equipSlots: newEquipSlots, secondary: { ...s.secondary, slots: [...s.secondary.slots, updatedSlot] }, maxWeight: newMaxWeight }))
    }
    fetch(`https://${GetParentResourceName()}/unequipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: slot.id, equipKey, targetPanel, targetIndex })
    })
  },

swapEquip: (srcKey, dstKey) => {
    const state = get()
    const srcSlot = state.equipSlots.find(s => s.key === srcKey)?.slot ?? null
    const dstSlot = state.equipSlots.find(s => s.key === dstKey)?.slot ?? null
    // Category check on destination
    const EQUIP_ALLOWED: Record<string, string[]> = {
      backpack: ['bag'], body_armour: ['armor'], phone: ['phone'],
      parachute: ['parachute'], weapon_primary: ['weapon'], weapon_secondary: ['weapon'],
      hotkey_1: ['any'], hotkey_2: ['any'], hotkey_3: ['any'], hotkey_4: ['any'], hotkey_5: ['any'],
    }
    const canFit = (item: typeof srcSlot, key: string) => {
      if (!item) return true
      const allowed = EQUIP_ALLOWED[key]
      if (!allowed) return false
      if (allowed.includes('any')) return true
      return allowed.includes(state.itemDefs[item.item_id]?.category ?? 'misc')
    }
    if (!canFit(srcSlot, dstKey) || !canFit(dstSlot, srcKey)) return
    set({
      equipSlots: state.equipSlots.map(s => {
        if (s.key === srcKey) return { ...s, slot: dstSlot }
        if (s.key === dstKey) return { ...s, slot: srcSlot }
        return s
      })
    })
    // Tell server about both moves
    if (srcSlot) fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: srcSlot.id, equipKey: dstKey })
    })
    if (dstSlot) fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: dstSlot.id, equipKey: srcKey })
    })
  },

splitStack: (slotId, amount) => {
    const state = get()
    const inPockets = !!state.slots.find(s => s.id === slotId)
    const panelSlots = inPockets ? state.slots : state.secondary.slots
    const slot = panelSlots.find(s => s.id === slotId)
    if (!slot || amount <= 0 || amount >= slot.quantity) return

    // Search only within the same panel — the two panels have independent slot_index spaces
    const used = panelSlots.map(s => s.slot_index)
    const newIndex = Array.from({ length: 999 }, (_, i) => i).find(i => !used.includes(i)) ?? 0

    // Use a negative temp id — safe JS integer, guaranteed not to collide with real u64 server ids
    // The server will push back the authoritative row via updateSlots/updateSecondary
    const tempId  = -(Date.now())
    const newSlot = { ...slot, id: tempId, quantity: amount, slot_index: newIndex }
    const reduced = { ...slot, quantity: slot.quantity - amount }
    const updateArr = (arr: typeof state.slots) =>
      arr.map(s => s.id === slotId ? reduced : s)

    if (inPockets) {
      set(s => ({ slots: [...updateArr(s.slots), newSlot] }))
    } else {
      set(s => ({ secondary: { ...s.secondary, slots: [...updateArr(s.secondary.slots), newSlot] } }))
    }
    fetch(`https://${GetParentResourceName()}/splitStack`, {
      method: 'POST', body: JSON.stringify({ slotId, amount })
    })
  },
  
  showContext: (slotId, x, y) => set({ contextMenu: { slotId, x, y } }),
  hideContext: () => set({ contextMenu: null }),
}))

function GetParentResourceName(): string {
  if (typeof window !== 'undefined' && (window as any).GetParentResourceName) {
    return (window as any).GetParentResourceName()
  }
  return 'stdb-inventory'
}