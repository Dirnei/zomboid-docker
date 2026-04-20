SandboxVars = {
    -- ── Shared Speed Multiplier ──
    Speed = 1,

    -- ── Zombies ──
    Zombies = 5,                -- 1=Insane 2=VeryHigh 3=High 4=Normal 5=Low
    Distribution = 1,           -- 1=Urban Focused 2=Uniform
    DayLength = 3,              -- 1=15min 2=30min 3=1hr 4=2hr 5=3hr (1hr is a sweet spot)
    StartYear = 1,
    StartMonth = 7,             -- July: warm weather, crops already growing
    StartDay = 1,
    StartTime = 2,              -- 1=7am 2=9am 3=12pm 4=2pm 5=5pm 6=9pm 7=12am 8=2am 9=5am

    -- ── Utilities ──
    WaterShut = 7,              -- 1-6 months (gives noobs a long grace period)
    WaterShutModifier = 14,     -- days after shutoff range starts
    ElecShut = 7,               -- 1-6 months
    ElecShutModifier = 14,

    -- ── Loot ──
    FoodLoot = 4,               -- 1=VeryRare to 5=Abundant
    WeaponLoot = 4,
    OtherLoot = 4,
    CannedFoodLoot = 4,
    LiteratureLoot = 4,
    MedicalLoot = 4,
    SurvivalGearsLoot = 3,
    MechanicsLoot = 3,

    -- ── World ──
    Temperature = 3,            -- 1=VeryCold 2=Cold 3=Normal 4=Warm (normal is fine in July)
    Rain = 3,                   -- 1=VeryDry to 5=VeryRainy (3=Normal)
    ErosionSpeed = 3,           -- 1=VeryFast to 5=VerySlow (3=Normal)
    ErosionDays = 0,
    FarmingSpeed = 3,           -- 1=VeryFast to 5=VerySlow (3=Normal)
    NatureAbundance = 3,        -- 1=VeryPoor to 5=VeryAbundant
    CompostTime = 2,            -- 1=1week to 5=4weeks
    Alarm = 6,                  -- 1=Never to 6=VeryRare (fewer alarm traps)
    LockedHouses = 6,           -- 1=Never to 6=VeryRare (easier entry)

    -- ── Zombie Behavior ──
    ZombieSpeed = 3,            -- 1=Sprinter 2=FastShambler 3=Shambler (KEEP THIS AT 3)
    ZombieStrength = 3,         -- 1=Superhuman 2=Normal 3=Weak
    ZombieToughness = 3,        -- 1=Tough 2=Normal 3=Fragile
    ZombieCognition = 3,        -- 1=Navigate+Doors 2=Navigate 3=Basic (dumber zombies)
    ZombieMemory = 2,           -- 1=Long 2=Normal 3=Short 4=None
    ZombieSight = 2,            -- 1=Eagle 2=Normal 3=Poor
    ZombieHearing = 2,          -- 1=Pinpoint 2=Normal 3=Poor
    ZombieSmell = 2,            -- 1=Bloodhound 2=Normal 3=Poor

    -- ── Infection & Health ──
    -- THIS IS THE BIGGEST NOOB-FRIENDLY CHANGE:
    -- Default PZ = one bite and you're dead. Turning this off lets
    -- new players learn without permadeath from every scratch.
    Transmission = 4,           -- 1=Blood+Saliva 2=Saliva Only 3=Everyone's Infected 4=None
    Mortality = 5,              -- 1=Instant 2=0-30sec 3=0-1min 4=0-12hr 5=2-3days 6=1-2weeks
    Reanimate = 3,              -- 1=Instant 2=0-30sec 3=0-1min 4=0-12hr 5=2-3days 6=1-2weeks
    BodyRemoval = 0,            -- 0=Never (bodies stay as warning markers)
    Infection = 2,              -- 1=Normal 2=Normal (wound infection, not zombie)
    InjurySeverity = 3,         -- 1=Low 2=Normal 3=Normal

    -- ── Zombie Population Over Time ──
    ZombieRespawn = 168,         -- 168 hours (7 days) before respawn starts
    ZombieRespawnPercent = 0.01, -- only 1% trickle back each cycle
    RedistributeHours = 48,      -- redistribute every 2 days (slow migration)
    RedistributePercent = 0.005, -- 0.5% migrate — barely noticeable
    RearZoneRespawnOffset = 168,
    FollowSoundDistance = 100,  -- default 100
    RallyGroupSize = 20,       -- smaller hordes (default 20)
    RallyTravelDistance = 20,
    RallyGroupSeparation = 15,
    RallyGroupRadius = 20,

    -- ── Meta Events (helicopter, gunshots etc.) ──
    Meta = 2,                   -- 1=Never 2=Sometimes 3=Often

    -- ── XP & Skills ──
    -- Faster leveling so noobs feel progress
    XPMultiplier = 3.0,
    XPMultiplierAffectsQuest = true,
    StatsDecrease = 3,          -- 1=VeryFast to 5=VerySlow (3=Normal)

    -- ── Vehicle ──
    EnableVehicles = true,
    CarSpawnRate = 3,           -- 1=None 2=VeryLow 3=Low 4=Normal
    ChanceHasGas = 5,           -- 1-100 (higher = more cars with gas)
    InitialGas = 4,             -- 1=Empty to 5=Full (start with decent gas)
    CarGasConsumption = 0.8,    -- lower = less gas usage
    LockedCar = 3,              -- 1=Never to 6=VeryRare
    CarGeneralCondition = 3,    -- 1=VeryLow to 5=VeryHigh
    CarDamageOnImpact = 3,      -- 1=VeryLow to 5=VeryHigh
    DamageToPlayerFromHitByACar = 3, -- 1=None to 5=VeryHigh
    TrafficJam = true,

    -- ── Player ──
    BonusFear = 3,              -- 1=VeryLow to 5=VeryHigh (3=Normal)
    BonusUnhappiness = 3,
    SlowBodyDamage = false,
    AllowMiniBuildings = true,
    PlayerBuildingHealth = 3,   -- 1=VeryLow to 5=VeryHigh
    ToolDurability = 3,         -- 1=VeryLow to 5=VeryHigh

    -- ── Fire ──
    FireSpread = true,
    DaysForRottenFoodRemoval = 8,

    -- ── Map ──
    Map = "Muldraugh, KY",
    MapAllKnown = true,         -- full map revealed (no need to find map items)

    -- ── Multiplayer-specific ──
    PVP = false,                -- PVE by default, no friendly fire frustration
    SafetySystem = true,
    ShowSafety = true,
    SafetyToggleTimer = 2,
    SafetyCooldownTimer = 3,
    SleepAllowed = true,
    SleepNeeded = false,        -- no forced sleep in MP
    DisplayServerTagName = true,
    AnnounceDeath = true,       -- let everyone know when someone dies (for laughs)
    MouseOverToSeeDisplayName = true,
    ShowSurvivalGuide = true,   -- keep the tutorial on
}
