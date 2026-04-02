import { useEffect, useState, useRef, MutableRefObject } from 'react'
import { createPortal } from 'react-dom'
import {
  DndContext, DragEndEvent, DragStartEvent,
  PointerSensor, useSensor, useSensors, pointerWithin,
} from '@dnd-kit/core'
import { useInventoryStore, dragState } from './store'
import { InventoryPanel } from './components/InventoryPanel'
import { EquipmentPanel } from './components/EquipmentPanel'
import { ContextMenu } from './components/ContextMenu'
import { InventorySlot, itemIcon, EquipSlotKey } from './types'
import { InspectHint } from './components/InspectHint'

const EQUIP_ALLOWED: Record<string, string[]> = {
  backpack: ['bag'], body_armour: ['armor'], phone: ['phone'],
  parachute: ['parachute'], weapon_primary: ['weapon'], weapon_secondary: ['weapon'],
  hotkey_1: ['any'], hotkey_2: ['any'], hotkey_3: ['any'], hotkey_4: ['any'], hotkey_5: ['any'],
}
function canEquip(itemId: string, equipKey: string): boolean {
  const allowed  = EQUIP_ALLOWED[equipKey]
  if (!allowed) return false
  if (allowed.includes('any')) return true
  const mappings = useInventoryStore.getState().equipMappings
  if (mappings[itemId] === equipKey) return true
  return allowed.includes(useInventoryStore.getState().itemDefs[itemId]?.category ?? 'misc')
}

const REF_H = 1080
function useZoom() {
  const [z, setZ] = useState(() => window.innerHeight / REF_H)
  useEffect(() => {
    const update = () => setZ(window.innerHeight / REF_H)
    window.addEventListener('resize', update)
    return () => window.removeEventListener('resize', update)
  }, [])
  return z
}

function DragCursor({ slot, mousePos }: {
  slot:     InventorySlot
  mousePos: MutableRefObject<{ x: number; y: number }>
}) {
  const itemDefs = useInventoryStore(s => s.itemDefs)
  const def      = itemDefs[slot.item_id] ?? null
  const [pos, setPos] = useState({ x: mousePos.current.x, y: mousePos.current.y })
  useEffect(() => {
    const move = (e: MouseEvent) => setPos({ x: e.clientX, y: e.clientY })
    window.addEventListener('mousemove', move)
    return () => window.removeEventListener('mousemove', move)
  }, [])
  return (
    <div style={{
      position: 'fixed', left: pos.x, top: pos.y,
      transform: 'translate(-50%, -50%) scale(0.9)',
      pointerEvents: 'none', zIndex: 9999, width: 110, height: 110,
      background: 'var(--bg-panel)', border: '1px solid var(--accent)',
      borderRadius: 'var(--radius)',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      boxShadow: '0 8px 32px rgba(0,0,0,0.6), 0 0 16px var(--accent-dim)', gap: 2,
    }}>
      <img src={itemIcon(slot.item_id)} alt={slot.item_id} draggable={false}
        style={{ width: 56, height: 56, objectFit: 'contain' }}
        onError={(e) => { (e.target as HTMLImageElement).style.opacity = '0' }} />
      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--text-secondary)' }}>
        {slot.quantity}x
      </span>
      {def && (
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 8, color: 'var(--text-muted)' }}>
          {def.label.toUpperCase()}
        </span>
      )}
    </div>
  )
}

