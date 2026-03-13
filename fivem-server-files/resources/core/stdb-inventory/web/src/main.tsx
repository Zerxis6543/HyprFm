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
    case 'openInventory':
      store.openInventory(
        d.slots    ?? [],
        d.itemDefs ?? {},
        d.maxWeight ?? 85,
        d.context  ?? undefined,
      )
      break

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

    case 'closeInventory':
      store.closeInventory()
      break

    case 'setHealth':
      store.setHealth(d.health ?? 100)
      break
  }
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
