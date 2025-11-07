-- /usr/lib/lua/luci/controller/libernet.lua

module("luci.controller.libernet", package.seeall)

function index()
    -- Cipta entri menu di bawah 'Services' (Perkhidmatan)
    -- Tukar target dari 'call("action_redirect_libernet")' kepada 'template("libernet/iframe")'
    if nixio.fs.access("/www/libernet") then
        entry({"admin", "services", "libernet_menu"}, template("libernet/iframe"), _("Libernet"), 40)
    end
end
