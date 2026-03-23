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
