-- FarCryCoop: the mod's version. Everyone needs the same one: a player with another is turned
-- away with a box that says both (COOPVER: COOP ClientStuff says ours, COOP gamerules answers with
-- its own or disconnects). A release sets it.
-- ModDesc.txt (_Version_, shown in the game's Mods menu) says the same: release/ci-package.ps1 checks
COOP_VERSION = "0.4-dev"
-- seconds to wait for the other side's version: versions before 0.4 never say it
COOP_VER_WAIT = 15
