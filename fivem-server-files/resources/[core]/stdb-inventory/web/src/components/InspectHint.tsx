import { useInventoryStore } from '../store'
import { itemIcon } from '../types'

export function InspectHint() {
  const inspectMode = useInventoryStore(s => s.inspectMode)
  const inspectSlot = useInventoryStore(s => s.inspectSlot)
  const itemDefs    = useInventoryStore(s => s.itemDefs)

  if (!inspectMode || !inspectSlot) return null
  const def = itemDefs[inspectSlot.item_id]

  return (
    <div style={{
      position: 'fixed', bottom: 40, left: '50%',
      transform: 'translateX(-50%)',
      display: 'flex', alignItems: 'center', gap: 20,
      background: 'rgba(8,10,14,0.95)',
      border: '1px solid var(--border)',
      borderRadius: 'var(--radius)',
      padding: '10px 20px',
      zIndex: 9999,
      pointerEvents: 'none',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <img src={itemIcon(inspectSlot.item_id)} style={{ width: 24, height: 24, objectFit: 'contain' }}
          onError={e => { (e.target as HTMLImageElement).style.opacity = '0' }} />
        <span style={{ color: 'var(--text-primary)', fontSize: 11, fontWeight: 700, letterSpacing: '0.08em' }}>
          {def?.label.toUpperCase() ?? inspectSlot.item_id}
        </span>
      </div>
      <div style={{ width: 1, height: 20, background: 'var(--border)' }} />
      {[
        { key: 'E', label: 'PLACE' },
        { key: 'G', label: 'GIVE' },
        { key: 'RMB', label: 'HOLD TO CHARGE' },
        { key: 'BKSP', label: 'CANCEL' },
      ].map(({ key, label }) => (
        <div key={key} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <div style={{
            background: 'rgba(255,255,255,0.1)', border: '1px solid var(--border)',
            borderRadius: 3, padding: '2px 7px',
            fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--text-primary)',
          }}>{key}</div>
          <span style={{ fontSize: 9, color: 'var(--text-muted)', letterSpacing: '0.08em' }}>{label}</span>
        </div>
      ))}
    </div>
  )
}