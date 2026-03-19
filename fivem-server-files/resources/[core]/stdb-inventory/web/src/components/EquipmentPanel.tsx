import { useDraggable } from '@dnd-kit/core'
import { useInventoryStore } from '../store'
import { EquipSlotKey, itemIcon } from '../types'

function zoneColor(hp: number): string {
  const h = Math.max(0, Math.min(100, hp))
  if (h >= 60) {
    const t = (100 - h) / 40
    return `rgb(${Math.round(74+176*t)},${Math.round(222-18*t)},${Math.round(128-107*t)})`
  }
  const t = (60 - h) / 60
  return `rgb(${Math.round(250-2*t)},${Math.round(204-91*t)},${Math.round(21+92*t)})`
}

// Convert rgb(...) to rgba(..., opacity)
function withAlpha(c: string, a: number) {
  return c.replace('rgb(', 'rgba(').replace(')', `,${a})`)
}

function BodyImage({ health }: { health: number }) {
  const c = zoneColor(health)
  return (
    <div style={{
      width: '100%',
      height: '100%',
      // CSS mask: image defines the shape, background provides the color
      WebkitMaskImage: 'url(body-silhouette.png)',
      WebkitMaskSize: 'contain',
      WebkitMaskRepeat: 'no-repeat',
      WebkitMaskPosition: 'center',
      maskImage: 'url(body-silhouette.png)',
      maskSize: 'contain',
      maskRepeat: 'no-repeat',
      maskPosition: 'center',
      backgroundColor: c,
      filter: `drop-shadow(0 0 12px ${withAlpha(c, 0.55)})`,
      transition: 'background-color 0.5s ease, filter 0.5s ease',
    }}/>
  )
}

function ESlot({ slotKey, label }: { slotKey: EquipSlotKey; label: string }) {
  const equipSlots = useInventoryStore(s => s.equipSlots)
  const itemDefs   = useInventoryStore(s => s.itemDefs)
  const equip = equipSlots.find(s => s.key === slotKey)
  const slot  = equip?.slot ?? null
  const def   = slot ? itemDefs[slot.item_id] : null

  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id:       `equip-${slotKey}`,
    disabled: !slot,
  })

  return (
    <div className="e-slot-wrap">
      <div className="e-slot-label">{label}</div>
      <div
        ref={setNodeRef}
        data-equip-key={slotKey}
        className={`e-slot ${slot ? 'occupied' : ''} ${isDragging ? 'dragging' : ''} ${slot && (slot.item_id === 'backpack' || slot.item_id === 'duffel_bag') ? 'bag-slot' : ''}`}
        style={{ opacity: isDragging ? 0.3 : 1 }}
        {...(slot ? { ...attributes, ...listeners } : {})}
      >
        {slot && (slot.item_id === 'backpack' || slot.item_id === 'duffel_bag') && (
          <button
            onPointerDown={e => e.stopPropagation()}
            onClick={e => {
              e.stopPropagation()
              useInventoryStore.getState().openBackpack(slot.item_id)
            }}
            style={{
              position: 'absolute', bottom: 4, left: '50%',
              transform: 'translateX(-50%)',
              background: 'rgba(74,222,128,0.15)',
              border: '1px solid var(--accent)',
              borderRadius: 3, color: 'var(--accent)',
              fontSize: 7, fontWeight: 700,
              letterSpacing: '0.08em',
              padding: '2px 6px', cursor: 'pointer',
              zIndex: 10, whiteSpace: 'nowrap',
            }}
          >
            OPEN
          </button>
        )}
        {!slot && (
          <div className="e-slot-empty-hint">{label[0]}</div>
        )}
        {slot && def && (<>
          <div className="e-qty">{slot.quantity}x</div>
          <div className="e-icon">
            <img src={itemIcon(slot.item_id)} alt={def.label} draggable={false}
              onError={(e) => { (e.target as HTMLImageElement).style.opacity = '0' }}/>
          </div>
          <div className="e-name">{def.label.toUpperCase()}</div>
          <div className="e-weight">{(def.weight * slot.quantity).toFixed(0)}g</div>
        </>)}
      </div>
    </div>
  )
}

