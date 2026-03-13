using CitizenFX.Core;
using CitizenFX.Core.Native;
using Newtonsoft.Json.Linq;
using StdbBridge;
using System.Collections.Generic;

namespace ModPlayer
{
    public class PlayerModule : BaseScript
    {
        public PlayerModule()
        {
            // Self-register with the bridge registry on construction.
            // Note: net452 / Mono does not support C# 9 target-typed new().
            // Use explicit generic types on all collections.
            ModuleRegistry.Register(new StdbModuleConfig
            {
                ModuleName = "mod-player",

                AllowedReducers = new List<string>
                {
                    "request_spawn",
                    "on_player_connect",
                    "on_player_disconnect",
                    "update_player_heading"
                },

                NativeHandlers = new List<(string, System.Action<InstructionQueue>)>
                {
                    // Custom Native handler for setting model + spawning.
                    ("SET_PLAYER_MODEL", (instr) =>
                    {
                        var p = JObject.Parse(instr.Payload);
                        int ped = API.NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                        if (ped == 0) return;

                        uint modelHash = p["model_hash"].Value<uint>();
                        API.SetEntityModel(ped, modelHash);
                    }),

                    ("SET_PLAYER_HEADING", (instr) =>
                    {
                        var p = JObject.Parse(instr.Payload);
                        int ped = API.NetworkGetEntityFromNetworkId((int)instr.TargetEntityNetId);
                        if (ped == 0) return;
                        API.SetEntityHeading(ped, p["heading"].Value<float>());
                    })
                },

                SubscriptionQueries = new List<string>
                {
                    "SELECT * FROM player",
                    "SELECT * FROM active_session",
                    "SELECT * FROM spawn_request WHERE fulfilled = false"
                }
            });

            Debug.WriteLine("[mod-player] Module registered with StdbBridge.");
        }
    }
}