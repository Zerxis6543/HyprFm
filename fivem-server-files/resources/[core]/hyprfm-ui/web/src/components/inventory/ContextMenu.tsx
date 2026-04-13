import { useEffect, useRef, useState } from 'react'
import { useInventoryStore } from '../../store'
import { itemIcon } from '../../types'

function GetParentResourceName(): string {
  if (typeof window !== 'undefined' && (window as any).GetParentResourceName) {
    return (window as any).GetParentResourceName()
  }
  return 'hyprfm-ui'
}

function optimisticConsume(slotId: number, consumeQty: number) {
  const state = useInventoryStore.getState()

  const applyToArr = (arr: typeof state.slots) => {
    const slot = arr.find(s => s.id === slotId)
    if (!slot) return arr
    if (slot.quantity <= consumeQty) return arr.filter(s => s.id !== slotId)
    return arr.map(s => s.id === slotId ? { ...s, quantity: s.quantity - consumeQty } : s)
  }

  const inPockets   = state.slots.some(s => s.id === slotId)
  const inSecondary = state.secondary.slots.some(s => s.id === slotId)
  const inBackpack  = state.backpack?.slots.some(s => s.id === slotId)

  if (inPockets)   useInventoryStore.setState({ slots: applyToArr(state.slots) })
  if (inSecondary) useInventoryStore.setState(s => ({ secondary: { ...s.secondary, slots: applyToArr(s.secondary.slots) } }))
  if (inBackpack)  useInventoryStore.setState(s => s.backpack
    ? { backpack: { ...s.backpack, slots: applyToArr(s.backpack.slots) } }
    : {}
  )
}

