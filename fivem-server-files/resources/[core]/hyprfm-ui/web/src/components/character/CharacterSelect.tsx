import { useState } from 'react'

// ─────────────────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────────────────

export interface CharacterData {
  id:              number
  slot_index:      number
  name:            string
  gender:          string
  job:             string
  money_cash:      number
  health:          number
  last_seen:       string
  components_json: string
}

interface Props {
  characters:    CharacterData[]
  maxCharacters: number
  onSelect:      (characterId: number) => void
  onCreate:      (slotIndex: number, name: string, gender: string) => void
  onDelete:      (characterId: number) => void
}

type Mode = 'list' | 'create'

// ─────────────────────────────────────────────────────────────────────────────
// STYLES (inline — no external dependency)
// ─────────────────────────────────────────────────────────────────────────────

const btnBase: React.CSSProperties = {
  padding: '7px 14px', background: 'none',
  border: '1px solid rgba(255,255,255,0.08)', borderRadius: 2,
  color: 'rgba(255,255,255,0.45)', fontFamily: 'var(--font-ui)',
  fontSize: 10, fontWeight: 700, letterSpacing: '0.08em', cursor: 'pointer',
  transition: 'all 0.12s ease',
}

const labelStyle: React.CSSProperties = {
  fontSize: 9, fontWeight: 800, letterSpacing: '0.12em',
  color: 'rgba(255,255,255,0.2)', marginBottom: 6,
}

const inputStyle: React.CSSProperties = {
  width: '100%', padding: '9px 12px',
  background: 'rgba(255,255,255,0.025)', border: '1px solid rgba(255,255,255,0.07)',
  borderRadius: 2, color: 'rgba(255,255,255,0.9)',
  fontFamily: 'var(--font-ui)', fontSize: 13, outline: 'none',
  letterSpacing: '0.04em',
}

// ─────────────────────────────────────────────────────────────────────────────
// HEALTH BAR
// ─────────────────────────────────────────────────────────────────────────────

