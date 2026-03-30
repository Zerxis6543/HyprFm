import { useDraggable } from '@dnd-kit/core'
import { useRef } from 'react'
import { useInventoryStore } from '../store'
import { EquipSlotKey, itemIcon } from '../types'

// ── Health colour ramp: green → amber → red ───────────────────────────────────
function zoneColor(hp: number): string {
  const h = Math.max(0, Math.min(100, hp))
  if (h >= 60) {
    const t = (100 - h) / 40
    return `rgb(${Math.round(74 + 176 * t)},${Math.round(222 - 18 * t)},${Math.round(128 - 107 * t)})`
  }
  const t = (60 - h) / 60
  return `rgb(${Math.round(250 - 2 * t)},${Math.round(204 - 91 * t)},${Math.round(21 + 92 * t)})`
}

function withAlpha(c: string, a: number) {
  return c.replace('rgb(', 'rgba(').replace(')', `,${a})`)
}

// ── Limb health data shape — extend when player-stats system is built ─────────
// Each zone maps to an SVG path id.  100 = full health, 0 = critical.
// Currently everything defaults to the overall health value until the stats
// system populates individual zone data.
interface LimbHealth {
  head:      number
  torso:     number
  leftArm:   number
  rightArm:  number
  leftLeg:   number
  rightLeg:  number
}

// ── Humanoid A-pose SVG ───────────────────────────────────────────────────────
// Proportions follow a standard 7.5-head-height figure.
// Each anatomical region is a separate <path> with an id so future code can
// target individual zones by id for per-limb colouring.
// The viewBox is 100 × 220 — wide enough for A-pose arms at ~100% body width.
function BodySVG({ health, limbs }: { health: number; limbs: LimbHealth }) {
  const overall  = zoneColor(health)
  const glow     = withAlpha(overall, 0.5)

  // Helper: pick colour for a zone.  Falls back to overall until per-limb data arrives.
  const zc = (hp: number) => zoneColor(hp)

  return (
    <svg
      viewBox="0 0 100 220"
      xmlns="http://www.w3.org/2000/svg"
      style={{ width: '100%', height: '100%', filter: `drop-shadow(0 0 8px ${glow})`, overflow: 'visible' }}
    >
      <defs>
        {/* Subtle inner highlight for each zone */}
        <filter id="zone-glow" x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="1.2" result="blur"/>
          <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
        </filter>
        {/* Scanline-style body texture overlay */}
        <pattern id="lines" x="0" y="0" width="2" height="2" patternUnits="userSpaceOnUse">
          <line x1="0" y1="0" x2="2" y2="2" stroke="rgba(0,0,0,0.15)" strokeWidth="0.4"/>
        </pattern>
      </defs>

      {/* ── HEAD ─────────────────────────────────────────────────────────── */}
      {/* Oval skull */}
      <ellipse
        id="zone-head"
        cx="50" cy="12" rx="9" ry="11"
        fill={zc(limbs.head)}
        opacity="0.92"
      />
      {/* Neck */}
      <rect x="46" y="22" width="8" height="6" rx="1" fill={zc(limbs.torso)} opacity="0.85"/>

      {/* ── TORSO ────────────────────────────────────────────────────────── */}
      {/* Shoulders + chest trapezoid */}
      <path
        id="zone-torso"
        d="M30 28 L70 28 L67 70 L33 70 Z"
        fill={zc(limbs.torso)}
        opacity="0.92"
      />
      {/* Waist / pelvis block */}
      <path
        d="M34 70 L66 70 L64 88 L36 88 Z"
        fill={zc(limbs.torso)}
        opacity="0.80"
      />
      {/* Sternum line for visual detail */}
      <line x1="50" y1="30" x2="50" y2="68" stroke="rgba(0,0,0,0.2)" strokeWidth="0.6"/>
      {/* Collar bones */}
      <line x1="34" y1="31" x2="50" y2="29" stroke="rgba(0,0,0,0.15)" strokeWidth="0.5"/>
      <line x1="66" y1="31" x2="50" y2="29" stroke="rgba(0,0,0,0.15)" strokeWidth="0.5"/>

      {/* ── LEFT ARM (screen-left = character's right) ────────────────────── */}
      {/* Upper arm — angled outward in A-pose */}
      <path
        id="zone-left-arm"
        d="M30 30 L10 55 L15 60 L35 36 Z"
        fill={zc(limbs.leftArm)}
        opacity="0.92"
      />
      {/* Elbow joint */}
      <ellipse cx="12.5" cy="57.5" rx="3" ry="3" fill={zc(limbs.leftArm)} opacity="0.85"/>
      {/* Forearm */}
      <path
        d="M10 55 L2 80 L7 82 L15 60 Z"
        fill={zc(limbs.leftArm)}
        opacity="0.88"
      />
      {/* Hand */}
      <ellipse cx="4.5" cy="81" rx="3.5" ry="4" fill={zc(limbs.leftArm)} opacity="0.80"/>

      {/* ── RIGHT ARM (screen-right = character's left) ───────────────────── */}
      <path
        id="zone-right-arm"
        d="M70 30 L90 55 L85 60 L65 36 Z"
        fill={zc(limbs.rightArm)}
        opacity="0.92"
      />
      <ellipse cx="87.5" cy="57.5" rx="3" ry="3" fill={zc(limbs.rightArm)} opacity="0.85"/>
      <path
        d="M90 55 L98 80 L93 82 L85 60 Z"
        fill={zc(limbs.rightArm)}
        opacity="0.88"
      />
      <ellipse cx="95.5" cy="81" rx="3.5" ry="4" fill={zc(limbs.rightArm)} opacity="0.80"/>

      {/* ── LEFT LEG ─────────────────────────────────────────────────────── */}
      {/* Upper leg */}
      <path
        id="zone-left-leg"
        d="M36 88 L48 88 L46 140 L34 140 Z"
        fill={zc(limbs.leftLeg)}
        opacity="0.92"
      />
      {/* Knee */}
      <ellipse cx="40" cy="141" rx="6" ry="4" fill={zc(limbs.leftLeg)} opacity="0.85"/>
      {/* Shin */}
      <path
        d="M34 142 L46 142 L44 190 L36 190 Z"
        fill={zc(limbs.leftLeg)}
        opacity="0.88"
      />
      {/* Foot */}
      <path
        d="M34 190 L46 190 L48 196 L32 196 Z"
        fill={zc(limbs.leftLeg)}
        opacity="0.80"
      />

      {/* ── RIGHT LEG ────────────────────────────────────────────────────── */}
      <path
        id="zone-right-leg"
        d="M52 88 L64 88 L66 140 L54 140 Z"
        fill={zc(limbs.rightLeg)}
        opacity="0.92"
      />
      <ellipse cx="60" cy="141" rx="6" ry="4" fill={zc(limbs.rightLeg)} opacity="0.85"/>
      <path
        d="M54 142 L66 142 L64 190 L56 190 Z"
        fill={zc(limbs.rightLeg)}
        opacity="0.88"
      />
      <path
        d="M54 190 L66 190 L68 196 L52 196 Z"
        fill={zc(limbs.rightLeg)}
        opacity="0.80"
      />

      {/* ── Scanline texture overlay (cosmetic) ───────────────────────────── */}
      <rect x="0" y="0" width="100" height="220" fill="url(#lines)" opacity="0.3" style={{ pointerEvents: 'none' }}/>
    </svg>
  )
}

