{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    viAlias = true;
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
