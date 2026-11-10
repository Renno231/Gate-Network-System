-- An rc daemon that only installer floppies from gns floppy --os carry (as /etc/rc.d/gns-autorun.lua,
-- enabled by the installer): at the first boot it turns gns autorun on, so the gate serves without
-- anyone at the computer, then disables and removes itself, so gns autorun off stays off.
function start()
    local shell = require("shell")
    shell.execute("gns autorun on")
    shell.execute("rc gns-autorun disable")
    require("filesystem").remove("/etc/rc.d/gns-autorun.lua")
end
