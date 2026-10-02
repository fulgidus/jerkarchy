-- wezterm — matches the river/waybar palette (cyan/magenta on near-black)
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- fish loads starship from ~/.config/fish/config.fish
config.default_prog = { "fish" }

config.font = wezterm.font("JetBrainsMono Nerd Font")
config.font_size = 12.0

config.enable_wayland = true
config.window_decorations = "NONE" -- river draws borders
config.window_padding = { left = 8, right = 8, top = 6, bottom = 6 }
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false
config.audible_bell = "Disabled"
config.window_close_confirmation = "NeverPrompt"
config.check_for_updates = false

config.colors = {
    foreground = "#c8c8d0",
    background = "#0a0a0f",
    cursor_bg = "#00f0ff",
    cursor_fg = "#0a0a0f",
    cursor_border = "#00f0ff",
    selection_bg = "#2a2a35",
    selection_fg = "#e5e1e7",
    split = "#2a2a35",
    ansi = { "#1a1a22", "#ff2b6d", "#00ff9f", "#ffcc00", "#3d7eff", "#c74ded", "#00f0ff", "#c8c8d0" },
    brights = { "#55556a", "#ff5c8a", "#5cffbf", "#ffe066", "#6e9eff", "#d980f5", "#66f6ff", "#ffffff" },
    tab_bar = {
        background = "#0a0a0f",
        active_tab = { bg_color = "#00f0ff", fg_color = "#0a0a0f" },
        inactive_tab = { bg_color = "#0a0a0f", fg_color = "#55556a" },
        inactive_tab_hover = { bg_color = "#1a1a22", fg_color = "#c8c8d0" },
        new_tab = { bg_color = "#0a0a0f", fg_color = "#55556a" },
        new_tab_hover = { bg_color = "#1a1a22", fg_color = "#00f0ff" },
    },
}

return config
