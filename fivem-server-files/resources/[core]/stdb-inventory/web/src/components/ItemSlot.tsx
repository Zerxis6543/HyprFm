import { useDraggable, useDroppable } from '@dnd-kit/core'
import { CSSProperties } from 'react'
import { InventorySlot, ItemDefinition, itemIcon, ITEM_RARITY } from '../types'
import { useInventoryStore } from '../store'

interface Props {
  slotIndex:    number
  slot:         InventorySlot | null
  itemDef:      ItemDefinition | null
  panel:        'pockets' | 'secondary' | 'backpack'
  isDropTarget?: boolean
}

export function ItemSlot({ slotIndex, slot, itemDef, panel, isDropTarget = false }: Props) {
  const showContext = useInventoryStore(s => s.showContext)

  const { attributes, listeners, setNodeRef: setDragRef, isDragging } = useDraggable({
    id:       slot ? `slot-${slot.id}` : `empty-${panel}-${slotIndex}`,
    disabled: !slot,
  })

  const { setNodeRef: setDropRef } = useDroppable({
    id:       `drop-${panel}-${slotIndex}`,
    data:     { slotIndex, panel },
    disabled: isDragging,
  })

  const setNodeRef = (el: HTMLElement | null) => {
    setDragRef(el)
    setDropRef(el)
  }

  const style: CSSProperties = {
    opacity: isDragging ? 0.3 : 1,
  }

  const rarity = slot ? (ITEM_RARITY[slot.item_id] ?? { label: 'COMMON', color: '#888' }) : null

  const handleContextMenu = (e: React.MouseEvent) => {
    if (!slot) return
    e.preventDefault()
    showContext(slot.id, e.clientX, e.clientY)
  }

  return (
    <div
      ref={setNodeRef}
      style={style}
      data-slot-index={slotIndex}
      data-panel={panel}
      onContextMenu={handleContextMenu}
      className={`item-slot ${slot ? 'occupied' : 'empty'} ${isDragging ? 'dragging' : ''} ${isDropTarget ? 'drop-target' : ''}`}
      {...(slot ? { ...attributes, ...listeners } : {})}
    >
      {slot && itemDef && (
        <>
          <div className="slot-rarity-bar" style={{ background: rarity?.color }} />
          <div className="slot-rarity-badge" style={{ color: rarity?.color }}>{rarity?.label}</div>
          <div className="slot-qty"><span className="qty-num">{slot.quantity}x</span></div>
          <div className="slot-icon">
            <img
              src={itemIcon(slot.item_id)}
              alt={itemDef.label}
              draggable={false}
              onError={(e) => { (e.target as HTMLImageElement).style.opacity = '0' }}
            />
          </div>
          <div className="slot-name">{itemDef.label.toUpperCase()}</div>
          <div className="slot-weight">{(itemDef.weight * slot.quantity).toFixed(2)}kg</div>
        </>
      )}
      <style>{`
        .item-slot {
          position: relative; width: 100%; aspect-ratio: 1;
          background: var(--bg-slot); border: 1px solid var(--border);
          border-radius: var(--radius);
          display: flex; flex-direction: column; align-items: center; justify-content: center;
          cursor: default; transition: border-color var(--transition), background var(--transition);
          overflow: hidden; user-select: none;
        }
        .item-slot.occupied { cursor: grab; }
        .item-slot.occupied:hover { border-color: rgba(255,255,255,0.15); background: var(--bg-slot-hover); }
        .item-slot.occupied:hover .slot-name { color: var(--accent); }
        .item-slot.dragging { border-color: var(--accent); background: var(--accent-dim); }
        .item-slot.drop-target {
          border-color: var(--accent);
          background: var(--accent-dim);
          box-shadow: inset 0 0 0 1px var(--accent);
        }
        .slot-rarity-bar { position: absolute; top: 0; left: 0; right: 0; height: 2px; opacity: 0.7; }
        .slot-rarity-badge {
          position: absolute; top: 5px; right: 4px;
          font-family: var(--font-mono); font-size: 8px; letter-spacing: 0.05em; opacity: 0.8;
        }
        .qty-num { font-family: var(--font-mono); font-size: 10px; color: var(--text-secondary); }
        .slot-name {
          font-size: 9px; font-weight: 600; letter-spacing: 0.06em;
          color: var(--text-secondary); text-align: center; padding: 0 4px;
          line-height: 1.2; transition: color var(--transition);
        }
        .slot-weight {
          position: absolute; bottom: 3px; right: 4px;
          font-family: var(--font-mono); font-size: 7px; color: var(--text-muted);
        }
        .slot-icon {
          width: 52px; height: 52px; margin-bottom: 3px; margin-top: 10px;
          display: flex; align-items: center; justify-content: center;
        }
        .slot-icon img {
          width: 100%; height: 100%; object-fit: contain;
          filter: drop-shadow(0 0 6px rgba(74,222,128,0.15));
          transition: filter var(--transition);
        }
        .item-slot.occupied:hover .slot-icon img { filter: drop-shadow(0 0 8px rgba(74,222,128,0.35)); }
      `}</style>
    </div>
  )
}