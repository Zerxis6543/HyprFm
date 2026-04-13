import { useDraggable } from '@dnd-kit/core'
import { useRef } from 'react'
import { useInventoryStore } from '../../store'
import { EquipSlotKey, itemIcon } from '../../types'

function zoneColor(hp: number): string {
  const h = Math.max(0, Math.min(100, hp))
  if (h >= 60) {
    const t = (100 - h) / 40
    return `rgb(${Math.round(74+176*t)},${Math.round(222-18*t)},${Math.round(128-107*t)})`
  }
  const t = (60 - h) / 60
  return `rgb(${Math.round(250-2*t)},${Math.round(204-91*t)},${Math.round(21+92*t)})`
}
function withAlpha(c: string, a: number) {
  return c.replace('rgb(', 'rgba(').replace(')', `,${a})`)
}

function BodyFigure({ health }: { health: number }){
  const glow = withAlpha(zoneColor(health), 0.28)
  return (
    <svg
      viewBox="0 0 200 223"
      xmlns="http://www.w3.org/2000/svg"
      style={{
        width: '100%', height: '100%',
        overflow: 'visible',
        filter: `drop-shadow(0 0 8px ${glow})`,
      }}
    >
      <defs>
        <filter id="recolor-to-accent" colorInterpolationFilters="sRGB">
          <feColorMatrix type="matrix" values="
            0 0 0 0 0.290
            0 0 0 0 0.871
            0 0 0 0 0.502
            0 0 0 1 0
          "/>
        </filter>
      </defs>
      <image href="./body-figure.png" x={0} y={0} width={200} height={223}
        filter="url(#recolor-to-accent)" opacity={0.10} preserveAspectRatio="none"/>
      <image href="./body-figure.png" x={0} y={0} width={200} height={223}
        filter="url(#recolor-to-accent)" opacity={0.88} preserveAspectRatio="none"/>
    </svg>
  )
}

function ESlot({ slotKey, label }: { slotKey: EquipSlotKey; label: string }) {
  const equipSlots  = useInventoryStore(s => s.equipSlots)
  const itemDefs    = useInventoryStore(s => s.itemDefs)
  const equip       = equipSlots.find(s => s.key === slotKey)
  const slot        = equip?.slot ?? null
  const def         = slot ? itemDefs[slot.item_id] : null
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `equip-${slotKey}`, disabled: !slot,
  })
  const showContext = useInventoryStore(s => s.showContext)
  const dragStart   = useRef<{ x: number; y: number } | null>(null)
  const didDrag     = useRef(false)

  return (
    <div className="e-slot-wrap">
      <div className="e-slot-label">{label}</div>
      <div
        ref={setNodeRef} data-equip-key={slotKey}
        className={`e-slot ${slot?'occupied':''} ${isDragging?'dragging':''}`}
        style={{ opacity: isDragging ? 0.3 : 1 }}
        onPointerDown={e=>{ dragStart.current={x:e.clientX,y:e.clientY}; didDrag.current=false }}
        onPointerMove={e=>{
          if(dragStart.current){
            const dx=e.clientX-dragStart.current.x, dy=e.clientY-dragStart.current.y
            if(Math.sqrt(dx*dx+dy*dy)>6) didDrag.current=true
          }
        }}
        onContextMenu={slot?e=>{
          e.preventDefault(); e.stopPropagation()
          if(didDrag.current){didDrag.current=false;return}
          showContext(slot.id,e.clientX,e.clientY)
        }:undefined}
        {...(slot?{...attributes,...listeners}:{})}
      >
        {!slot && <div className="e-slot-empty-hint">{label[0]}</div>}
        {slot && def && (<>
          <div className="e-qty">{slot.quantity}x</div>
          <div className="e-icon">
            <img src={itemIcon(slot.item_id)} alt={def.label} draggable={false}
              onError={e=>{(e.target as HTMLImageElement).style.opacity='0'}}/>
          </div>
          <div className="e-name">{def.label.toUpperCase()}</div>
          <div className="e-weight">{(def.weight*slot.quantity).toFixed(0)}g</div>
        </>)}
      </div>
    </div>
  )
}

