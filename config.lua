-- Options for Mud and Blood Co-op, shown on QuarterMaster 1.8's Mod Options screen (or the old GMenu's).
-- QM reads this file as text: plain tables only, no functions. Read at runtime with net.option(id).
return {
    name = "Co-op",
    options = {
        {
            id = "port",
            label = "Host port (UDP)",
            type = "cycle",
            default = 47913,
            options = { 47913, 47914, 47915, 27015 },
            labels = { "47913", "47914", "47915", "27015" },
            description = "Port a hosted lobby listens on. Point your playit.gg UDP tunnel at this port. Joiners type host:port if it isn't 47913.",
        },
        {
            id = "joinCode",
            label = "Require join code",
            type = "checkbox",
            default = true,
            description = "Hosted lobbies get a code that rides along in COPY ADDRESS. Strangers who find your address can't get in without it.",
        },
        {
            id = "syncRate",
            label = "Battle updates per second (host)",
            type = "cycle",
            default = 30,
            options = { 30, 45, 60, 20, 10 },
            labels = { "30", "45", "60", "20", "10" },
            description = "How often the host sends the battle to the other players. Higher: friends' screens react sooner (less waiting and smoothing), more upload and a bit more work for the host each frame; it can't go above the host's frame rate. Lower (20, 10) for a slow connection. Movement is smoothed either way.",
        },
        {
            id = "classicDefense",
            label = "Co-op Classic: defend the middle",
            type = "checkbox",
            default = true,
            description = "Co-op Classic starts your squads in the middle around a radar and the Germans come from both sides. Off: the usual Classic, everyone on the left.",
        },
        {
            id = "stackWindows",
            label = "Two copies on one PC: stack the windows",
            type = "checkbox",
            default = true,
            description = "When a copy joins 127.0.0.1 (both games on this PC), the host's window goes to the top of the screen and the friend's to the bottom, shrunk to fit if the screen is too small for two.",
        },
        {
            id = "netStats",
            label = "Show network stats",
            type = "checkbox",
            default = false,
            description = "While connected: ping, upload/download per second and totals, top right. Ctrl+F8 toggles it too.",
        },
        {
            id = "debug",
            label = "Debug log",
            type = "checkbox",
            default = false,
            description = "Print co-op network messages to the console",
        },
    },
}
