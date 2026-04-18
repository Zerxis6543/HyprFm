// ─────────────────────────────────────────────────────────────────────────────
// HyprFM TYPED ERROR SYSTEM
//
// All reducers that can fail return `Result<(), HyprError>`. The enum is
// serialised to the wire as "ERROR_CODE|human-readable message" — a format
// the C# sidecar and Lua layer parse without regex or ad-hoc splits.
//
// Wire format rules:
//   • Error code  : SCREAMING_SNAKE_CASE, always the prefix before the first '|'
//   • Message     : everything after the first '|'; may itself contain '|' for
//                   structured sub-fields (e.g. InventoryFull weight data).
//   • Sidecar law : ParseHyprError() in Program.cs is the ONLY authorised
//                   place that reads raw exception text from SpacetimeDB.
// ─────────────────────────────────────────────────────────────────────────────

/// Canonical error taxonomy for all HyprFM SpacetimeDB reducers.
///
/// # Mapping guide for reducer authors
///
/// | Situation                                          | Variant            |
/// |----------------------------------------------------|-------------------|
/// | Row looked up by ID/key does not exist             | `NotFound`         |
/// | Inserting a row that would violate a unique index  | `AlreadyExists`    |
/// | Cash / bank balance too low for the operation      | `InsufficientFunds`|
/// | Weight limit **or** slot limit exceeded            | `InventoryFull`    |
/// | Caller does not own the entity / is banned         | `Unauthorised`     |
/// | Parameter fails validation (length, range, format) | `InvalidInput`     |
/// | Database is in an inconsistent state (programming) | `InternalError`    |
#[derive(Debug, Clone)]
pub enum HyprError {
    /// A requested row or resource does not exist.
    ///
    /// Use when: looking up a `Character`, `InventorySlot`, `StashDefinition`,
    /// or `ItemDefinition` by primary key and finding nothing.
    ///
    /// # Example
    /// ```
    /// return Err(hypr_err!(not_found, "Character {} does not exist", char_id));
    /// ```
    NotFound(String),

    /// An insert would create a duplicate of a unique record.
    ///
    /// Use when: calling `.insert()` on a table with a unique index where a
    /// matching row already exists (e.g. re-registering an opcode label).
    AlreadyExists(String),

    /// The account or character has insufficient currency.
    ///
    /// Use when: a shop purchase, fine, or fee cannot be paid. Carry the
    /// shortfall so the UI can render "You need $X more".
    ///
    /// # Example
    /// ```
    /// return Err(hypr_err!(insufficient_funds,
    ///     "Needs ${:.0}, has ${:.0}", cost, balance));
    /// ```
    InsufficientFunds(String),

    /// A weight or slot limit is exceeded.
    ///
    /// **Weight violations** should be constructed via
    /// `HyprError::weight_exceeded(actual, max)` so the sidecar can extract
    /// the two float values without a bespoke parser.
    ///
    /// **Slot violations** use `HyprError::slots_full(used, capacity)`.
    InventoryFull(String),

    /// The caller is not authorised to perform this operation.
    ///
    /// Use when: ownership check fails (character belongs to another account),
    /// or an account is banned. For bans, prefix the message with `"BANNED: "`
    /// so the sidecar can route it to the dedicated ban-kick flow in Lua.
    ///
    /// # Example
    /// ```
    /// return Err(hypr_err!(unauthorised, "BANNED: {}", acct.ban_reason));
    /// return Err(hypr_err!(unauthorised, "Character does not belong to this account"));
    /// ```
    Unauthorised(String),

    /// One or more input parameters are outside acceptable bounds.
    ///
    /// Use when: a string is empty or too long, a numeric value is out of
    /// range, an enum discriminant is unrecognised, or logical preconditions
    /// (e.g. "cannot delete an online character") are violated.
    InvalidInput(String),

    /// The module is in an unexpected internal state.
    ///
    /// Use sparingly — this variant indicates a programming error or a
    /// deployment problem (e.g. `init()` was never called). It should never
    /// appear in normal play. Log the cause and alert.
    InternalError(String),
}

// ─────────────────────────────────────────────────────────────────────────────
// CORE METHODS
// ─────────────────────────────────────────────────────────────────────────────

