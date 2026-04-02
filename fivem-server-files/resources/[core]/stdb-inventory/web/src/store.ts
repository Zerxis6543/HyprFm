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

// ── Drag modifier state ───────────────────────────────────────────────────────
// Plain mutable object — not reactive state, so no re-renders on every
// pointer-down. Set in ItemSlot.tsx, read in App.tsx handleDragEnd.
export const dragState = {
  modifier:      null as null | 'half' | 'single',
  isRightButton: false,
}

interface InventoryStore {
  isOpen:         boolean
  activeTab:      ActiveTab
  slots:          InventorySlot[]
  itemDefs:       Record<string, ItemDefinition>
  maxWeight:      number
  maxSlots:       number
  secondary:      SecondaryContext
  backpack:       SecondaryContext | null
  equipSlots:     EquipSlot[]
  health:         number
  contextMenu:    { slotId: number; x: number; y: number } | null
  contextMenuInitialSplit: boolean   // true  → ContextMenu opens straight to split UI
  draggingSlot:   InventorySlot | null
  draggingSource: 'pockets' | 'secondary' | 'backpack' | null
  weightFlash:    'pockets' | 'secondary' | null
  inspectMode:    boolean
  inspectSlot:    InventorySlot | null

  equipMappings:        Record<string, string>
  registerEquipMapping: (itemId: string, equipKey: string) => void

  openInventory:   (slots: InventorySlot[], itemDefs: Record<string, ItemDefinition>, maxWeight: number, secondary?: Partial<SecondaryContext>) => void
  openBackpack:    (bagItemId: string) => void
  closeInventory:  () => void
  updateSlots:     (slots: InventorySlot[]) => void
  updateSecondary: (slots: InventorySlot[]) => void
  setSecondary:       (ctx: Partial<SecondaryContext>) => void
  openBackpackPanel:  (ctx: Partial<SecondaryContext>) => void
  closeBackpackPanel: () => void
  setTab:             (tab: ActiveTab) => void
  setHealth:       (health: number) => void
  setDragging:     (slot: InventorySlot | null, source: 'pockets' | 'secondary' | 'backpack' | null) => void
  moveSlot:        (slotId: number, newIndex: number, sourcePanel?: 'pockets' | 'secondary' | 'backpack', targetPanel?: 'pockets' | 'secondary' | 'backpack', qty?: number) => void
  equipItem:       (slotId: number, equipKey: EquipSlotKey, sourcePanel: 'pockets' | 'secondary' | 'backpack') => void
  unequipItem:     (equipKey: EquipSlotKey, targetPanel: 'pockets' | 'secondary' | 'backpack', targetIndex: number) => void
  swapEquip:       (srcKey: EquipSlotKey, dstKey: EquipSlotKey) => void
  splitStack:      (slotId: number, amount: number) => void
  showContext:     (slotId: number, x: number, y: number) => void
  showContextSplit:(slotId: number, x: number, y: number) => void
  hideContext:     () => void
  startInspect:    (slot: InventorySlot) => void
  stopInspect:     () => void
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
  isOpen:                  false,
  activeTab:               'inventories',
  slots:                   [],
  itemDefs:                {},
  maxWeight:               85,
  maxSlots:                24,
  secondary:               EMPTY_SECONDARY,
  backpack:                null,
  equipSlots:              DEFAULT_EQUIP_SLOTS,
  health:                  100,
  contextMenu:             null,
  contextMenuInitialSplit: false,
  draggingSlot:            null,
  draggingSource:          null,
  weightFlash:             null,
  inspectMode:             false,
  inspectSlot:             null,
  equipMappings: {
    backpack:        'backpack',
    duffel_bag:      'backpack',
    body_armour:     'body_armour',
    phone:           'phone',
    parachute:       'parachute',
    weapon_pistol:   'weapon_primary',
    weapon_knife:    'weapon_secondary',
    assault_rifle:   'weapon_primary',
  },

  openInventory: (slots, itemDefs, maxWeight, secondary) => set({
    isOpen: true, slots, itemDefs,
    maxWeight:     maxWeight ?? 85,
    secondary: secondary ? { ...EMPTY_SECONDARY, ...secondary } : EMPTY_SECONDARY,
  }),

  closeInventory: () => {
    set({ isOpen: false, contextMenu: null, contextMenuInitialSplit: false, secondary: EMPTY_SECONDARY, draggingSlot: null, draggingSource: null, backpack: null, inspectMode: false, inspectSlot: null })
    fetch(`https://${GetParentResourceName()}/close`, { method: 'POST', body: JSON.stringify({}) })
  },

