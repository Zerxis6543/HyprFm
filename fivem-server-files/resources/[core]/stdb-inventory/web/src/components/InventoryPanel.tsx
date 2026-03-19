import {
  DragStartEvent,
  PointerSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import { useState, useRef, useEffect } from 'react'
import { useInventoryStore } from '../store'
import { ItemSlot } from './ItemSlot'
import { InventorySlot } from '../types'

interface Props {
  title:      string
  panel:      'pockets' | 'secondary' | 'backpack'
  secondary?: boolean
  contextOverride?: import('../store').SecondaryContext
}

export function InventoryPanel({ title, panel, secondary = false, contextOverride }: Props) {
  const { slots, secondary: ctx, itemDefs, maxWeight, maxSlots, draggingSlot, weightFlash } = useInventoryStore()
  const isFlashing = weightFlash === panel
  const [collapsed, setCollapsed] = useState(false)

  const effectiveCtx = contextOverride ?? ctx
  const activeSlots  = (secondary || panel === 'backpack') ? effectiveCtx.slots : slots
  const panelWeight2 = panel === 'backpack' ? effectiveCtx.maxWeight : (secondary ? effectiveCtx.maxWeight : maxWeight)
  const panelSlots2  = panel === 'backpack' ? effectiveCtx.maxSlots  : (secondary ? effectiveCtx.maxSlots  : maxSlots)
  const panelTitle   = contextOverride ? contextOverride.label : (secondary ? ctx.label : title)
  const panelWeight  = panelWeight2
  const panelSlots   = panelSlots2

  const [activeDropIndex, setActiveDropIndex] = useState<number | null>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const mousePos  = useRef({ x: 0, y: 0 })

  useEffect(() => {
    const track = (e: MouseEvent) => {
      mousePos.current = { x: e.clientX, y: e.clientY }
      if (draggingSlot) {
        const el     = document.elementFromPoint(e.clientX, e.clientY)
        const slotEl = el?.closest('[data-slot-index]')
        if (slotEl && slotEl.getAttribute('data-panel') === panel) {
          const idx = parseInt(slotEl.getAttribute('data-slot-index') ?? '-1')
          setActiveDropIndex(idx >= 0 ? idx : null)
        } else {
          setActiveDropIndex(null)
        }
      } else {
        setActiveDropIndex(null)
      }
    }
    window.addEventListener('mousemove', track)
    return () => window.removeEventListener('mousemove', track)
  }, [draggingSlot, panel])

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    const handler = (e: WheelEvent) => { el.scrollTop += e.deltaY }
    el.addEventListener('wheel', handler, { passive: true })
    return () => el.removeEventListener('wheel', handler)
  }, [])

  const slotMap = new Map<number, InventorySlot>()
  activeSlots.forEach((s: InventorySlot) => slotMap.set(s.slot_index, s))

  const totalWeight = activeSlots.reduce((acc: number, s: InventorySlot) => {
    const def = itemDefs[s.item_id]
    return acc + (def ? def.weight * s.quantity : 0)
  }, 0)

  const weightPct   = Math.min((totalWeight / panelWeight) * 100, 100)
  const weightColor = isFlashing ? '#f87171' : weightPct > 90 ? '#f87171' : weightPct > 70 ? '#fb923c' : 'var(--accent)'

  return (
    <div className="inv-panel">
      <div className="inv-header">
        <div className="inv-title-row">
          <span className="inv-title">{panelTitle}</span>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span className="inv-weight-badge">
              <svg width="10" height="10" viewBox="0 0 10 10" fill="none" style={{ marginRight: 3 }}>
                <path d="M5 1L6.5 3.5H9L7 5.5L7.5 8.5L5 7L2.5 8.5L3 5.5L1 3.5H3.5L5 1Z" fill="currentColor" opacity="0.6"/>
              </svg>
              {totalWeight.toFixed(2)}/{panelWeight}kg
            </span>
            <button
              onClick={() => setCollapsed(c => !c)}
              style={{
                background: 'none', border: 'none', cursor: 'pointer',
                color: 'var(--text-muted)', fontSize: 14, lineHeight: 1,
                padding: '0 2px',
                transform: collapsed ? 'rotate(-90deg)' : 'rotate(0deg)',
                transition: 'transform 0.2s ease',
              }}>∨</button>
          </div>
        </div>
        <div className="inv-weight-bar">
          <div className="inv-weight-fill" style={{
            width: `${weightPct}%`,
            background: weightColor,
            transition: isFlashing ? 'none' : 'width 0.3s ease, background 0.3s ease',
            boxShadow: isFlashing ? '0 0 8px #f87171' : undefined,
          }} />
        </div>
      </div>

      <div className="inv-grid-wrap" ref={scrollRef} style={{
        maxHeight:  collapsed ? '0px' : '420px',
        overflow:   'hidden',
        transition: 'max-height 0.25s ease',
      }}>
        <div className="inv-grid">
          {Array.from({ length: panelSlots }, (_, i) => {
            const slot = slotMap.get(i) ?? null
            const def  = slot ? (itemDefs[slot.item_id] ?? null) : null
            return (
              <ItemSlot
                key={i}
                slotIndex={i}
                slot={slot}
                itemDef={def}
                panel={panel as 'pockets' | 'secondary' | 'backpack'}
                isDropTarget={activeDropIndex === i}
              />
            )
          })}
        </div>
      </div>

      <style>{`
        .inv-panel {
          background: var(--bg-panel);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          overflow: hidden;
          backdrop-filter: blur(12px);
          width: 520px;
        }
        .inv-header { padding: 12px 14px 8px; border-bottom: 1px solid var(--border); }
        .inv-title-row {
          display: flex; align-items: center;
          justify-content: space-between; margin-bottom: 7px;
        }
        .inv-title { font-size: 15px; font-weight: 700; letter-spacing: 0.08em; color: var(--text-primary); }
        .inv-weight-badge {
          display: flex; align-items: center;
          font-family: var(--font-mono); font-size: 11px; color: var(--text-secondary);
        }
        .inv-weight-bar { height: 3px; background: rgba(255,255,255,0.06); border-radius: 2px; overflow: hidden; }
        .inv-weight-fill { height: 100%; border-radius: 2px; transition: width 0.3s ease, background 0.3s ease; }
        .inv-grid-wrap { overflow-y: scroll; overflow-x: hidden; }
        .inv-grid-wrap::-webkit-scrollbar { width: 4px; }
        .inv-grid-wrap::-webkit-scrollbar-track { background: transparent; }
        .inv-grid-wrap::-webkit-scrollbar-thumb { background: rgba(74,222,128,0.25); border-radius: 2px; }
        .inv-grid-wrap::-webkit-scrollbar-thumb:hover { background: rgba(74,222,128,0.45); }
        .inv-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; padding: 12px; }
        @keyframes slot-place {
          from { transform: scale(0.75); opacity: 0.5; }
          to   { transform: scale(1);    opacity: 1; }
        }
        .item-slot.occupied:not(.dragging) {
          animation: slot-place 0.15s ease-out;
        }
      `}</style>
    </div>
  )
}