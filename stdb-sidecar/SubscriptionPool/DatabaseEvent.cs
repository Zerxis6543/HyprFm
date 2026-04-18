namespace HyprFM.Sidecar.Pool;

// ─────────────────────────────────────────────────────────────────────────────
// DATABASE EVENT
// Immutable value that flows through the internal Channel<T> bus.
// Every ManagedSubscription writes to the same bus; consumers filter by
// DatabaseName so core logic ignores third-party module events and vice versa.
// ─────────────────────────────────────────────────────────────────────────────

public enum DatabaseEventKind
{
    Connected,
    Disconnected,
    Reconnecting,
    Error,
}

/// <summary>
/// Snapshot of a state-change event emitted by one <see cref="ManagedSubscription"/>.
/// Immutable — safe to share across threads without copying.
/// </summary>
public sealed record DatabaseEvent(
    string            DatabaseName,
    DatabaseEventKind Kind,
    string?           Payload   = null,
    Exception?        Exception = null)
{
    /// <summary>Wall-clock timestamp stamped at construction, before any queue transit.</summary>
    public DateTimeOffset OccurredAt { get; } = DateTimeOffset.UtcNow;

    public override string ToString() =>
        $"[{OccurredAt:HH:mm:ss.fff}] {DatabaseName} → {Kind}" +
        (Payload   != null ? $" | {Payload}"               : "") +
        (Exception != null ? $" | ERR: {Exception.Message}" : "");
}