export function EquipmentPanel() {
  const health = useInventoryStore(s => s.health)
  const c      = zoneColor(health)

  return (
    <div className="equip-panel">
      <div className="e-top">
        <div className="e-col">
          <ESlot slotKey="backpack"    label="BACKPACK"/>
          <ESlot slotKey="body_armour" label="BODY ARMOUR"/>
          <ESlot slotKey="phone"       label="PHONE"/>
        </div>
        <div className="e-center">
          <div className="e-figure">
            <BodyFigure health={health}/>
          </div>
          <div className="e-hp" style={{ color: c }}>
            {health}<span className="e-hp-unit">HP</span>
          </div>
        </div>
        <div className="e-col">
          <ESlot slotKey="parachute"        label="PARACHUTE"/>
          <ESlot slotKey="weapon_primary"   label="WEAPON 1"/>
          <ESlot slotKey="weapon_secondary" label="WEAPON 2"/>
        </div>
      </div>

      <div className="e-hotkeys">
        <ESlot slotKey="hotkey_1" label="HOTKEY 1"/>
        <ESlot slotKey="hotkey_2" label="HOTKEY 2"/>
        <ESlot slotKey="hotkey_3" label="HOTKEY 3"/>
      </div>

      <style>{`
        .equip-panel {
          display: flex; flex-direction: column; gap: 10px; padding: 14px;
          background: rgba(8,10,14,0.97); border: 1px solid var(--border);
          border-radius: var(--radius); width: 520px;
        }
        .e-top { display: grid; grid-template-columns: 110px 1fr 110px; gap: 8px; align-items: stretch; }
        .e-col { display: flex; flex-direction: column; gap: 8px; }
        .e-center { display: flex; flex-direction: column; align-items: center; justify-content: space-between; overflow: visible; }
        .e-figure { flex: 1; width: 100%; min-height: 0; display: flex; align-items: stretch; justify-content: center; overflow: visible; }
        .e-figure svg { height: 100%; width: auto; }
        .e-hp { font-family: var(--font-mono); font-size: 13px; font-weight: 700; letter-spacing: 0.12em; transition: color 0.5s ease; padding: 4px 0 2px; flex-shrink: 0; }
        .e-hp-unit { font-size: 0.6em; opacity: 0.55; margin-left: 2px; }
        .e-slot-wrap { display: flex; flex-direction: column; gap: 0; }
        .e-slot-label { font-size: 9px; font-weight: 800; letter-spacing: 0.1em; color: var(--text-primary); background: rgba(255,255,255,0.06); border: 1px solid var(--border); border-bottom: none; border-radius: 3px 3px 0 0; padding: 3px 6px; white-space: nowrap; }
        .e-slot { width: 100%; aspect-ratio: 1; background: var(--bg-slot); border: 1px solid var(--border); border-radius: 0 0 var(--radius) var(--radius); display: flex; flex-direction: column; align-items: center; justify-content: center; position: relative; overflow: hidden; transition: border-color var(--transition); }
        .e-slot.occupied { border-color: rgba(74,222,128,0.35); }
        .e-slot.occupied:hover { border-color: rgba(74,222,128,0.6); background: rgba(74,222,128,0.05); }
        .e-slot.dragging { opacity: 0.3; border-color: var(--accent); }
        .e-slot-empty-hint { font-size: 18px; font-weight: 900; color: rgba(255,255,255,0.04); font-family: var(--font-mono); }
        .e-qty { position: absolute; top: 4px; left: 5px; font-family: var(--font-mono); font-size: 9px; color: var(--text-muted); }
        .e-icon { width: 44px; height: 44px; display: flex; align-items: center; justify-content: center; }
        .e-icon img { width:100%; height:100%; object-fit:contain; filter:drop-shadow(0 0 6px rgba(74,222,128,0.15)); transition:filter var(--transition); }
        .e-slot.occupied:hover .e-icon img { filter: drop-shadow(0 0 8px rgba(74,222,128,0.35)); }
        .e-name { font-size: 8px; font-weight: 600; letter-spacing: 0.06em; color: var(--text-secondary); text-align: center; padding: 0 2px; margin-top: 2px; line-height: 1.2; }
        .e-weight { position: absolute; bottom: 3px; right: 4px; font-family: var(--font-mono); font-size: 7px; color: var(--text-muted); }
        .e-hotkeys { display: grid; grid-template-columns: repeat(3,1fr); gap: 8px; border-top: 1px solid var(--border); padding-top: 10px; }
        .e-hotkeys .e-icon { width: 38px; height: 38px; }
      `}</style>
    </div>
  )
}