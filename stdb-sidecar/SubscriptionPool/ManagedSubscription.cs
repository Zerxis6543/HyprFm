namespace HyprFM.Sidecar.Pool;

using System.Threading.Channels;

// ─────────────────────────────────────────────────────────────────────────────
// MANAGED SUBSCRIPTION
// One instance per database. Runs a supervisor loop that:
//   connect → tick → detect disconnect → backoff → reconnect → repeat
//
// All state transitions are published to the shared Channel<DatabaseEvent> bus.
// External callers only interact via StopAsync() — all mutation is internal.
// ─────────────────────────────────────────────────────────────────────────────

public sealed class ManagedSubscription : IAsyncDisposable
{
    // ── Identity (immutable) ──────────────────────────────────────────────────
    public string DatabaseName { get; }

    // ── Observable state (volatile — readable from any thread) ───────────────
    private volatile bool _connected;
    public bool IsConnected => _connected;

    // ── Internal wiring ───────────────────────────────────────────────────────
    private readonly string                      _uri;
    private readonly string                      _token;
    private readonly IDbTransportFactory         _factory;
    private readonly ChannelWriter<DatabaseEvent> _bus;       // shared across all subscriptions
    private readonly CancellationTokenSource     _cts = new();
    private readonly Task                        _supervisor; // the long-running background task

    // ── Backoff policy ────────────────────────────────────────────────────────
    private const int InitialMs = 1_000;
    private const int MaxMs     = 30_000;

    public ManagedSubscription(
        string                       databaseName,
        string                       uri,
        string                       token,
        IDbTransportFactory          factory,
        ChannelWriter<DatabaseEvent> bus)
    {
        DatabaseName = databaseName;
        _uri         = uri;
        _token       = token;
        _factory     = factory;
        _bus         = bus;

        // ── IPC STEP 0: Launch supervisor as a fire-and-forget background task ──
        // Task.Run ensures the constructor returns immediately; supervision happens
        // on the thread pool, independent of the caller's thread context.
        _supervisor  = Task.Run(() => RunSupervisorAsync(_cts.Token));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SUPERVISOR LOOP
    // ─────────────────────────────────────────────────────────────────────────

    private async Task RunSupervisorAsync(CancellationToken ct)
    {
        var rng       = new Random();
        int backoffMs = InitialMs;

        while (!ct.IsCancellationRequested)
        {
            IDbTransport? transport = null;
            try
            {
                // ── IPC STEP 1: Open transport (blocks until handshake) ───────
                transport = await _factory.CreateAsync(_uri, DatabaseName, _token, ct);

                // Reset backoff on every successful connect
                _connected = true;
                backoffMs  = InitialMs;
                Publish(DatabaseEventKind.Connected);

                // ── IPC STEP 2: Arm the disconnect signal ─────────────────────
                // The TCS is completed by the transport's Disconnected event so the
                // tick loop can exit without polling IsOpen on every iteration.
                var disconnectSignal = new TaskCompletionSource(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                transport.Disconnected += () => disconnectSignal.TrySetResult();

                // ── IPC STEP 3: Tick loop — drives the SpacetimeDB state machine ─
                await TickUntilDisconnectedAsync(transport, disconnectSignal.Task, ct);

                _connected = false;
                Publish(DatabaseEventKind.Disconnected);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                // Clean shutdown path — do not reconnect
                _connected = false;
                Publish(DatabaseEventKind.Disconnected);
                break;
            }
            catch (Exception ex)
            {
                _connected = false;
                Publish(DatabaseEventKind.Error, exception: ex);
            }
            finally
            {
                if (transport is not null)
                    await transport.DisposeAsync();
            }

            if (ct.IsCancellationRequested) break;

            // ── Exponential backoff with ±10 % jitter ─────────────────────────
            int jitter = (int)(backoffMs * 0.10 * (rng.NextDouble() * 2.0 - 1.0));
            int delay  = Math.Clamp(backoffMs + jitter, 1, MaxMs);
            Publish(DatabaseEventKind.Reconnecting, payload: $"retry in {delay / 1_000.0:F1}s");

            try   { await Task.Delay(delay, ct); }
            catch (OperationCanceledException) { break; }

            backoffMs = Math.Min(backoffMs * 2, MaxMs);
        }
    }

    // Each call to Tick() drives one SpacetimeDB frame; 50 ms cadence matches
    // the original Program.cs loop and gives ~20 frames/sec of state polling.
    private static async Task TickUntilDisconnectedAsync(
        IDbTransport      transport,
        Task              disconnectSignal,
        CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !disconnectSignal.IsCompleted)
        {
            transport.Tick();
            await Task.Delay(50, ct).ConfigureAwait(false);
        }
    }

    // ── Fire-and-forget publish — TryWrite is lock-free and never blocks ──────
    private void Publish(
        DatabaseEventKind kind,
        string?           payload   = null,
        Exception?        exception = null)
    {
        var ev = new DatabaseEvent(DatabaseName, kind, payload, exception);
        // If the channel is bounded and full, fall back to async write on a pool thread.
        if (!_bus.TryWrite(ev))
            _ = _bus.WriteAsync(ev).AsTask();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LIFECYCLE
    // ─────────────────────────────────────────────────────────────────────────

    /// <summary>Cancel the supervisor and await its orderly exit.</summary>
    public async Task StopAsync()
    {
        _cts.Cancel();
        try { await _supervisor.ConfigureAwait(false); }
        catch (OperationCanceledException) { /* expected on clean shutdown */ }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _cts.Dispose();
    }
}