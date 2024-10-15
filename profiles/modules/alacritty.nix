{
  programs.alacritty = {
    enable = true;
    settings = {
      window.decorations = "none";
      window.dynamic_title = true;
      window.decorations_theme_variant = "Dark";

      font.normal.family = "DejaVu Sans Mono";
      font.size = 10.0;

      colors.primary.background = "#000000";
      colors.primary.foreground = "#ffffff";
      colors.normal.black = "#000000";
      colors.bright.black = "#000000";
      colors.dim.black = "#000000";

      cursor.style.shape = "Beam";
    };
  };
}
