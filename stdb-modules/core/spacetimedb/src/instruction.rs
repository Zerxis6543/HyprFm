use spacetimedb::Timestamp;

#[derive(Clone, Debug)]
pub struct InstructionQueue {
    pub id:                   u64,
    pub target_entity_net_id: u32,
    pub opcode:               u16,
    pub payload:              String,
    pub queued_at:            Timestamp,
    pub consumed:             bool,
}