export function ContextMenu() {
  const { contextMenu, slots, secondary, itemDefs, hideContext, splitStack } = useInventoryStore()
  const backpack               = useInventoryStore(s => s.backpack)
  const contextMenuInitialSplit = useInventoryStore(s => s.contextMenuInitialSplit)

  const ref = useRef<HTMLDivElement>(null)
  const [dropQty,     setDropQty]     = useState<number | null>(null)
  const [inspecting,  setInspecting]  = useState(false)
  const [splitting,   setSplitting]   = useState(false)
  const [splitAmt,    setSplitAmt]    = useState(1)

  useEffect(() => {
    if (!contextMenu) {
      setDropQty(null); setInspecting(false); setSplitting(false); setSplitAmt(1)
    } else if (contextMenuInitialSplit) {
      setSplitting(true); setSplitAmt(1); setDropQty(null); setInspecting(false)
    }
  }, [contextMenu, contextMenuInitialSplit])

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) hideContext()
    }
    window.addEventListener('mousedown', handler)
    return () => window.removeEventListener('mousedown', handler)
  }, [hideContext])

  if (!contextMenu) return null

  const slot    = slots.find(s => s.id === contextMenu.slotId)
             ?? secondary.slots.find(s => s.id === contextMenu.slotId)
             ?? backpack?.slots.find(s => s.id === contextMenu.slotId)
  const itemDef = slot ? itemDefs[slot.item_id] : null
  if (!slot || !itemDef) return null

  const weaponMeta = (() => {
    try { return slot.metadata ? JSON.parse(slot.metadata) : null } catch { return null }
  })()
  const isWeapon = itemDef.category === 'weapon' && weaponMeta?.serial

  const durabilityColor = (d: number) => {
    if (d >= 75) return '#4ade80'
    if (d >= 50) return '#facc15'
    if (d >= 25) return '#fb923c'
    return '#f87171'
  }

  const menuH = inspecting ? 220 : (dropQty !== null ? 180 : (itemDef.usable ? 180 : 150))
  const x = Math.min(contextMenu.x, window.innerWidth  - 200)
  const y = Math.min(contextMenu.y, window.innerHeight - menuH)

  const doDrop = (dropAmount: number) => {
    optimisticConsume(slot.id, dropAmount)
    fetch(`https://${GetParentResourceName()}/dropItem`, {
      method: 'POST',
      body: JSON.stringify({ slotId: slot.id, quantity: dropAmount, itemId: slot.item_id, propModel: itemDef.prop_model ?? '' }),
    })
    hideContext()
  }

  const doUse = () => {
    optimisticConsume(slot.id, 1)
    fetch(`https://${GetParentResourceName()}/useItem`, {
      method: 'POST',
      body: JSON.stringify({ slotId: slot.id }),
    })
    hideContext()
  }

  return (
    <div ref={ref} className="ctx-menu" style={{ left: x, top: y }}
      onPointerDown={e => e.stopPropagation()}
    >
      {/* Header */}
      <div className="ctx-header">
        <div className="ctx-item-icon">
          <img src={itemIcon(slot.item_id)} alt={itemDef.label} draggable={false}
            onError={(e) => { (e.target as HTMLImageElement).style.opacity = '0' }} />
        </div>
        <div style={{ flex: 1 }}>
          <div className="ctx-name">{itemDef.label.toUpperCase()}</div>
          <div className="ctx-meta">
            {slot.quantity}x &middot; {(itemDef.weight * slot.quantity).toFixed(2)}kg
            &nbsp;&middot;&nbsp;<span style={{ color: 'var(--accent)', textTransform: 'uppercase' }}>{itemDef.category}</span>
          </div>
          {isWeapon && (
            <div className="ctx-meta" style={{ marginTop: 2, color: 'var(--text-muted)', letterSpacing: '0.06em' }}>
              S/N: <span style={{ color: 'var(--text-secondary)' }}>{weaponMeta.serial}</span>
            </div>
          )}
        </div>
      </div>

      {/* Weapon metadata */}
      {isWeapon && (<>
        <div className="ctx-divider" />
        <div style={{ padding: '6px 12px 4px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 4 }}>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--text-muted)' }}>
              MAG {weaponMeta.mag_ammo ?? 0}/{weaponMeta.mag_capacity ?? 0}
            </span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--text-muted)' }}>
              STORED {weaponMeta.stored_ammo ?? 0}/{weaponMeta.stored_capacity ?? 0}
            </span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--text-muted)' }}>DURABILITY</span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: durabilityColor(weaponMeta.durability ?? 100) }}>
              {weaponMeta.durability ?? 100}%
            </span>
          </div>
          <div style={{ height: 3, background: 'rgba(255,255,255,0.06)', borderRadius: 2, overflow: 'hidden' }}>
            <div style={{
              height: '100%', width: `${weaponMeta.durability ?? 100}%`,
              background: durabilityColor(weaponMeta.durability ?? 100),
              borderRadius: 2, transition: 'width 0.3s ease, background 0.3s ease',
            }} />
          </div>
        </div>
      </>)}

      <div className="ctx-divider" />

      {/* Inspect panel */}
      {inspecting && (
        <div className="ctx-inspect">
          <div className="ctx-inspect-row"><span>Weight</span><span>{itemDef.weight}kg each</span></div>
          <div className="ctx-inspect-row"><span>Stackable</span><span>{itemDef.stackable ? 'Yes' : 'No'}</span></div>
          <div className="ctx-inspect-row"><span>Usable</span><span>{itemDef.usable ? 'Yes' : 'No'}</span></div>
          <div className="ctx-inspect-row"><span>Max stack</span><span>{itemDef.max_stack}</span></div>
          <div className="ctx-inspect-row"><span>Category</span><span>{itemDef.category}</span></div>
          <div className="ctx-divider" style={{ margin: '4px 0' }} />
          <button className="ctx-action" onClick={() => setInspecting(false)}>← BACK</button>
        </div>
      )}

      {/* Split stack */}
      {!inspecting && splitting && (
        <div className="ctx-qty-wrap">
          <div className="ctx-qty-label">SPLIT STACK — KEEP {slot.quantity - splitAmt} · SPLIT OFF {splitAmt}</div>
          <div className="ctx-qty-row">
            <button className="ctx-qty-btn" onClick={() => setSplitAmt(Math.max(1, splitAmt - 1))}>−</button>
            <input className="ctx-qty-input" type="range" min={1} max={slot.quantity - 1} value={splitAmt}
              onChange={e => setSplitAmt(parseInt(e.target.value))}
              style={{ flex: 1, accentColor: 'var(--accent)' }} />
            <button className="ctx-qty-btn" onClick={() => setSplitAmt(Math.min(slot.quantity - 1, splitAmt + 1))}>+</button>
          </div>
          <div style={{ display: 'flex', gap: 4, padding: '4px 8px 8px' }}>
            <button className="ctx-action" style={{ color: '#facc15', flex: 1 }} onClick={() => {
              splitStack(slot.id, splitAmt); hideContext()
            }}>CONFIRM SPLIT</button>
            <button className="ctx-action" style={{ flex: 1 }} onClick={() => setSplitting(false)}>CANCEL</button>
          </div>
        </div>
      )}

      {/* Drop quantity picker */}
      {!inspecting && dropQty !== null && (
        <div className="ctx-qty-wrap">
          <div className="ctx-qty-label">DROP QUANTITY</div>
          <div className="ctx-qty-row">
            <button className="ctx-qty-btn" onClick={() => setDropQty(Math.max(1, dropQty - 1))}>−</button>
            <input className="ctx-qty-input" type="number" min={1} max={slot.quantity} value={dropQty}
              onChange={e => setDropQty(Math.min(slot.quantity, Math.max(1, parseInt(e.target.value) || 1)))} />
            <button className="ctx-qty-btn" onClick={() => setDropQty(Math.min(slot.quantity, dropQty + 1))}>+</button>
          </div>
          <div style={{ display: 'flex', gap: 4, padding: '4px 8px 8px' }}>
            <button className="ctx-action" style={{ color: '#f87171', flex: 1 }}
              onClick={() => doDrop(dropQty)}>CONFIRM DROP</button>
            <button className="ctx-action" style={{ flex: 1 }} onClick={() => setDropQty(null)}>CANCEL</button>
          </div>
        </div>
      )}

      {/* Main actions */}
      {!inspecting && dropQty === null && !splitting && (<>
        {itemDef.usable && (
          <button className="ctx-action" style={{ color: 'var(--accent)' }} onClick={doUse}>USE</button>
        )}
        <button className="ctx-action" onClick={() => {
          useInventoryStore.getState().startInspect(slot)
          fetch(`https://${GetParentResourceName()}/inspectItem`, {
            method: 'POST',
            body: JSON.stringify({ slotId: slot.id, itemId: slot.item_id }),
          })
          hideContext()
        }}>INSPECT</button>
        {slot.quantity > 1 && !splitting && (
          <button className="ctx-action" style={{ color: '#facc15' }} onClick={() => {
            setSplitting(true); setSplitAmt(Math.floor(slot.quantity / 2))
          }}>SPLIT</button>
        )}
        <button className="ctx-action" style={{ color: '#f87171' }} onClick={() => {
          if (slot.quantity === 1) doDrop(1)
          else setDropQty(slot.quantity)
        }}>DROP</button>
      </>)}

      <style>{`
        .ctx-menu {
          position: fixed; z-index: 999999;
          background: rgba(8,10,14,0.97); border: 1px solid var(--border);
          border-radius: var(--radius); min-width: 200px; overflow: hidden;
          box-shadow: 0 8px 32px rgba(0,0,0,0.8); animation: ctxIn 0.08s ease;
        }
        @keyframes ctxIn {
          from { opacity: 0; transform: scale(0.96) translateY(-4px); }
          to   { opacity: 1; transform: scale(1) translateY(0); }
        }
        .ctx-header { display: flex; align-items: center; gap: 10px; padding: 10px 12px; }
        .ctx-item-icon {
          width: 36px; height: 36px; flex-shrink: 0;
          display: flex; align-items: center; justify-content: center;
          background: var(--bg-slot); border: 1px solid var(--border); border-radius: var(--radius);
        }
        .ctx-item-icon img { width: 26px; height: 26px; object-fit: contain; }
        .ctx-name { font-size: 11px; font-weight: 700; letter-spacing: 0.08em; color: var(--text-primary); }
        .ctx-meta { font-family: var(--font-mono); font-size: 9px; color: var(--text-muted); margin-top: 2px; }
        .ctx-divider { height: 1px; background: var(--border); }
        .ctx-action {
          display: block; width: 100%; padding: 9px 12px;
          background: none; border: none; text-align: left;
          font-family: var(--font-ui); font-size: 11px; font-weight: 600;
          letter-spacing: 0.08em; color: var(--text-secondary);
          cursor: pointer; transition: background var(--transition);
        }
        .ctx-action:hover { background: rgba(255,255,255,0.05); color: var(--text-primary); }
        .ctx-inspect { padding: 6px 0; }
        .ctx-inspect-row {
          display: flex; justify-content: space-between; padding: 4px 12px;
          font-family: var(--font-mono); font-size: 9px; color: var(--text-secondary);
        }
        .ctx-inspect-row span:last-child { color: var(--text-primary); }
        .ctx-qty-wrap { padding: 8px; }
        .ctx-qty-label { font-size: 9px; font-weight: 700; letter-spacing: 0.1em; color: var(--text-muted); padding: 0 4px 6px; }
        .ctx-qty-row { display: flex; align-items: center; gap: 4px; padding: 0 4px 6px; }
        .ctx-qty-btn {
          width: 28px; height: 28px; background: var(--bg-slot);
          border: 1px solid var(--border); border-radius: var(--radius);
          color: var(--text-primary); font-size: 14px; cursor: pointer;
          display: flex; align-items: center; justify-content: center;
        }
        .ctx-qty-btn:hover { border-color: var(--accent); }
        .ctx-qty-input {
          flex: 1; height: 28px; text-align: center;
          background: var(--bg-slot); border: 1px solid var(--border);
          border-radius: var(--radius); color: var(--text-primary);
          font-family: var(--font-mono); font-size: 11px;
        }
        .ctx-qty-input::-webkit-inner-spin-button { -webkit-appearance: none; }
      `}</style>
    </div>
  )
}