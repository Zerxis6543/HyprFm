using CitizenFX.Core;
using SpacetimeDB.Types;
using System;
using System.Collections.Generic;

namespace StdbBridge
{
    /// <summary>
    /// Static registry that modules call at startup to register:
    ///   1. Allowed reducer names (security allowlist)
    ///   2. Custom Native handlers (added to NativeDispatcher)
    ///   3. Subscription queries (additional STDB table subscriptions)
    /// </summary>
    public static class ModuleRegistry
    {
        private static NativeDispatcher _dispatcher;

        // Allowlist of reducer names clients are permitted to call.
        private static readonly HashSet<string> _allowedReducers
            = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Registered subscription queries (module → SQL-like STDB query).
        private static readonly List<(string module, string query)> _subscriptions
            = new List<(string, string)>();

        // Called once by Bridge during startup.
        public static void Initialize(NativeDispatcher dispatcher)
        {
            _dispatcher = dispatcher;

            // Core allowlist — always permitted.
            _allowedReducers.Add("request_spawn");
            _allowedReducers.Add("equip_weapon");
        }

        /// Module registration entrypoint.
        /// Call this from your module's BaseScript constructor.
        public static void Register(StdbModuleConfig config)
        {
            // Register allowed reducers.
            foreach (var reducer in config.AllowedReducers)
                _allowedReducers.Add(reducer);

            // Register custom Native handlers.
            foreach (var (key, handler) in config.NativeHandlers)
                _dispatcher.RegisterHandler(key, handler);

            // Register subscription queries.
            foreach (var query in config.SubscriptionQueries)
                _subscriptions.Add((config.ModuleName, query));

            Debug.WriteLine($"[ModuleRegistry] Module '{config.ModuleName}' registered " +
                            $"({config.AllowedReducers.Count} reducers, " +
                            $"{config.NativeHandlers.Count} native handlers).");
        }

        public static bool IsReducerAllowed(string reducerName)
            => _allowedReducers.Contains(reducerName);

        public static void DispatchReducer(DbConnection db, string reducerName, string argsJson)
        {
            // Reflect over db.Reducers to find and call the method.
            // In production, use a pre-built dictionary of Action<string> delegates
            // for performance (same pattern as NativeDispatcher).
            var method = db.Reducers.GetType().GetMethod(
                ToPascalCase(reducerName),
                System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance
            );
            method?.Invoke(db.Reducers, ParseArgs(reducerName, argsJson));
        }

        private static string ToPascalCase(string snakeCase)
        {
            var parts = snakeCase.Split('_');
            var result = new System.Text.StringBuilder();
            foreach (var part in parts)
                if (part.Length > 0)
                    result.Append(char.ToUpper(part[0]) + part.Substring(1));
            return result.ToString();
        }

        private static object[] ParseArgs(string reducerName, string argsJson)
        {
            // Module-specific arg deserialization; simplified here.
            // Production: each module registers an arg-parser alongside its reducer.
            return new object[] { argsJson };
        }
    }

    /// Configuration object a module provides during registration.
    public class StdbModuleConfig
    {
        public string ModuleName { get; set; }
        public List<string> AllowedReducers { get; set; } = new();
        public List<(string key, Action<InstructionQueue> handler)> NativeHandlers { get; set; } = new();
        public List<string> SubscriptionQueries { get; set; } = new();
    }
}