impl HyprError {
    /// The machine-readable code prefix used on the wire.
    /// Consumers (sidecar, Lua) branch on this string.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotFound(_)          => "NOT_FOUND",
            Self::AlreadyExists(_)     => "ALREADY_EXISTS",
            Self::InsufficientFunds(_) => "INSUFFICIENT_FUNDS",
            Self::InventoryFull(_)     => "INVENTORY_FULL",
            Self::Unauthorised(_)      => "UNAUTHORISED",
            Self::InvalidInput(_)      => "INVALID_INPUT",
            Self::InternalError(_)     => "INTERNAL_ERROR",
        }
    }

    /// The human-readable detail string carried by this error.
    pub fn message(&self) -> &str {
        match self {
            Self::NotFound(m)          => m,
            Self::AlreadyExists(m)     => m,
            Self::InsufficientFunds(m) => m,
            Self::InventoryFull(m)     => m,
            Self::Unauthorised(m)      => m,
            Self::InvalidInput(m)      => m,
            Self::InternalError(m)     => m,
        }
    }

    // ── Structured constructors ───────────────────────────────────────────────

    /// Weight-limit constructor.
    /// Message format: `"actual_kg|max_kg"` — the sidecar splits on `|` and
    /// surfaces `actual_kg` / `max_kg` as top-level JSON fields to Lua.
    pub fn weight_exceeded(actual: f32, max: f32) -> Self {
        Self::InventoryFull(format!("{:.2}|{:.2}", actual, max))
    }

    /// Slot-limit constructor (no extra numeric fields needed).
    pub fn slots_full(used: u32, capacity: u32) -> Self {
        Self::InventoryFull(format!(
            "Inventory full: {}/{} slots used",
            used, capacity
        ))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRAIT IMPLEMENTATIONS
// ─────────────────────────────────────────────────────────────────────────────

impl std::fmt::Display for HyprError {
    /// Serialises to the wire format: `"ERROR_CODE|message"`
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}|{}", self.code(), self.message())
    }
}

/// Allows `?` propagation from `HyprResult` into `Result<(), String>` (the
/// type that SpacetimeDB expects at the ABI boundary). The `#[reducer]` macro
/// auto-inserts this conversion when it serialises error returns.
impl From<HyprError> for String {
    fn from(e: HyprError) -> Self {
        e.to_string()
    }
}

/// Blanket `std::error::Error` impl so `HyprError` works with the full Rust
/// error ecosystem (anyhow, thiserror, Box<dyn Error>, etc.).
impl std::error::Error for HyprError {}

// ─────────────────────────────────────────────────────────────────────────────
// TYPE ALIAS
// ─────────────────────────────────────────────────────────────────────────────

/// Shorthand for reducer return types. Equivalent to `Result<T, HyprError>`.
///
/// ```rust
/// pub fn create_character(...) -> HyprResult {
///     ...
/// }
/// ```
pub type HyprResult<T = ()> = Result<T, HyprError>;


// ─────────────────────────────────────────────────────────────────────────────
// CONSTRUCTION MACRO
//
// hypr_err!(variant_keyword, format_string, args...)
//
// The keyword is lowercase-with-underscores to keep call sites readable
// without the enum path prefix. It expands to the fully qualified enum path
// so the macro is usable from sibling crates after `use stdb_core::hypr_err`.
// ─────────────────────────────────────────────────────────────────────────────

/// Ergonomic constructor for [`HyprError`].
///
/// Accepts a snake_case variant keyword and a `format!`-compatible string.
///
/// # Examples
/// ```rust
/// return Err(hypr_err!(not_found,          "Character {} missing",  char_id));
/// return Err(hypr_err!(already_exists,     "Opcode '{}' is taken",  label));
/// return Err(hypr_err!(insufficient_funds, "Need ${}, have ${}",    cost, bal));
/// return Err(hypr_err!(inventory_full,     "Slot limit reached"));
/// return Err(hypr_err!(unauthorised,       "BANNED: {}",            reason));
/// return Err(hypr_err!(invalid_input,      "Name must be 1–32 chars"));
/// return Err(hypr_err!(internal_error,     "Allocator not seeded"));
/// ```
#[macro_export]
macro_rules! hypr_err {
    (not_found,          $($arg:tt)+) => { $crate::error::HyprError::NotFound(format!($($arg)+))          };
    (already_exists,     $($arg:tt)+) => { $crate::error::HyprError::AlreadyExists(format!($($arg)+))     };
    (insufficient_funds, $($arg:tt)+) => { $crate::error::HyprError::InsufficientFunds(format!($($arg)+)) };
    (inventory_full,     $($arg:tt)+) => { $crate::error::HyprError::InventoryFull(format!($($arg)+))     };
    (unauthorised,       $($arg:tt)+) => { $crate::error::HyprError::Unauthorised(format!($($arg)+))      };
    (invalid_input,      $($arg:tt)+) => { $crate::error::HyprError::InvalidInput(format!($($arg)+))      };
    (internal_error,     $($arg:tt)+) => { $crate::error::HyprError::InternalError(format!($($arg)+))     };
}