export function EquipmentPanel() {
  const health = useInventoryStore(s => s.health)
  const c = zoneColor(health)

  return (
    <div className="equip-panel">

      {/* TOP: left slots | body | right slots */}
      <div className="e-top">

        {/* Left: backpack, armour, phone */}
        <div className="e-col">
          <ESlot slotKey="backpack"    label="BACKPACK"/>
          <ESlot slotKey="body_armour" label="BODY ARMOUR"/>
          <ESlot slotKey="phone"       label="PHONE"/>
        </div>

        {/* Centre: body image + HP */}
        <div className="e-center">
          <div className="e-figure">
            <BodyImage health={health}/>
          </div>
          <div className="e-hp" style={{ color: c }}>
            {health}<span className="e-hp-unit">HP</span>
          </div>
        </div>

        {/* Right: parachute, weapon 1, weapon 2 */}
        <div className="e-col">
          <ESlot slotKey="parachute"        label="PARACHUTE"/>
          <ESlot slotKey="weapon_primary"   label="WEAPON 1"/>
          <ESlot slotKey="weapon_secondary" label="WEAPON 2"/>
        </div>

      </div>

      {/* BOTTOM: hotkey row */}
      <div className="e-hotkeys">
        <ESlot slotKey="hotkey_1" label="HOTKEY 1"/>
        <ESlot slotKey="hotkey_2" label="HOTKEY 2"/>
        <ESlot slotKey="hotkey_3" label="HOTKEY 3"/>
      </div>

      <style>{`
        .equip-panel {
          display: flex;
          flex-direction: column;
          gap: 10px;
          padding: 14px;
          background: var(--bg-panel);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          backdrop-filter: blur(12px);
          width: 520px;
        }

        .e-top {
          display: grid;
          grid-template-columns: 130px 1fr 130px;
          gap: 10px;
          align-items: center;
        }

        .e-center {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 6px;
        }
        .e-figure {
          width: 120px;
          height: 230px;
        }
        .e-hp {
          font-family: var(--font-mono);
          font-size: 15px; font-weight: 700; letter-spacing: 0.12em;
          transition: color 0.5s ease;
        }
        .e-hp-unit { font-size: 0.6em; opacity: 0.55; margin-left: 2px; }

        .e-col { display: flex; flex-direction: column; gap: 10px; }

        .e-hotkeys {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 8px;
          border-top: 1px solid var(--border);
          padding-top: 10px;
        }

        /* Slot wrapper */
        .e-slot-wrap { display: flex; flex-direction: column; gap: 0; }

        /* Label — pill style, clearly readable */
        .e-slot-label {
          display: flex;
          align-items: center;
          font-size: 9px;
          font-weight: 800;
          letter-spacing: 0.1em;
          color: var(--text-primary);
          background: rgba(255,255,255,0.06);
          border: 1px solid var(--border);
          border-bottom: none;
          border-radius: 3px 3px 0 0;
          padding: 3px 6px;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .e-slot-icon-char { font-size: 10px; line-height: 1; }

        /* Slot box */
        .e-slot {
          width: 100%; aspect-ratio: 1;
          background: var(--bg-slot);
          border: 1px solid var(--border);
          border-radius: 0 0 var(--radius) var(--radius);
          display: flex; flex-direction: column;
          align-items: center; justify-content: center;
          position: relative; overflow: hidden;
          transition: border-color var(--transition);
        }
        .e-slot.occupied { border-color: rgba(74,222,128,0.35); }
        .e-slot.bag-slot { cursor: pointer; }
        .e-slot.bag-slot:hover::after {
          content: 'DOUBLE-CLICK TO OPEN';
          position: absolute; bottom: -18px; left: 50%; transform: translateX(-50%);
          font-size: 7px; color: var(--accent); white-space: nowrap; pointer-events: none;
        }
          
        .e-slot.dragging { opacity: 0.3; border-color: var(--accent); }
        .e-slot.occupied:hover { border-color: rgba(74,222,128,0.6); background: rgba(74,222,128,0.05); }
        .e-slot-empty-hint {
          font-size: 18px; font-weight: 900;
          color: rgba(255,255,255,0.04);
          font-family: var(--font-mono);
          letter-spacing: 0;
        }
        .e-qty {
          position: absolute; top: 4px; left: 5px;
          font-family: var(--font-mono); font-size: 9px; color: var(--text-muted);
        }
        .e-icon { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; }
        .e-icon img { width: 100%; height: 100%; object-fit: contain; filter: drop-shadow(0 0 5px rgba(74,222,128,0.25)); }
        .e-name {
          font-size: 8px; font-weight: 600; letter-spacing: 0.05em;
          color: var(--text-secondary); text-align: center;
          padding: 0 4px; margin-top: 2px;
        }
        .e-weight {
          position: absolute; bottom: 4px; right: 5px;
          font-family: var(--font-mono); font-size: 7px; color: var(--text-muted);
        }
        .e-hotkeys .e-icon { width: 30px; height: 30px; }
      `}</style>
    </div>
  )
}