  updateSlots:     (slots) => set({ slots }),
  updateSecondary: (slots) => set(s => ({ secondary: { ...s.secondary, slots } })),
  setSecondary:    (ctx)   => set(s => ({ secondary: { ...s.secondary, ...ctx } })),
  openBackpackPanel: (ctx) => set({ backpack: { ...EMPTY_SECONDARY, ...ctx } }),
  closeBackpackPanel: () => set({ backpack: null }),
  setTab:          (tab)   => set({ activeTab: tab }),
  setHealth:       (h)     => set({ health: h }),
  setDragging:     (slot, source) => set({ draggingSlot: slot, draggingSource: source }),
  openBackpack: (bagItemId) => {
    fetch(`https://${GetParentResourceName()}/openBackpack`, {
      method: 'POST', body: JSON.stringify({ bagItemId })
    })
  },

  // showContext      — normal right-click, opens action list
  showContext:      (slotId, x, y) => set({ contextMenu: { slotId, x, y }, contextMenuInitialSplit: false }),
  // showContextSplit — shift+right-click, opens directly in split-amount picker
  showContextSplit: (slotId, x, y) => set({ contextMenu: { slotId, x, y }, contextMenuInitialSplit: true }),
  hideContext:      () => set({ contextMenu: null, contextMenuInitialSplit: false }),

