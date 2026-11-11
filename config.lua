-- GMenu options for Mud and Blood Co-op (read at runtime with modLibrary.option("mnb_coop", id)).
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
