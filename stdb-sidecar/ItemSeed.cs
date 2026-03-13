// G:\FIVEMSTDBPROJECT\stdb-sidecar\ItemSeed.cs
static class ItemSeed
{
    public record ItemDef(
        string Id,
        string Label,
        float  Weight,
        bool   Stackable,
        bool   Usable,
        uint   MaxStack,
        string Category
    );

    public static readonly ItemDef[] Items =
    {
        // ── Medical ──────────────────────────────────────────────────────────
        new("bandage",       "Bandage",        0.1f,  true,  true,  20,   "misc"),
        new("medkit",        "Medical Kit",    1.0f,  false, true,  1,    "misc"),

        // ── Food & Drink ─────────────────────────────────────────────────────
        new("water_bottle",  "Water Bottle",   0.5f,  true,  true,  10,   "misc"),
        new("food_burger",   "Burger",         0.3f,  true,  true,  10,   "misc"),

        // ── Documents ────────────────────────────────────────────────────────
        new("id_card",       "ID Card",        0.01f, false, false, 1,    "misc"),
        new("cash",          "Cash",           0.01f, true,  false, 1000, "misc"),

        // ── Comms ────────────────────────────────────────────────────────────
        new("phone",         "Phone",          0.1f,  false, true,  1,    "phone"),

        // ── Weapons ──────────────────────────────────────────────────────────
        new("weapon_pistol", "Pistol",         1.5f,  false, false, 1,    "weapon"),
        new("ammo_pistol",   "Pistol Ammo",    0.05f, true,  false, 250,  "misc"),
        new("weapon_knife",  "Knife",          0.5f,  false, false, 1,    "weapon"),
        new("assault_rifle", "Assault Rifle",  4.5f,  false, false, 1,    "weapon"),

        // ── Tools ────────────────────────────────────────────────────────────
        new("lockpick",      "Lockpick",       0.1f,  true,  true,  10,   "misc"),
        new("handcuffs",     "Handcuffs",      0.5f,  false, true,  1,    "misc"),
        new("hammer",        "Hammer",         1.2f,  false, false, 1,    "misc"),

        // ── Police ───────────────────────────────────────────────────────────
        new("evidence_bag",  "Evidence Bag",   0.1f,  true,  false, 20,   "misc"),
        new("radio",         "Police Radio",   0.3f,  false, true,  1,    "misc"),

        // ── Drugs ────────────────────────────────────────────────────────────
        new("weed",          "Weed",           0.1f,  true,  false, 100,  "misc"),
        new("cocaine",       "Cocaine",        0.1f,  true,  false, 100,  "misc"),
        new("dirty_money",   "Dirty Money",    0.01f, true,  false, 1000, "misc"),

        // ── Bags / Containers ────────────────────────────────────────────────
        new("backpack",      "Backpack",       2.0f,  false, false, 1,    "bag"),
        new("duffel_bag",    "Duffel Bag",     1.5f,  false, false, 1,    "bag"),

        // ── Armor ────────────────────────────────────────────────────────────
        new("body_armour",   "Body Armour",    3.0f,  false, false, 1,    "armor"),

        // ── Parachute ────────────────────────────────────────────────────────
        new("parachute",     "Parachute",      5.0f,  false, false, 1,    "parachute"),
    };
}