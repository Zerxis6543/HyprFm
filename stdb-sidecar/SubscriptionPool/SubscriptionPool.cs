namespace HyprFM.Sidecar.Pool;

using System.Collections.Concurrent;
using System.Threading.Channels;

// ─────────────────────────────────────────────────────────────────────────────
// SUBSCRIPTION POOL
// Runtime registry of ManagedSubscription instances.
// AddSubscription / RemoveSubscription are the only public mutation points.
// All events from all databases flow through one ChannelReader<DatabaseEvent>
// that callers drain to react to cross-module state changes.
// ─────────────────────────────────────────────────────────────────────────────

public sealed class SubscriptionPool : IAsyncDisposable
{
    // ── Registry ──────────────────────────────────────────────────────────────
    private readonly ConcurrentDictionary<string, ManagedSubscription> _pool = new(
        StringComparer.OrdinalIgnoreCase);

    // ── Configuration ─────────────────────────────────────────────────────────
    private readonly string             _baseUri;
    private readonly string             _defaultToken;
    private readonly IDbTransportFactory _factory;

    // ── Event bus ─────────────────────────────────────────────────────────────
    // Unbounded so slow consumers never back-pressure the tick loops.
    // SingleWriter=false: every ManagedSubscription writes concurrently.
    private readonly Channel<DatabaseEvent> _bus =
        Channel.CreateUnbounded<DatabaseEvent>(new UnboundedChannelOptions
        {
            SingleWriter = false,
            SingleReader = false,
        });

    /// <summary>Read side of the event bus. Consumers filter by DatabaseEvent.DatabaseName.</summary>
    public ChannelReader<DatabaseEvent> Events => _bus.Reader;

    public SubscriptionPool(string baseUri, string defaultToken, IDbTransportFactory factory)
    {
        _baseUri      = baseUri;
        _defaultToken = defaultToken;
        _factory      = factory;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADD
    // ─────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Start a managed subscription for <paramref name="databaseName"/>.
    /// Returns <c>true</c> if the subscription was created; <c>false</c> if
    /// one was already active (idempotent — safe to call multiple times).
    /// </summary>
    public bool AddSubscription(string databaseName, string? token = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databaseName);

        // Build a candidate — we may discard it if TryAdd loses the race.
        var candidate = new ManagedSubscription(
            databaseName,
            _baseUri,
            token ?? _defaultToken,
            _factory,
            _bus.Writer);

        if (_pool.TryAdd(databaseName, candidate))
        {
            Console.WriteLine($"[Pool] ✓ Subscribed: {databaseName}");
            return true;
        }

        // Another caller won — discard without blocking this thread.
        _ = candidate.DisposeAsync().AsTask();
        Console.WriteLine($"[Pool] SKIP: {databaseName} already active");
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // REMOVE
    // ─────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Stop and remove the subscription for <paramref name="databaseName"/>.
    /// Awaits the supervisor's orderly exit before returning.
    /// Returns <c>false</c> if the database was not tracked.
    /// </summary>
    public async Task<bool> RemoveSubscriptionAsync(string databaseName)
    {
        if (!_pool.TryRemove(databaseName, out var sub))
            return false;

        Console.WriteLine($"[Pool] ✗ Removing: {databaseName}");
        await sub.DisposeAsync().ConfigureAwait(false);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // QUERY
    // ─────────────────────────────────────────────────────────────────────────

    public bool IsConnected(string databaseName)
        => _pool.TryGetValue(databaseName, out var s) && s.IsConnected;

    public IReadOnlyList<string> ActiveDatabases
        => _pool.Keys.ToArray();

    public int Count => _pool.Count;

    // ─────────────────────────────────────────────────────────────────────────
    // DISPOSE
    // ─────────────────────────────────────────────────────────────────────────

    public async ValueTask DisposeAsync()
    {
        // Drain all entries and stop them concurrently — no sequential waiting.
        var entries = _pool.Values.ToArray();
        _pool.Clear();

        await Task.WhenAll(entries.Select(s => s.DisposeAsync().AsTask()))
                  .ConfigureAwait(false);

        // Signal the ChannelReader end-of-stream so consumers can exit their ReadAllAsync loop.
        _bus.Writer.TryComplete();
    }
}