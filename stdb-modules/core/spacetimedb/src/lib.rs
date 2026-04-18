pub mod instruction;
pub mod opcodes;
pub mod error;

pub use instruction::InstructionQueue;
pub use error::{HyprError, HyprResult};