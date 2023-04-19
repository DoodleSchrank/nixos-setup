{
  programs.neovim = {
    enable = true;
    coc.enable = true;
    defaultEditor = true;
    extraConfig = ''
      set number
      set mouse=nvi
      set mousehide
      set mousefocus

      set linebreak
      set tabstop=2
      set expandtab
      set autoindent
      set smartindent
      set cindent

      syntax enable
    '';
  };
}