namespace HyprFM.Sidecar.Pool;

// ─────────────────────────────────────────────────────────────────────────────
// TRANSPORT ABSTRACTION
// Decouples ManagedSubscription from the SpacetimeDB SDK so tests can inject
// a FakeTransport without requiring a live SpacetimeDB process.
// ─────────────────────────────────────────────────────────────────────────────

/// <summary>
/// Thin shell over a single SpacetimeDB WebSocket connection.
/// The real implementation wraps <c>SpacetimeDB.Types.DbConnection</c>;
/// test doubles simulate any network scenario.
/// </summary>
public interface IDbTransport : IAsyncDisposable
{
    /// <summary>True while the WebSocket handshake is complete and the pipe is live.</summary>
    bool IsOpen { get; }

    /// <summary>
    /// Advances the SpacetimeDB client state machine one tick.
    /// Maps 1-to-1 with <c>DbConnection.FrameTick()</c>.
    /// </summary>
    void Tick();

    /// <summary>Fired by the transport when the remote closes the connection.</summary>
    event Action? Disconnected;
}

/// <summary>
/// Factory that produces ready-to-tick transports for a (uri, database, token) triple.
/// The factory owns the connection handshake; <see cref="ManagedSubscription"/>
/// only calls CreateAsync — it never constructs a raw SDK object directly.
/// </summary>
public interface IDbTransportFactory
{
    /// <summary>
    /// Open the connection and return only after the handshake succeeds.
    /// Throw on failure; the supervisor loop handles retries.
    /// </summary>
    Task<IDbTransport> CreateAsync(
        string            uri,
        string            database,
        string            token,
        CancellationToken ct);
}