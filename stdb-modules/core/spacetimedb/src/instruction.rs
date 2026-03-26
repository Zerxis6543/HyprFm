use spacetimedb::Timestamp;


#[spacetimedb::table(accessor = instruction_queue, public)]
#[derive(Clone, Debug)]
pub struct InstructionQueue {
    #[primary_key]
    #[auto_inc]
    pub id: u64,

    
    pub target_entity_net_id: u32,

    pub opcode: u16,

    pub payload: String,

    pub queued_at: Timestamp,

    pub consumed: bool,
}

#[spacetimedb::reducer]
pub fn mark_instruction_consumed(ctx: &spacetimedb::ReducerContext, id: u64) {
    if let Some(mut row) = ctx.db.instruction_queue().id().find(id) {
        row.consumed = true;
        ctx.db.instruction_queue().id().update(row);
    }
}