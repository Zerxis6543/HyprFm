using CitizenFX.Core;
using SpacetimeDB;
using SpacetimeDB.Types;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace StdbBridge
{
    public class Bridge : BaseScript
    {
        private static DbConnection _db;
        private readonly InstructionProcessor _processor;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();

        public Bridge()
        {
            _processor = new InstructionProcessor(this);

            _ = ConnectAsync();

            EventHandlers["playerConnecting"]  += new Action<Player, string, dynamic, dynamic>(OnPlayerConnecting);
            EventHandlers["playerDropped"]     += new Action<Player, string>(OnPlayerDropped);
            EventHandlers["stdb:clientAction"] += new Action<Player, string, string>(OnClientAction);

            Tick += OnTick;

            Debug.WriteLine("[STDB-Bridge] Initialized.");
        }

        private async Task ConnectAsync()
        {
            string uri    = GetConvar("stdb_uri",   "ws://localhost:3000");
            string dbName = GetConvar("stdb_db",    "fivem-game");
            string token  = GetConvar("stdb_token", "");

            try
            {
                _db = DbConnection.Builder()
                    .WithUri(uri)
                    .WithModuleName(dbName)
                    .WithToken(token)
                    .OnConnect(OnStdbConnected)
                    .OnConnectError(OnStdbError)
                    .OnDisconnect(OnStdbDisconnected)
                    .Build();

                await _db.ConnectAsync(_cts.Token);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[STDB-Bridge] FATAL: Connection failed - {ex.Message}");
            }
        }

        private void OnStdbConnected(DbConnection conn, Identity identity, string token)
        {
            Debug.WriteLine($"[STDB-Bridge] Connected. Identity: {identity}");

            conn.SubscriptionBuilder()
                .OnApplied(OnSubscriptionReady)
                .Subscribe(new[] {
                    "SELECT * FROM instruction_queue WHERE consumed = false",
                    "SELECT * FROM active_session"
                });
        }

        private void OnSubscriptionReady(SubscriptionEventContext ctx)
        {
            Debug.WriteLine("[STDB-Bridge] Subscription active - instruction queue live.");

            // Instance-based OnInsert in SDK 1.0
            _db.Db.InstructionQueue.OnInsert += _processor.EnqueueInstruction;
        }

        private void OnStdbError(DbConnection conn, Exception ex)
            => Debug.WriteLine($"[STDB-Bridge] ERROR: {ex.Message}");

        private void OnStdbDisconnected(DbConnection conn, Exception ex)
        {
            Debug.WriteLine("[STDB-Bridge] Disconnected - scheduling reconnect in 5s.");
            _ = Task.Delay(5000).ContinueWith(_ => ConnectAsync());
        }

        private async Task OnTick()
        {
            _processor.Drain(maxPerTick: 20);
            _db?.FrameTick();
            await Delay(0);
        }

        private async void OnPlayerConnecting(
            [FromSource] Player player,
            string playerName,
            dynamic setKickReason,
            dynamic deferrals)
        {
            deferrals.defer();
            await Delay(0);

            try
            {
                string steamHex = player.Identifiers["steam"] ?? "unknown";
                uint netId = (uint)GetPlayerPed(player.Handle);

                _db.Reducers.OnPlayerConnect(
                    steamHex,
                    playerName,
                    uint.Parse(player.Handle),
                    netId
                );

                deferrals.done();
            }
            catch (Exception ex)
            {
                deferrals.done($"Connection error: {ex.Message}");
            }
        }

        private void OnPlayerDropped([FromSource] Player player, string reason)
        {
            _db.Reducers.OnPlayerDisconnect();
            Debug.WriteLine($"[STDB-Bridge] Player {player.Name} dropped: {reason}");
        }

        private void OnClientAction([FromSource] Player player, string reducerName, string argsJson)
        {
            if (!ModuleRegistry.IsReducerAllowed(reducerName))
            {
                Debug.WriteLine($"[STDB-Bridge] BLOCKED reducer call: {reducerName} from {player.Name}");
                return;
            }
            ModuleRegistry.DispatchReducer(_db, reducerName, argsJson);
        }
    }
}