-- What an install of GNS takes: install.lua and gns floppy read this.
-- loom: the files of the loom library the client uses, under /usr/lib/loom; the rest of loom
-- stays out of an install.
-- client: what only the client runs, under /usr. A gate server's install (install.lua gate,
-- gns floppy --gate) leaves it out, and loom with it.
return {
    loom = {"init.lua", "run.lua", "util.lua", "input.lua", "gpu.lua", "class.lua", "widget/init.lua",
        "widget/Widget.lua", "widget/Frame.lua", "widget/TextInput.lua", "widget/Shader.lua"},
    client = {"gns/client", "gns/address.lua", "gns/invite.lua", "gns/peer.lua"},
}
