using CitizenFX.Core;
using CitizenFX.Core.Native;
using Newtonsoft.Json.Linq;
using SpacetimeDB.Types;
using System;
using System.Collections.Generic;

namespace StdbBridge
{
    /// <summary>
    /// Dictionary-based Native dispatcher.
    /// Each handler is a strongly-typed lambda that deserializes its payload
    /// and calls the appropriate CitizenFX API method.
    ///
    /// External modules call RegisterHandler() to add their own Natives.
    /// </summary>
    public class NativeDispatcher
    {
        private readonly BaseScript _script;

        // The lookup table: native_key → strongly-typed handler.
        // Populated once at startup; reads are lock-free after that.
        private readonly Dictionary<string, Action<InstructionQueue>> _handlers;

        public NativeDispatcher(BaseScript script)
        {
            _script   = script;
            _handlers = new Dictionary<string, Action<InstructionQueue>>(
                StringComparer.OrdinalIgnoreCase); // case-insensitive keys

            RegisterCoreHandlers();
        }

        // ── CORE HANDLER REGISTRATION ─────────────────────────────────────────

        private void RegisterCoreHandlers()
        {
            // ── Position ──────────────────────────────────────────────────────
            _handlers["SET_ENTITY_COORDS"] = (instr) =>
            {
                int entity = NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                if (entity == 0) return; // entity not found on this server

                var p = JObject.Parse(instr.Payload);
                API.SetEntityCoords(
                    entity,
                    p["x"]!.Value<float>(),
                    p["y"]!.Value<float>(),
                    p["z"]!.Value<float>(),
                    p["xAxis"]?.Value<bool>() ?? false,
                    p["yAxis"]?.Value<bool>() ?? false,
                    p["clearArea"]?.Value<bool>() ?? true
                );
            };

            // ── Weapons ───────────────────────────────────────────────────────
            _handlers["GIVE_WEAPON_TO_PED"] = (instr) =>
            {
                int ped = NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                if (ped == 0) return;

                var p = JObject.Parse(instr.Payload);
                API.GiveWeaponToPed(
                    ped,
                    p["weapon_hash"]!.Value<uint>(),
                    p["ammo_count"]!.Value<int>(),
                    p["equip_now"]?.Value<bool>() ?? true,
                    p["allow_multiple"]?.Value<bool>() ?? false
                );
            };

            // ── Health ────────────────────────────────────────────────────────
            _handlers["SET_ENTITY_HEALTH"] = (instr) =>
            {
                int entity = NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                if (entity == 0) return;
                var p = JObject.Parse(instr.Payload);
                API.SetEntityHealth(entity, p["health"]!.Value<int>());
            };

            // ── Freeze ────────────────────────────────────────────────────────
            _handlers["FREEZE_ENTITY_POSITION"] = (instr) =>
            {
                int entity = NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                if (entity == 0) return;
                var p = JObject.Parse(instr.Payload);
                API.FreezeEntityPosition(entity, p["toggle"]!.Value<bool>());
            };

            // ── Network events (send to client) ───────────────────────────────
            _handlers["TRIGGER_CLIENT_EVENT"] = (instr) =>
            {
                var p = JObject.Parse(instr.Payload);
                string eventName = p["event"]!.Value<string>()!;
                string target    = p["target"]!.Value<string>()!;
                string args      = p["args"]?.ToString() ?? "{}";
                // Use BaseScript.TriggerClientEvent via _script reference.
                _script.TriggerClientEvent(eventName, target, args);
            };

            Debug.WriteLine($"[NativeDispatcher] {_handlers.Count} core handlers registered.");
        }

        // ── PUBLIC: modules add their own handlers ────────────────────────────

        public void RegisterHandler(string nativeKey, Action<InstructionQueue> handler)
        {
            if (_handlers.ContainsKey(nativeKey))
            {
                Debug.WriteLine($"[NativeDispatcher] WARNING: Overwriting handler for {nativeKey}");
            }
            _handlers[nativeKey] = handler;
            Debug.WriteLine($"[NativeDispatcher] Registered: {nativeKey}");
        }

        // ── EXECUTION ─────────────────────────────────────────────────────────

        public void Execute(InstructionQueue instruction)
        {
            if (!_handlers.TryGetValue(instruction.NativeKey, out var handler))
            {
                Debug.WriteLine($"[NativeDispatcher] UNKNOWN native_key: {instruction.NativeKey}");
                return;
            }

            handler(instruction);
        }

        // ── HELPERS ───────────────────────────────────────────────────────────

        private static int NetworkGetEntityFromNetworkId(int netId)
            => API.NetworkGetEntityFromNetworkId(netId);
    }
}