  // ── moveSlot ───────────────────────────────────────────────────────────────
  // qty is optional. When supplied and less than the slot's total quantity, the
  // server atomically splits the stack and moves the split portion.
  moveSlot: (slotId, newIndex, sourcePanel = 'pockets', targetPanel = 'pockets', qty) => {
    const state = get()
    const getSlotsForPanel = (p: string) => {
      if (p === 'pockets')   return state.slots
      if (p === 'backpack')  return state.backpack?.slots ?? []
      return state.secondary.slots
    }
    const setSlotsForPanel = (p: string, updated: typeof state.slots) => {
      if (p === 'pockets')  set({ slots: updated })
      else if (p === 'backpack') set(s => ({ backpack: s.backpack ? { ...s.backpack, slots: updated } : null }))
      else set(s => ({ secondary: { ...s.secondary, slots: updated } }))
    }
    const getOwnerForPanel = (p: string) => {
      if (p === 'pockets')  return { ownerType: 'player', ownerId: '' }
      if (p === 'backpack') return { ownerType: 'stash',  ownerId: state.backpack?.id ?? '' }
      return { ownerType: state.secondary.type, ownerId: state.secondary.id }
    }
    const getMaxWeightForPanel = (p: string) => {
      if (p === 'pockets')  return state.maxWeight
      if (p === 'backpack') return state.backpack?.maxWeight ?? 30
      return state.secondary.maxWeight
    }
    const srcSlots = getSlotsForPanel(sourcePanel)
    const tgtSlots = getSlotsForPanel(targetPanel)

    const moving = srcSlots.find(s => s.id === slotId)
    if (!moving) return

    // Resolve effective quantity — partial move when qty < moving.quantity
    const effectiveQty = (qty && qty > 0 && qty < moving.quantity) ? qty : moving.quantity
    const isPartial    = effectiveQty < moving.quantity

    // Weight check — only when moving INTO a different panel
    if (sourcePanel !== targetPanel) {
      const movingDef    = state.itemDefs[moving.item_id]
      const movingWeight = movingDef ? movingDef.weight * effectiveQty : 0
      const displaced    = tgtSlots.find(s => s.slot_index === newIndex && s.id !== slotId)
      const displacedDef = displaced ? state.itemDefs[displaced.item_id] : null
      const displacedWeight = (displacedDef && displaced) ? displacedDef.weight * displaced.quantity : 0

      const tgtMaxWeight     = getMaxWeightForPanel(targetPanel)
      const tgtCurrentWeight = tgtSlots.reduce((acc, s) => {
        const d = state.itemDefs[s.item_id]
        return acc + (d ? d.weight * s.quantity : 0)
      }, 0)
      if (tgtCurrentWeight + movingWeight - displacedWeight > tgtMaxWeight) {
        set(s => ({ weightFlash: targetPanel === 'pockets' ? 'pockets' : 'secondary' }))
        setTimeout(() => set({ weightFlash: null }), 600)
        return
      }
    }

    // ── Partial move ──────────────────────────────────────────────────────────
    // Optimistic: reduce source quantity. The split-off slot at destination
    // arrives a moment later via the delta push.
    if (isPartial) {
      const reducedSrc = srcSlots.map(s => s.id === slotId ? { ...s, quantity: s.quantity - effectiveQty } : s)
      setSlotsForPanel(sourcePanel, reducedSrc)
      const tgtOwner = getOwnerForPanel(targetPanel)
      fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST',
        body: JSON.stringify({ slotId, newSlotIndex: newIndex, ...tgtOwner, quantity: effectiveQty }),
      })
      return
    }

    // ── Stack merge ───────────────────────────────────────────────────────────
    const stackTarget = tgtSlots.find(s => s.slot_index === newIndex && s.id !== slotId && s.item_id === moving.item_id)
    const movingDef   = state.itemDefs[moving.item_id]
    if (stackTarget && movingDef?.stackable) {
      const total     = moving.quantity + stackTarget.quantity
      const capped    = Math.min(total, movingDef.max_stack)
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
        setSlotsForPanel(sourcePanel, updated)
      } else {
        const newSrc = remainder === 0
          ? srcSlots.filter(s => s.id !== slotId)
          : srcSlots.map(s => s.id === slotId ? { ...s, quantity: remainder } : s)
        const newTgt = tgtSlots.map(s => s.id === stackTarget.id ? mergedTgt : s)
        setSlotsForPanel(sourcePanel, newSrc)
        setSlotsForPanel(targetPanel, newTgt)
      }
      fetch(`https://${GetParentResourceName()}/mergeStacks`, {
        method: 'POST', body: JSON.stringify({ srcSlotId: slotId, dstSlotId: stackTarget.id })
      })
      return
    }

    const oldIndex = moving.slot_index

    // ── Same-panel reorder ────────────────────────────────────────────────────
    if (sourcePanel === targetPanel) {
      const displaced = srcSlots.find(s => s.slot_index === newIndex && s.id !== slotId)
      const updated = srcSlots.map(s => {
        if (s.id === slotId) return { ...s, slot_index: newIndex }
        if (displaced && s.id === displaced.id) return { ...s, slot_index: oldIndex }
        return s
      })
      setSlotsForPanel(sourcePanel, updated)
      fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId, newSlotIndex: newIndex })
      })
      if (displaced) fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId: displaced.id, newSlotIndex: oldIndex })
      })
    } else {
      // ── Cross-panel full transfer ─────────────────────────────────────────
      const displaced = tgtSlots.find(s => s.slot_index === newIndex)
      let newSrcSlots = srcSlots.filter(s => s.id !== slotId)
      if (displaced) newSrcSlots = [...newSrcSlots, { ...displaced, slot_index: oldIndex }]
      const newTgtSlots = [
        ...tgtSlots.filter(s => !displaced ? s.slot_index !== newIndex : s.id !== displaced.id),
        { ...moving, slot_index: newIndex },
      ]
      setSlotsForPanel(sourcePanel, newSrcSlots)
      setSlotsForPanel(targetPanel, newTgtSlots)

      if (sourcePanel === 'secondary' && state.secondary.type === 'ground' &&
          state.secondary.id !== '' && newSrcSlots.length === 0) {
        fetch(`https://${GetParentResourceName()}/groundStashEmpty`, {
          method: 'POST', body: JSON.stringify({ stashId: state.secondary.id }),
        })
      }

      const tgtOwner = getOwnerForPanel(targetPanel)
      fetch(`https://${GetParentResourceName()}/moveItem`, {
        method: 'POST', body: JSON.stringify({ slotId, newSlotIndex: newIndex, ...tgtOwner })
      })
      if (displaced) {
        const srcOwner = getOwnerForPanel(sourcePanel)
        fetch(`https://${GetParentResourceName()}/moveItem`, {
          method: 'POST', body: JSON.stringify({ slotId: displaced.id, newSlotIndex: oldIndex, ...srcOwner })
        })
      }
    }
  },

  equipItem: (slotId, equipKey, sourcePanel) => {
    const state = get()
    const srcSlots = sourcePanel === 'pockets' ? state.slots
      : sourcePanel === 'backpack' ? (state.backpack?.slots ?? []) : state.secondary.slots
    const moving = srcSlots.find(s => s.id === slotId)
    if (!moving) return
    const newSrcSlots   = srcSlots.filter(s => s.id !== slotId)
    const newEquipSlots = state.equipSlots.map(s => s.key === equipKey ? { ...s, slot: moving } : s)
    if (sourcePanel === 'pockets') {
      set({ slots: newSrcSlots, equipSlots: newEquipSlots })
    } else if (sourcePanel === 'backpack') {
      set(s => ({ backpack: s.backpack ? { ...s.backpack, slots: newSrcSlots } : null, equipSlots: newEquipSlots }))
    } else {
      set(s => ({ secondary: { ...s.secondary, slots: newSrcSlots }, equipSlots: newEquipSlots }))
    }
    fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId, equipKey, itemId: moving.item_id })
    })
    if (equipKey === 'backpack' && (moving.item_id === 'backpack' || moving.item_id === 'duffel_bag')) {
      const bpStashId   = `backpack_slot_${moving.id}`
      const bpMaxSlots  = moving.item_id === 'duffel_bag' ? 30 : 20
      const bpMaxWeight = moving.item_id === 'duffel_bag' ? 50 : 30
      const bpLabel     = moving.item_id === 'duffel_bag' ? 'DUFFEL BAG' : 'BACKPACK'
      get().openBackpackPanel({ type: 'stash', label: bpLabel, id: bpStashId, maxWeight: bpMaxWeight, maxSlots: bpMaxSlots, slots: [] })
      fetch(`https://${GetParentResourceName()}/openBackpack`, {
        method: 'POST', body: JSON.stringify({ bagItemId: moving.item_id, bagSlotId: moving.id })
      })
    }
  },

  unequipItem: (equipKey, targetPanel, targetIndex) => {
    const state = get()
    const equip = state.equipSlots.find(s => s.key === equipKey)
    if (!equip?.slot) return
    const slot = equip.slot
    const newEquipSlots = state.equipSlots.map(s => s.key === equipKey ? { ...s, slot: null } : s)
    const updatedSlot   = { ...slot, slot_index: targetIndex }
    const closeBackpack = equipKey === 'backpack' ? { backpack: null } : {}
    if (targetPanel === 'pockets') {
      set({ equipSlots: newEquipSlots, slots: [...state.slots, updatedSlot], ...closeBackpack })
    } else if (targetPanel === 'backpack') {
      set(s => ({ equipSlots: newEquipSlots, backpack: s.backpack ? { ...s.backpack, slots: [...s.backpack.slots, updatedSlot] } : null, ...closeBackpack }))
    } else {
      set(s => ({ equipSlots: newEquipSlots, secondary: { ...s.secondary, slots: [...s.secondary.slots, updatedSlot] }, ...closeBackpack }))
    }
    fetch(`https://${GetParentResourceName()}/unequipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: slot.id, equipKey, targetPanel, targetIndex })
    })
  },

  swapEquip: (srcKey, dstKey) => {
    const state = get()
    const srcSlot = state.equipSlots.find(s => s.key === srcKey)?.slot ?? null
    const dstSlot = state.equipSlots.find(s => s.key === dstKey)?.slot ?? null
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
    set({ equipSlots: state.equipSlots.map(s => {
      if (s.key === srcKey) return { ...s, slot: dstSlot }
      if (s.key === dstKey) return { ...s, slot: srcSlot }
      return s
    })})
    if (srcSlot) fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: srcSlot.id, equipKey: dstKey })
    })
    if (dstSlot) fetch(`https://${GetParentResourceName()}/equipItem`, {
      method: 'POST', body: JSON.stringify({ slotId: dstSlot.id, equipKey: srcKey })
    })
  },

  splitStack: (slotId, amount) => {
    const state = get()
    const inPockets  = !!state.slots.find(s => s.id === slotId)
    const panelSlots = inPockets ? state.slots : state.secondary.slots
    const slot       = panelSlots.find(s => s.id === slotId)
    if (!slot || amount <= 0 || amount >= slot.quantity) return

    const used     = panelSlots.map(s => s.slot_index)
    const newIndex = Array.from({ length: 999 }, (_, i) => i).find(i => !used.includes(i)) ?? 0
    const tempId   = -(Date.now())
    const newSlot  = { ...slot, id: tempId, quantity: amount, slot_index: newIndex }
    const reduced  = { ...slot, quantity: slot.quantity - amount }
    const updateArr = (arr: typeof state.slots) => arr.map(s => s.id === slotId ? reduced : s)

    if (inPockets) {
      set(s => ({ slots: [...updateArr(s.slots), newSlot] }))
    } else {
      set(s => ({ secondary: { ...s.secondary, slots: [...updateArr(s.secondary.slots), newSlot] } }))
    }
    fetch(`https://${GetParentResourceName()}/splitStack`, {
      method: 'POST', body: JSON.stringify({ slotId, amount })
    })
  },

  startInspect: (slot) => set({ inspectMode: true, inspectSlot: slot }),
  stopInspect:  () => set({ inspectMode: false, inspectSlot: null }),
  registerEquipMapping: (itemId, equipKey) =>
    set(s => ({ equipMappings: { ...s.equipMappings, [itemId]: equipKey } })),
}))

function GetParentResourceName(): string {
  if (typeof window !== 'undefined' && (window as any).GetParentResourceName) {
    return (window as any).GetParentResourceName()
  }
  return 'stdb-inventory'
}