// ── Equipment slot ────────────────────────────────────────────────────────────
function ESlot({ slotKey, label }: { slotKey: EquipSlotKey; label: string }) {
  const equipSlots = useInventoryStore(s => s.equipSlots)
  const itemDefs   = useInventoryStore(s => s.itemDefs)
  const equip      = equipSlots.find(s => s.key === slotKey)
  const slot       = equip?.slot ?? null
  const def        = slot ? itemDefs[slot.item_id] : null

  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id:       `equip-${slotKey}`,
    disabled: !slot,
  })

  const showContext = useInventoryStore(s => s.showContext)
  const dragStart   = useRef<{ x: number; y: number } | null>(null)
  const didDrag     = useRef(false)

  return (
    <div className="e-slot-wrap">
      <div className="e-slot-label">{label}</div>
      <div
        ref={setNodeRef}
        data-equip-key={slotKey}
        className={`e-slot ${slot ? 'occupied' : ''} ${isDragging ? 'dragging' : ''} ${slot && (slot.item_id === 'backpack' || slot.item_id === 'duffel_bag') ? 'bag-slot' : ''}`}
        style={{ opacity: isDragging ? 0.3 : 1 }}
        onPointerDown={(e) => { dragStart.current = { x: e.clientX, y: e.clientY }; didDrag.current = false }}
        onPointerMove={(e) => {
          if (dragStart.current) {
            const dx = e.clientX - dragStart.current.x
            const dy = e.clientY - dragStart.current.y
            if (Math.sqrt(dx * dx + dy * dy) > 6) didDrag.current = true
          }
        }}
        onContextMenu={slot ? (e) => {
          e.preventDefault(); e.stopPropagation()
          if (didDrag.current) { didDrag.current = false; return }
          showContext(slot.id, e.clientX, e.clientY)
        } : undefined}
        {...(slot ? { ...attributes, ...listeners } : {})}
      >
        {!slot && <div className="e-slot-empty-hint">{label[0]}</div>}
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

// ── Main panel ────────────────────────────────────────────────────────────────
export function EquipmentPanel() {
  const health = useInventoryStore(s => s.health)
  const c      = zoneColor(health)

  // Placeholder limb data — all zones mirror overall HP until the stats system
  // populates per-zone values. Replace with real store selectors when ready.
  const limbs: LimbHealth = {
    head:      health,
    torso:     health,
    leftArm:   health,
    rightArm:  health,
    leftLeg:   health,
    rightLeg:  health,
  }

  return (
    <div className="equip-panel">

      {/* TOP: left slots | body figure | right slots */}
      <div className="e-top">

        <div className="e-col">
          <ESlot slotKey="backpack"    label="BACKPACK"/>
          <ESlot slotKey="body_armour" label="BODY ARMOUR"/>
          <ESlot slotKey="phone"       label="PHONE"/>
        </div>

        <div className="e-center">
          <div className="e-figure">
            <BodySVG health={health} limbs={limbs}/>
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

      {/* BOTTOM: hotkey row */}
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
        .e-top {
          display: grid; grid-template-columns: 130px 1fr 130px;
          gap: 10px; align-items: center;
        }
        .e-center { display: flex; flex-direction: column; align-items: center; gap: 6px; }
        .e-figure { width: 120px; height: 230px; }
        .e-hp {
          font-family: var(--font-mono); font-size: 15px; font-weight: 700;
          letter-spacing: 0.12em; transition: color 0.5s ease;
        }
        .e-hp-unit { font-size: 0.6em; opacity: 0.55; margin-left: 2px; }
        .e-col { display: flex; flex-direction: column; gap: 10px; }
        .e-hotkeys {
          display: grid; grid-template-columns: repeat(3,1fr); gap: 8px;
          border-top: 1px solid var(--border); padding-top: 10px;
        }
        .e-slot-wrap { display: flex; flex-direction: column; gap: 0; }
        .e-slot-label {
          display: flex; align-items: center;
          font-size: 9px; font-weight: 800; letter-spacing: 0.1em;
          color: var(--text-primary); background: rgba(255,255,255,0.06);
          border: 1px solid var(--border); border-bottom: none;
          border-radius: 3px 3px 0 0; padding: 3px 6px;
          white-space: nowrap; text-overflow: ellipsis;
        }
        .e-slot {
          width: 100%; aspect-ratio: 1; background: var(--bg-slot);
          border: 1px solid var(--border); border-radius: 0 0 var(--radius) var(--radius);
          display: flex; flex-direction: column; align-items: center; justify-content: center;
          position: relative; overflow: hidden; transition: border-color var(--transition);
        }
        .e-slot.occupied { border-color: rgba(74,222,128,0.35); }
        .e-slot.occupied:hover { border-color: rgba(74,222,128,0.6); background: rgba(74,222,128,0.05); }
        .e-slot.dragging { opacity: 0.3; border-color: var(--accent); }
        .e-slot-empty-hint {
          font-size: 18px; font-weight: 900;
          color: rgba(255,255,255,0.04); font-family: var(--font-mono);
        }
        .e-qty { position: absolute; top: 4px; left: 5px; font-family: var(--font-mono); font-size: 9px; color: var(--text-muted); }
        .e-icon { width: 52px; height: 52px; display: flex; align-items: center; justify-content: center; }
        .e-icon img { width: 100%; height: 100%; object-fit: contain; filter: drop-shadow(0 0 6px rgba(74,222,128,0.15)); transition: filter var(--transition); }
        .e-slot.occupied:hover .e-icon img { filter: drop-shadow(0 0 8px rgba(74,222,128,0.35)); }
        .e-name { font-size: 9px; font-weight: 600; letter-spacing: 0.06em; color: var(--text-secondary); text-align: center; padding: 0 4px; margin-top: 2px; line-height: 1.2; }
        .e-weight { position: absolute; bottom: 3px; right: 4px; font-family: var(--font-mono); font-size: 7px; color: var(--text-muted); }
        .e-hotkeys .e-icon { width: 42px; height: 42px; }
      `}</style>
    </div>
  )
}