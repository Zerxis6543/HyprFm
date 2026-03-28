import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { useInventoryStore } from './store'

window.addEventListener('message', (e: MessageEvent) => {
  const d     = e.data ?? {}
  const store = useInventoryStore.getState()

  switch (d.action) {

    // ── Standard inventory open (pockets only)
    case 'openInventory': {
      store.openInventory(
        d.slots    ?? [],
        d.itemDefs ?? {},
        d.maxWeight ?? 85,
        d.context  ?? undefined,
      )
      console.log('[inventory] openInventory equippedSlots:', JSON.stringify(d.equippedSlots), 'backpackData:', JSON.stringify(d.backpackData))
      if (d.equippedSlots && Array.isArray(d.equippedSlots)) {
        const equipSlots = useInventoryStore.getState().equipSlots.map(es => {
          const found = (d.equippedSlots as any[]).find((e: any) => e.equip_key === es.key)
          return found ? { ...es, slot: found } : es
        })
        useInventoryStore.setState({ equipSlots })
        // Auto-open backpack panel if backpack is equipped and data is included
        const bagSlot = d.equippedSlots.find((e: any) => e.equip_key === 'backpack')
        if (bagSlot && d.backpackData) {
          const bpData = {
            type:      'stash' as const,
            label:     d.backpackData.label     ?? 'BACKPACK',
            id:        d.backpackData.stash_id  ?? '',
            maxWeight: d.backpackData.max_weight ?? 30,
            maxSlots:  d.backpackData.max_slots  ?? 20,
            slots:     d.backpackData.slots      ?? [],
          }
          useInventoryStore.getState().openBackpackPanel(bpData)
          // Re-apply after short delay to ensure render cycle picks it up
          setTimeout(() => {
            useInventoryStore.getState().openBackpackPanel(bpData)
          }, 100)
                    
        } else if (bagSlot && !d.backpackData) {
          useInventoryStore.getState().openBackpack(bagSlot.item_id)
        } else {
          useInventoryStore.getState().closeBackpackPanel()
        }
      } else {
        useInventoryStore.getState().closeBackpackPanel()
      }
      break
    }

    // ── Open with glovebox as the right-panel inventory
    case 'openGlovebox':
      store.openInventory(
        d.slots    ?? [],
        d.itemDefs ?? {},
        85,
        {
          type:      'glovebox',
          label:     'GLOVEBOX',
          id:        d.plate ?? '',
          maxWeight: d.maxWeight ?? 10,
          maxSlots:  d.maxSlots  ?? 5,
          slots:     d.secondarySlots ?? [],
        }
      )
      break

    // ── Open with trunk (called via third-eye later)
    case 'openTrunk':
      store.openInventory(
        d.slots    ?? [],
        d.itemDefs ?? {},
        85,
        {
          type:      'trunk',
          label:     d.trunkType === 'front' ? 'FRUNK' : 'TRUNK',
          id:        d.plate ?? '',
          maxWeight: d.maxWeight ?? 0,
          maxSlots:  d.maxSlots  ?? 0,
          slots:     d.secondarySlots ?? [],
        }
      )
      break

    // ── Open with stash
    case 'openStash':
      store.openInventory(
        d.slots    ?? [],
        d.itemDefs ?? {},
        85,
        {
          type:      'stash',
          label:     d.label ?? 'STASH',
          id:        d.stashId ?? '',
          maxWeight: d.maxWeight ?? 100,
          maxSlots:  d.maxSlots  ?? 20,
          slots:     d.secondarySlots ?? [],
        }
      )
      break

    case 'updateInventory':
      store.updateSlots(d.slots ?? [])
      break

    case 'updateSecondary':
      store.updateSecondary(d.slots ?? [])
      break

    case 'openBackpackPanel':
      store.openBackpackPanel({
        type:      d.type      ?? 'stash',
        label:     d.label     ?? 'BACKPACK',
        id:        d.id        ?? '',
        maxWeight: d.maxWeight ?? 30,
        maxSlots:  d.maxSlots  ?? 20,
        slots:     d.slots     ?? [],
      })
      if (d.item_defs) useInventoryStore.setState(s => ({ itemDefs: { ...s.itemDefs, ...d.item_defs } }))
      break

    case 'syncSlots': {
      const state = useInventoryStore.getState()
      if (d.ownerType === 'player') {
        store.updateSlots(d.slots ?? [])
      } else if (state.secondary.id === d.ownerId) {
        store.updateSecondary(d.slots ?? [])
      } else if (state.backpack && state.backpack.id === d.ownerId) {
        useInventoryStore.setState(s => ({
          backpack: s.backpack ? { ...s.backpack, slots: d.slots ?? [] } : null
        }))
      }
      break
    }

      case 'applySlotDeltas': {
        const state = useInventoryStore.getState()
      
        type RawDelta = { type: string; slot?: any; slot_id?: number; owner_id?: string }
        const rawDeltas: RawDelta[] = d.deltas ?? []
      
        const added:   typeof state.slots = []
        const updated: typeof state.slots = []
        const removed: number[]            = []
      
        for (const delta of rawDeltas) {
          if (delta.type === 'added'   && delta.slot)              added.push(delta.slot)
          if (delta.type === 'updated' && delta.slot)              updated.push(delta.slot)
          if (delta.type === 'deleted' && delta.slot_id != null)   removed.push(delta.slot_id)
        }
      
        const applyToPanel = (
          slots: typeof state.slots,
          panelOwnerId:   string,
          panelOwnerType: string,
        ) => {
          // Remove deleted ids (applied to all panels — no routing hint on delete)
          let result = slots.filter(s => !removed.includes(s.id))
          // Apply updates
          result = result.map(s => {
            const u = updated.find(u => u.id === s.id)
            return u ? { ...s, ...u } : s
          })
          // Add new slots belonging to this panel
          const existingIds = new Set(result.map(s => s.id))
          for (const a of added) {
            if (!existingIds.has(a.id) &&
                a.owner_type === panelOwnerType &&
                (panelOwnerId === '' || a.owner_id === panelOwnerId)) {
              result.push(a)
            }
          }
          return result
        }
      
        const pocketOwnerId = state.slots[0]?.owner_id ?? ''
      
        const newPockets = applyToPanel(state.slots, pocketOwnerId, 'player')
      
        const newSecondarySlots = state.secondary.id !== ''
          ? applyToPanel(
              state.secondary.slots,
              state.secondary.id,
              state.secondary.type === 'glovebox' ? 'vehicle_glovebox' :
              state.secondary.type === 'trunk'    ? 'vehicle_trunk'    :
              'stash'
            )
          : state.secondary.slots
      
        const newBackpackSlots = state.backpack
          ? applyToPanel(state.backpack.slots, state.backpack.id, 'stash')
          : null
      
        useInventoryStore.setState(s => ({
          slots:     newPockets,
          secondary: { ...s.secondary, slots: newSecondarySlots },
          backpack:  s.backpack && newBackpackSlots
            ? { ...s.backpack, slots: newBackpackSlots }
            : s.backpack,
        }))
      
        break
      }

    case 'closeInventory':
      store.closeInventory()
      break

    case 'setHealth':
      store.setHealth(d.health ?? 100)
      break
      case 'cancelInspect':
      store.stopInspect()
      break

      case 'hideForInspect':
      useInventoryStore.setState({ inspectMode: true, isOpen: false })
      break

    case 'activateSlot': {
      const equipKey = d.equipKey as string
      const state    = useInventoryStore.getState()
      const equip    = state.equipSlots.find(s => s.key === equipKey)
      const itemId   = equip?.slot?.item_id ?? null
      fetch(`https://${(window as any).GetParentResourceName()}/activateSlot`, {
        method: 'POST',
        body: JSON.stringify({ equipKey, itemId }),
      })
      break
    }
    
    case 'updateStats':
      // Stats are display-only for now — extend HUD here when ready
      break
    
  }
})


createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
