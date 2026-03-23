static class ItemSeed
{
    public record ItemDef(
        string Id,
        string Label,
        float  Weight,
        bool   Stackable,
        bool   Usable,
        uint   MaxStack,
        string Category,
        string PropModel       = "prop_cs_cardbox_01",
        int    MagCapacity     = 0,
        int    StoredCapacity  = 0,
        string AmmoType        = ""
    );

    public static readonly ItemDef[] Items =
    {
        // Medical
        new("bandage",       "Bandage",        0.1f,  true,  true,  20,   "misc",      "prop_rag_01"),
        new("medkit",        "Medical Kit",    1.0f,  false, true,  1,    "misc",      "sm_prop_smug_crate_s_medical"),

        //food and drink
        new("water_bottle",  "Water Bottle",   0.5f,  true,  true,  10,   "misc",      "prop_cs_beer_01"),
        new("food_burger",   "Burger",         0.3f,  true,  true,  10,   "misc",      "prop_cs_hotdog_01"),

        //Misc
        new("id_card",       "ID Card",        0.01f, false, false, 1,    "misc",      "prop_notepad_01"),
        new("cash",          "Cash",           0.001f, true,  false, 1000, "misc",      "prop_amb_cash_note"),

        //Electronics
        new("phone",         "Phone",          0.1f,  false, true,  1,    "phone",     "prop_npc_phone_02"),

        //Weapons and Ammo
        new("weapon_pistol", "Pistol",        1.5f,  false, false, 1,   "weapon", "prop_w_pi_pistol",      MagCapacity: 17, StoredCapacity: 255,  AmmoType: "ammo_pistol"),
        new("ammo_pistol",   "Pistol Ammo",   0.05f, true,  false, 250, "misc",   "prop_box_ammo01a"),
        new("weapon_knife",  "Knife",         0.5f,  false, false, 1,   "weapon", "prop_cs_knife_01",      MagCapacity: 0,  StoredCapacity: 0,   AmmoType: ""),
        new("assault_rifle", "Assault Rifle", 4.5f,  false, false, 1,   "weapon", "prop_w_ar_assaultrifle",MagCapacity: 30, StoredCapacity: 120, AmmoType: "ammo_rifle"),

        //Other
        new("lockpick",      "Lockpick",       0.1f,  true,  true,  10,   "misc",      "prop_cs_cardbox_01"),
        new("hammer",        "Hammer",         1.2f,  false, false, 1,    "misc",      "prop_tool_hammer"),

        //Police
        new("evidence_bag",  "Evidence Bag",   0.1f,  true,  false, 20,   "misc",      "prop_cs_cardbox_01"),
        new("handcuffs",     "Handcuffs",      0.5f,  false, true,  1,    "misc",      "prop_cs_cardbox_01"),

        //Comms
        new("radio",         "Police Radio",   0.3f,  false, true,  1,    "misc",      "prop_cs_cardbox_01"),

        //Illegal
        new("weed",          "Weed",           0.1f,  true,  false, 100,  "misc",      "prop_cs_cardbox_01"),
        new("cocaine",       "Cocaine",        0.1f,  true,  false, 100,  "misc",      "prop_cs_cardbox_01"),
        new("dirty_money",   "Dirty Money",    0.01f, true,  false, 1000, "misc",      "prop_amb_cash_note"),

        //Containers
        new("backpack",      "Backpack",       2.0f,  false, false, 1,    "bag",       "prop_cs_duffel_bag_01"),
        new("duffel_bag",    "Duffel Bag",     1.5f,  false, false, 1,    "bag",       "prop_cs_duffel_bag_01"),

        //Armor
        new("body_armour",   "Body Armour",    3.0f,  false, false, 1,    "armor",     "prop_cs_cardbox_01"),
        
        //Gadgets
        new("parachute",     "Parachute",      5.0f,  false, false, 1,    "parachute", "prop_cs_cardbox_01"),
    };
}