function HealthBar({ health }: { health: number }) {
  const pct = Math.round(((Math.max(100, Math.min(200, health)) - 100) / 100) * 100)
  const color = pct >= 60 ? '#4ade80' : pct >= 30 ? '#facc15' : '#f87171'
  return (
    <div style={{ height: 2, background: 'rgba(255,255,255,0.06)', borderRadius: 1, overflow: 'hidden', marginTop: 4 }}>
      <div style={{ height: '100%', width: `${pct}%`, background: color, borderRadius: 1, transition: 'width 0.3s ease' }} />
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// CHARACTER SLOT CARD
// ─────────────────────────────────────────────────────────────────────────────

function CharSlot({
  slotIdx, char, onSelect, onDelete, onCreateClick,
}: {
  slotIdx:       number
  char:          CharacterData | null
  onSelect:      (id: number) => void
  onDelete:      (id: number) => void
  onCreateClick: (slotIdx: number) => void
}) {
  const [confirmDelete, setConfirmDelete] = useState(false)

  const borderColor = char ? 'rgba(74,222,128,0.22)' : 'rgba(255,255,255,0.07)'
  const bgColor     = char ? 'rgba(74,222,128,0.03)' : 'rgba(255,255,255,0.01)'

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '13px 16px',
      background: bgColor, border: `1px solid ${borderColor}`,
      borderRadius: 2, transition: 'border-color 0.12s ease',
    }}>
      {/* Slot number badge */}
      <div style={{
        width: 34, height: 34, borderRadius: 2, flexShrink: 0,
        background: char ? 'rgba(74,222,128,0.08)' : 'rgba(255,255,255,0.03)',
        border: `1px solid ${char ? 'rgba(74,222,128,0.3)' : 'rgba(255,255,255,0.07)'}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: 'var(--font-mono)', fontSize: 14, fontWeight: 700,
        color: char ? '#4ade80' : 'rgba(255,255,255,0.15)',
      }}>
        {slotIdx + 1}
      </div>

      {char ? (
        <>
          {/* Character info */}
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 700, letterSpacing: '0.06em', color: 'rgba(255,255,255,0.9)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
              {char.name.toUpperCase()}
            </div>
            <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'rgba(255,255,255,0.3)', marginTop: 2, letterSpacing: '0.04em' }}>
              {char.gender.toUpperCase()} · {char.job.toUpperCase()} · ${char.money_cash.toLocaleString()}
            </div>
            <HealthBar health={char.health} />
          </div>

          {/* Action buttons */}
          <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
            {confirmDelete ? (<>
              <button
                onClick={() => { onDelete(char.id); setConfirmDelete(false) }}
                style={{ ...btnBase, color: '#f87171', borderColor: 'rgba(248,113,113,0.35)' }}>
                CONFIRM
              </button>
              <button onClick={() => setConfirmDelete(false)} style={btnBase}>
                CANCEL
              </button>
            </>) : (<>
              <button
                onClick={() => setConfirmDelete(true)}
                style={{ ...btnBase, color: 'rgba(255,255,255,0.25)' }}>
                DELETE
              </button>
              <button
                onClick={() => onSelect(char.id)}
                style={{ ...btnBase, color: '#4ade80', borderColor: 'rgba(74,222,128,0.35)' }}>
                PLAY →
              </button>
            </>)}
          </div>
        </>
      ) : (
        <>
          <div style={{ flex: 1, fontSize: 11, color: 'rgba(255,255,255,0.2)', fontStyle: 'italic', letterSpacing: '0.04em' }}>
            Empty slot
          </div>
          <button
            onClick={() => onCreateClick(slotIdx)}
            style={{ ...btnBase, color: '#4ade80', borderColor: 'rgba(74,222,128,0.25)' }}>
            + CREATE
          </button>
        </>
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// CREATE FORM
// ─────────────────────────────────────────────────────────────────────────────

function CreateForm({
  slotIndex, onCreate, onBack,
}: {
  slotIndex: number
  onCreate:  (slotIndex: number, name: string, gender: string) => void
  onBack:    () => void
}) {
  const [name,   setName]   = useState('')
  const [gender, setGender] = useState<'male' | 'female'>('male')
  const trimmed = name.trim()
  const valid   = trimmed.length >= 1 && trimmed.length <= 32

  return (
    <div>
      <div style={{ marginBottom: 20, fontSize: 11, fontWeight: 700, letterSpacing: '0.1em', color: 'rgba(255,255,255,0.45)' }}>
        NEW CHARACTER — SLOT {slotIndex + 1}
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={labelStyle}>CHARACTER NAME</div>
        <input
          value={name}
          onChange={e => setName(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter' && valid) onCreate(slotIndex, trimmed, gender) }}
          maxLength={32}
          placeholder="First Last"
          autoFocus
          style={inputStyle}
        />
        {name.length > 0 && (name.trim().length < 1 || name.trim().length > 32) && (
          <div style={{ fontSize: 9, color: '#f87171', marginTop: 4, fontFamily: 'var(--font-mono)' }}>
            1–32 characters required
          </div>
        )}
      </div>

      <div style={{ marginBottom: 24 }}>
        <div style={labelStyle}>GENDER</div>
        <div style={{ display: 'flex', gap: 8 }}>
          {(['male', 'female'] as const).map(g => (
            <button key={g} onClick={() => setGender(g)} style={{
              flex: 1, padding: '9px 0', cursor: 'pointer',
              background: gender === g ? 'rgba(74,222,128,0.08)' : 'transparent',
              border: `1px solid ${gender === g ? 'rgba(74,222,128,0.4)' : 'rgba(255,255,255,0.07)'}`,
              borderRadius: 2,
              color: gender === g ? '#4ade80' : 'rgba(255,255,255,0.3)',
              fontFamily: 'var(--font-ui)', fontSize: 11, fontWeight: 700,
              letterSpacing: '0.08em', transition: 'all 0.12s ease',
            }}>
              {g.toUpperCase()}
            </button>
          ))}
        </div>
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button onClick={onBack} style={{ ...btnBase, flex: 1 }}>
          ← BACK
        </button>
        <button
          onClick={() => { if (valid) onCreate(slotIndex, trimmed, gender) }}
          disabled={!valid}
          style={{
            ...btnBase, flex: 2,
            color: valid ? '#4ade80' : 'rgba(74,222,128,0.25)',
            borderColor: valid ? 'rgba(74,222,128,0.4)' : 'rgba(74,222,128,0.1)',
            opacity: valid ? 1 : 0.6,
            cursor: valid ? 'pointer' : 'not-allowed',
          }}>
          CREATE CHARACTER →
        </button>
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────────────────────

export function CharacterSelect({ characters, maxCharacters, onSelect, onCreate, onDelete }: Props) {
  const [mode,          setMode]          = useState<Mode>('list')
  const [pendingSlot,   setPendingSlot]   = useState<number | null>(null)
  const [createError,   setCreateError]   = useState<string | null>(null)

  const allSlots  = Array.from({ length: maxCharacters }, (_, i) => i)

  const handleCreate = (slotIndex: number, name: string, gender: string) => {
    setCreateError(null)
    onCreate(slotIndex, name, gender)
    setMode('list')
    setPendingSlot(null)
  }

  const handleCreateClick = (slotIdx: number) => {
    setPendingSlot(slotIdx)
    setMode('create')
  }

  return (
    <div style={{
      position: 'fixed', inset: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: 'rgba(0,0,0,0.88)', backdropFilter: 'blur(16px)',
      zIndex: 10000, fontFamily: 'var(--font-ui)',
    }}>
      <div style={{
        background: 'rgba(8,10,14,0.98)', border: '1px solid rgba(255,255,255,0.07)',
        borderRadius: 2, width: 560, padding: '28px 28px 24px',
        boxShadow: '0 24px 80px rgba(0,0,0,0.8)',
      }}>

        {/* Header */}
        <div style={{ marginBottom: 22, borderBottom: '1px solid rgba(255,255,255,0.06)', paddingBottom: 16 }}>
          <div style={{ fontSize: 17, fontWeight: 700, letterSpacing: '0.12em', color: 'rgba(255,255,255,0.9)' }}>
            CHARACTER SELECT
          </div>
          <div style={{ fontSize: 10, color: 'rgba(255,255,255,0.2)', fontFamily: 'var(--font-mono)', marginTop: 4, letterSpacing: '0.06em' }}>
            {characters.length}/{maxCharacters} SLOTS USED
          </div>
        </div>

        {mode === 'list' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {allSlots.map(slotIdx => {
              const char = characters.find(c => c.slot_index === slotIdx) ?? null
              return (
                <CharSlot
                  key={slotIdx}
                  slotIdx={slotIdx}
                  char={char}
                  onSelect={onSelect}
                  onDelete={onDelete}
                  onCreateClick={handleCreateClick}
                />
              )
            })}

            {createError && (
              <div style={{ padding: '8px 12px', background: 'rgba(248,113,113,0.08)', border: '1px solid rgba(248,113,113,0.2)', borderRadius: 2, fontSize: 10, color: '#f87171', fontFamily: 'var(--font-mono)', marginTop: 4 }}>
                {createError}
              </div>
            )}
          </div>
        )}

        {mode === 'create' && pendingSlot !== null && (
          <CreateForm
            slotIndex={pendingSlot}
            onCreate={handleCreate}
            onBack={() => { setMode('list'); setPendingSlot(null) }}
          />
        )}

      </div>
    </div>
  )
}