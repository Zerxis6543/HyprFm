namespace HyprFM.Sidecar.Pool;

using SpacetimeDB;
using SpacetimeDB.Types;

// ─────────────────────────────────────────────────────────────────────────────
// REAL SPACETIMEDB TRANSPORT
// Adapts the SDK-generated DbConnection to IDbTransport.
// One instance per database; created exclusively by SpacetimeDbTransportFactory.
// ─────────────────────────────────────────────────────────────────────────────

internal sealed class SpacetimeDbTransport : IDbTransport
{
    private readonly DbConnection _conn;
    private volatile bool         _isOpen;

    public bool IsOpen => _isOpen;
    public event Action? Disconnected;

    // Expose the typed connection so Program.cs can wire table callbacks.
    public DbConnection TypedConnection => _conn;

    private SpacetimeDbTransport(DbConnection conn) => _conn = conn;

    // ── Factory method: builds and awaits the OnConnect handshake ────────────
    internal static async Task<SpacetimeDbTransport> ConnectAsync(
        string                                          uri,
        string                                          database,
        string                                          token,
        Action<string, DbConnection, Identity>?         onConnected,
        CancellationToken                               ct)
    {
        var handshakeTcs = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        SpacetimeDbTransport? adapter = null;

        var conn = DbConnection.Builder()
            .WithUri(uri)
            .WithDatabaseName(database)
            .WithToken(token)
            .OnConnect((c, identity, t) =>
            {
                // IPC STEP A: handshake complete — signal the awaiter
                adapter!._isOpen = true;
                onConnected?.Invoke(database, c, identity);
                handshakeTcs.TrySetResult();
            })
            .OnConnectError(ex =>
            {
                handshakeTcs.TrySetException(
                    ex ?? new InvalidOperationException($"SpacetimeDB connect failed: {database}"));
            })
            .OnDisconnect((_, ex) =>
            {
                if (adapter is not null) adapter._isOpen = false;
                Console.WriteLine($"[Transport:{database}] Disconnected: {ex?.Message ?? "clean"}");
                adapter?.Disconnected?.Invoke();
            })
            .Build();

        adapter = new SpacetimeDbTransport(conn);

        // Block until OnConnect fires or until the CancellationToken fires.
        await handshakeTcs.Task.WaitAsync(ct).ConfigureAwait(false);
        return adapter;
    }

    public void Tick() => _conn.FrameTick();

    public ValueTask DisposeAsync()
    {
        _isOpen = false;
        return ValueTask.CompletedTask;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FACTORY
// ─────────────────────────────────────────────────────────────────────────────

public sealed class SpacetimeDbTransportFactory : IDbTransportFactory
{
    /// <summary>
    /// Fired when a new typed connection is ready.
    /// Program.cs subscribes to this to re-wire its delta callbacks on reconnect.
    /// Signature: (databaseName, conn, identity)
    /// </summary>
    public event Action<string, DbConnection, Identity>? ConnectionReady;

    public async Task<IDbTransport> CreateAsync(
        string uri, string database, string token, CancellationToken ct)
    {
        Console.WriteLine($"[Factory] Connecting to {uri}/{database}...");
        var transport = await SpacetimeDbTransport.ConnectAsync(
            uri, database, token,
            onConnected: (db, conn, id) => ConnectionReady?.Invoke(db, conn, id),
            ct);
        Console.WriteLine($"[Factory] Connected: {database}");
        return transport;
    }
}