export default function App() {
  const {
    isOpen, activeTab, closeInventory, setTab,
    setDragging, draggingSlot, draggingSource,
    moveSlot, equipItem, unequipItem, swapEquip,
    backpack, inspectMode,
  } = useInventoryStore()
  const z = useZoom()

  const mousePos = useRef({ x: 0, y: 0 })
  useEffect(() => {
    const track = (e: MouseEvent) => { mousePos.current = { x: e.clientX, y: e.clientY } }
    window.addEventListener('mousemove', track)
    return () => window.removeEventListener('mousemove', track)
  }, [])

  // Track Ctrl modifier at the window level so we never have to touch dnd-kit's
  // listeners in ItemSlot. Fires before dnd-kit's sensor, so dragState is set
  // by the time handleDragStart runs.
  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      if (e.button === 0 && e.ctrlKey) {
        dragState.modifier = 'half'
      } else if (e.button === 0 && e.shiftKey) {
        // Shift+left is handled as a click in ItemSlot — don't set a modifier
        dragState.modifier = null
      } else {
        dragState.modifier = null
      }
    }
    window.addEventListener('pointerdown', onDown, { capture: true })
    return () => window.removeEventListener('pointerdown', onDown, { capture: true })
  }, [])

  // Single PointerSensor — right-click drag is removed per spec
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } })
  )

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!isOpen) return
      if (e.key === 'Escape') closeInventory()
      if (e.key === 'e' || e.key === 'E') setTab(activeTab === 'inventories' ? 'utility' : 'inventories')
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [isOpen, closeInventory, activeTab, setTab])

  const [rendered, setRendered] = useState(false)
  const [opacity, setOpacity]   = useState(0)
  useEffect(() => {
    if (isOpen) {
      setRendered(true)
      requestAnimationFrame(() => requestAnimationFrame(() => setOpacity(1)))
    } else {
      setOpacity(0)
      const t = setTimeout(() => setRendered(false), 220)
      return () => clearTimeout(t)
    }
  }, [isOpen])

  if (!rendered && !inspectMode) return null

  const PANEL_W   = 520
  const panelZoom = { zoom: z } as React.CSSProperties

  function handleDragStart(e: DragStartEvent) {
    const id    = String(e.active.id)
    const state = useInventoryStore.getState()
    if (id.startsWith('slot-')) {
      const slotId        = parseInt(id.replace('slot-', ''))
      const fromPockets   = state.slots.find(s => s.id === slotId)
      const fromSecondary = state.secondary.slots.find(s => s.id === slotId)
      const fromBackpack  = state.backpack?.slots.find(s => s.id === slotId)
      if (fromPockets)        setDragging(fromPockets,   'pockets')
      else if (fromBackpack)  setDragging(fromBackpack,  'backpack' as any)
      else if (fromSecondary) setDragging(fromSecondary, 'secondary')
    } else if (id.startsWith('equip-')) {
      const equipKey = id.replace('equip-', '') as EquipSlotKey
      const equip    = state.equipSlots.find(s => s.key === equipKey)
      if (equip?.slot) setDragging(equip.slot, 'pockets')
    }
  }

  function handleDragEnd(_e: DragEndEvent) {
    const source      = draggingSource
    const slot        = draggingSlot
    const activeId    = String(_e.active.id)
    const isEquipSrc  = activeId.startsWith('equip-')
    const equipSrcKey = isEquipSrc ? activeId.replace('equip-', '') as EquipSlotKey : null

    // Read then reset modifier state
    const modifier = dragState.modifier
    dragState.modifier = null

    setDragging(null, null)
    if (!slot) return

    const el = document.elementFromPoint(mousePos.current.x, mousePos.current.y)

    // Equip → Equip swap
    if (isEquipSrc && equipSrcKey) {
      const equipEl = el?.closest('[data-equip-key]')
      if (equipEl) {
        const targetKey = equipEl.getAttribute('data-equip-key') as EquipSlotKey
        if (targetKey && targetKey !== equipSrcKey) swapEquip(equipSrcKey, targetKey)
        return
      }
      const slotEl = el?.closest('[data-slot-index]')
      if (slotEl) {
        const toIndex     = parseInt(slotEl.getAttribute('data-slot-index') ?? '-1')
        const targetPanel = (slotEl.getAttribute('data-panel') ?? 'pockets') as 'pockets' | 'secondary' | 'backpack'
        if (toIndex >= 0) unequipItem(equipSrcKey, targetPanel, toIndex)
      }
      return
    }

    // Inventory → Inventory slot
    const slotEl = el?.closest('[data-slot-index]')
    if (slotEl) {
      const toIndex     = parseInt(slotEl.getAttribute('data-slot-index') ?? '-1')
      const targetPanel = (slotEl.getAttribute('data-panel') ?? 'pockets') as 'pockets' | 'secondary' | 'backpack'
      if (toIndex >= 0 && source) {
        // Ctrl+drag = half-stack partial move; no modifier = full move
        const effectiveQty = modifier === 'half'
          ? Math.max(1, Math.ceil(slot.quantity / 2))
          : undefined
        moveSlot(slot.id, toIndex, source, targetPanel, effectiveQty)
      }
      return
    }

    // Inventory → Equip slot
    const equipEl = el?.closest('[data-equip-key]')
    if (equipEl && source) {
      const equipKey = equipEl.getAttribute('data-equip-key') as EquipSlotKey | null
      if (equipKey && canEquip(slot.item_id, equipKey)) {
        equipItem(slot.id, equipKey, source as 'pockets' | 'secondary' | 'backpack')
      }
    }
  }

  return (
    <div style={{ opacity, transition: 'opacity 0.2s ease', pointerEvents: isOpen ? 'all' : 'none' }}>
    <DndContext
      sensors={sensors}
      collisionDetection={pointerWithin}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      autoScroll={false}
    >
      <div style={{ position: 'fixed', inset: 0, pointerEvents: 'none' }}>

        <div style={{
          position: 'fixed', top: 20, right: 20, ...panelZoom,
          pointerEvents: 'all', zIndex: 200,
          display: inspectMode ? 'none' : 'flex', gap: 2,
          transformOrigin: 'top right',
        }}>
          <button className={`tab-btn ${activeTab === 'inventories' ? 'active' : ''}`}
            onClick={() => setTab('inventories')}>
            <span className="tab-icon">⊞</span> INVENTORIES
          </button>
          <button className={`tab-btn ${activeTab === 'utility' ? 'active' : ''}`}
            onClick={() => setTab('utility')}>
            UTILITY <span className="tab-key">E</span>
          </button>
        </div>

        {/* Left column — full-height flex container centres panels vertically */}
        <div style={{
          position: 'fixed', top: 0, bottom: 0, left: 20,
          display: inspectMode ? 'none' : 'flex',
          alignItems: 'center',
          pointerEvents: 'none',   // container is click-through
          zIndex: 10,
        }}>
          <div style={{
            ...panelZoom,
            transform: 'perspective(1200px) rotateY(6deg)',
            transformOrigin: 'left center',
            pointerEvents: 'all',
            display: 'flex', flexDirection: 'column', gap: 8,
            width: PANEL_W,
          }}>
            <InventoryPanel title="POCKETS" panel="pockets" />
            {backpack && (
              <div style={{ animation: 'slideDown 0.2s ease' }}>
                <InventoryPanel title={backpack.label} panel="backpack" secondary contextOverride={backpack} />
              </div>
            )}
          </div>
        </div>

        {/* Right column — same centering approach */}
        <div style={{
          position: 'fixed', top: 0, bottom: 0, right: 20,
          display: inspectMode ? 'none' : 'flex',
          alignItems: 'center',
          pointerEvents: 'none',
          zIndex: 10,
        }}>
          <div style={{
            ...panelZoom,
            transform: 'perspective(1200px) rotateY(-6deg)',
            transformOrigin: 'right center',
            pointerEvents: 'all',
            width: PANEL_W,
          }}>
            {activeTab === 'inventories' && <InventoryPanel title="GROUND" panel="secondary" secondary />}
            {activeTab === 'utility'     && <EquipmentPanel />}
          </div>
        </div>

        <style>{`
          * { box-sizing: border-box; }
          .tab-btn {
            padding: 7px 16px; background: rgba(8,10,14,0.88);
            border: 1px solid var(--border); color: var(--text-secondary);
            font-family: var(--font-ui); font-size: 11px; font-weight: 700;
            letter-spacing: 0.1em; cursor: pointer; border-radius: var(--radius);
            transition: all var(--transition); display: flex; align-items: center; gap: 6px;
            backdrop-filter: blur(12px); white-space: nowrap;
          }
          .tab-btn:hover  { color: var(--text-primary); border-color: rgba(255,255,255,0.15); }
          .tab-btn.active { background: var(--accent); color: #000; border-color: var(--accent); }
          .tab-icon { font-size: 10px; opacity: 0.7; }
          .tab-key  { background: rgba(0,0,0,0.3); padding: 1px 6px; border-radius: 2px; font-size: 9px; font-family: var(--font-mono); }
          @keyframes slideDown {
            from { opacity: 0; transform: translateY(-12px); }
            to   { opacity: 1; transform: translateY(0); }
          }
        `}</style>
      </div>

      {draggingSlot && createPortal(
        <DragCursor slot={draggingSlot} mousePos={mousePos} />,
        document.body
      )}
    </DndContext>
    {createPortal(<><ContextMenu /><InspectHint /></>, document.body)}
    </div>
  )
}