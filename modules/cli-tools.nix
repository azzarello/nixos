# Modern CLI tools for hands-on work, with aliases for interactive shells only. Scripts, systemd units and
# non-interactive `ssh host 'cmd'` keep the classic tools: NixOS puts environment.shellAliases in the
# interactive-shell init, never in what a script sources.
# find/grep/du are deliberately NOT aliased: fd and rg take different flags and skip hidden and .gitignore'd
# files, and dust's flags differ from du's, so pasted commands would break or silently miss files.
# Use fd, rg and dust by name. One-off tools need no package here: `nix shell nixpkgs#<tool>`.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    eza       # ls
    fd        # find (by name)
    ripgrep   # rg: grep -r
    bat       # cat with highlighting; plain like cat when piped
    dust      # du as a tree
    procs     # ps
    bottom    # btm: top
    sd        # sed s///
    zoxide    # z: cd by frecency
  ];

  environment.shellAliases = {
    ls = "eza";
    ll = "eza -l --git";
    la = "eza -la --git";
    lt = "eza -l --sort=modified";   # eza's -t picks *which* time, so `ls -ltr` habits go here instead
    tree = "eza --tree";
    cat = "bat --paging=never --style=plain";
    top = "btm";
  };

  # `z <dir>` / `zi`; interactive bash only
  programs.bash.interactiveShellInit = ''
    eval "$(${pkgs.zoxide}/bin/zoxide init bash)"
  '';
}
